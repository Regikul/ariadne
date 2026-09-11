%% @doc Исполняет граф целиком внутри одного Erlang-процесса.
%%
%% `compile/1` переводит плоский `#graph{}` в неизменную программу:
%% проверяет модули узлов и слоты на концах рёбер, строит индексы
%% маршрутизации, фиксирует стабильные порядки узлов и рёбер и считает
%% минимальные сводки непустых путей между узлами.
%%
%% `new/2` создаёт прогон по программе: вызывает `init/1` каждого узла,
%% наполняет входные очереди и ставит в `ready` начальные переходы.
%% `advance/2` выполняет переходы: каждый шаг снимает с головы `ready`
%% ребро или уведомление, вызывает callback узла и применяет результат
%% целиком либо отбрасывает его, записывая нарушение.
%%
%% Собственных процессов модуль не создаёт; прогон идёт по месту вызова.
%%
%% Ошибки сборки возвращаются как `{error, Reason}`:
%%
%% - `{unknown_module, Node, Module}` — модуль узла не загружается;
%% - `{missing_callback, Node, Module, {Function, Arity}}` — модуль не
%%   экспортирует функцию контракта узла;
%% - `{unknown_input_slot, Edge, Node, Slot}` — ребро ведёт в слот, не
%%   объявленный в `Module:input()`;
%% - `{unknown_output_slot, Edge, Node, Slot}` — ребро выходит из слота, не
%%   объявленного в `Module:output()`.
%%
%% Ошибки создания прогона:
%%
%% - `{unknown_input, Name}` — имени нет среди входных полурёбер;
%% - `{duplicate_input, Name}` — имя названо во входе дважды;
%% - `{invalid_input, Name, Item}` — элемент входа не является парой
%%   сообщения и времени глубины узла-получателя;
%% - `{init_crashed, Node, Exception}` — исключение или неверный результат
%%   `init/1`;
%% - `{invalid_notification, Node, Time}` — начальный запрос уведомления
%%   с временем не той глубины, что контекст узла.
-module(ari_local_runtime).

-include("ariadne.hrl").

-export([advance/2, compile/1, inspect/1, new/2, outputs/1, steps/1, violations/1]).
-export_type([
    compile_error/0,
    exception/0,
    execution/0,
    inputs/0,
    new_error/0,
    outputs/0,
    program/0,
    violation/0
]).

-type kind() :: message | ingress | egress | feedback.
-type endpoint() :: {name(), slot()} | undefined.

-type compile_error() ::
    {unknown_module, name(), module()}
    | {missing_callback, name(), module(), {atom(), arity()}}
    | {unknown_input_slot, name(), name(), slot()}
    | {unknown_output_slot, name(), name(), slot()}.

-type inputs() :: [{name(), [{term(), ari_vtime:t()}]}].

-type outputs() :: #{name() => [{term(), ari_vtime:t()}]}.

-type exception() :: {error | exit | throw, term(), [term()]}.

-type new_error() ::
    {unknown_input, name()}
    | {duplicate_input, name()}
    | {invalid_input, name(), term()}
    | {init_crashed, name(), exception()}
    | {invalid_notification, name(), term()}.

-type violation() ::
    {time_rule, name(), message | notification, ari_vtime:t(), ari_vtime:t()}
    | {crash, name(), message | notification, ari_vtime:t(), exception()}
    | {invalid_result, name(), message | notification, ari_vtime:t(), exception()}.

%% Готовый переход: ребро с сообщением или допустимое уведомление.
-type item() :: {edge, name()} | {notify, name(), ari_vtime:t()}.

-record(pnode, {
    module :: module(),
    args :: term(),
    %% Глубина времени узла: число охватывающих циклов.
    depth :: non_neg_integer(),
    %% Рёбра каждого объявленного выходного слота в порядке `edge_order`.
    outputs :: #{slot() => [name()]}
}).

-record(pedge, {
    kind :: kind(),
    loop :: name() | undefined,
    from :: endpoint(),
    to :: endpoint()
}).

-record(program, {
    nodes :: #{name() => #pnode{}},
    edges :: #{name() => #pedge{}},
    edge_order :: [name()],
    node_order :: [name()],
    inputs :: [name()],
    outputs :: [name()],
    %% Антицепь минимальных сводок непустых путей для каждой пары узлов.
    summaries :: #{{name(), name()} => [ari_vtime:summary()]}
}).

-opaque program() :: #program{}.

-record(execution, {
    program :: #program{},
    states :: #{name() => term()},
    queues :: #{name() => queue:queue({term(), ari_vtime:t()})},
    counts :: ari_progress:counts(),
    notify :: ari_progress:requests(),
    ready :: queue:queue(item()),
    %% Уведомления, уже поставленные в `ready`.
    scheduled :: #{{name(), ari_vtime:t()} => true},
    %% Фронтиры `counts` и `notify`; узел из `stale` пересобирается перед
    %% следующей проверкой. До первого запроса в прогоне фронтиры не
    %% поддерживаются: `stale = all`, и первая проверка строит их заново.
    messages :: ari_progress:frontier(),
    requests :: ari_progress:frontier(),
    stale :: all | #{{message | request, name()} => true},
    %% Свидетель каждого заблокированного запроса: время фронтира, которое
    %% его блокирует. Исчезновение свидетеля возвращает запросы в проверку.
    blockers :: #{ari_progress:blocker() => [{name(), ari_vtime:t()}]},
    %% Запросы, ожидающие проверки: новые и освобождённые свидетелем.
    candidates :: [{name(), ari_vtime:t()}],
    steps = 0 :: non_neg_integer(),
    %% Нарушения в обратном порядке: новое в голове списка.
    violations = [] :: [violation()]
}).

-opaque execution() :: #execution{}.

-define(CALLBACKS, [
    {input, 0},
    {output, 0},
    {init, 1},
    {handle_message, 4},
    {handle_notification, 2}
]).

%% @doc Собирает программу из плоского графа.
-spec compile(#graph{}) -> {ok, program()} | {error, compile_error()}.
compile(#graph{nodes = Nodes, edges = Edges}) ->
    try
        {ok, build(Nodes, Edges)}
    catch
        throw:{compile_error, Reason} -> {error, Reason}
    end.

%% @doc Создаёт прогон: вызывает `init/1` узлов в `node_order`, загружает
%% вход, затем наполняет `ready` непустыми входными рёбрами в `edge_order`
%% и допустимыми начальными уведомлениями.
-spec new(program(), inputs()) -> {ok, execution()} | {error, new_error()}.
new(#program{} = Program, Inputs) ->
    try
        {ok, initialize(Program, Inputs)}
    catch
        throw:{new_error, Reason} -> {error, Reason}
    end.

%% @doc Выполняет до `Budget` шагов. `done` означает покой: `ready` пуста,
%% и по свойству допустимости запросов уведомлений тогда не остаётся.
%% `more` — исчерпанный бюджет при оставшейся работе. С `infinity`
%% расходящийся граф не возвращается.
-spec advance(execution(), pos_integer() | infinity) -> {done | more, execution()}.
advance(#execution{ready = Ready} = Execution, 0) ->
    case queue:is_empty(Ready) of
        true -> {done, Execution};
        false -> {more, Execution}
    end;
advance(#execution{} = Execution, Budget) ->
    case step(Execution) of
        none -> {done, Execution};
        {ok, Next} -> advance(Next, spend(Budget))
    end.

spend(infinity) -> infinity;
spend(Budget) -> Budget - 1.

%% @doc Возвращает содержимое выходных полурёбер в порядке очередей.
-spec outputs(execution()) -> outputs().
outputs(#execution{program = #program{outputs = Outputs}, queues = Queues}) ->
    maps:from_list([{Name, queue:to_list(maps:get(Name, Queues))} || Name <- Outputs]).

%% @doc Возвращает нарушения в порядке возникновения.
-spec violations(execution()) -> [violation()].
violations(#execution{violations = Violations}) ->
    lists:reverse(Violations).

%% @doc Возвращает число выполненных переходов.
-spec steps(execution()) -> non_neg_integer().
steps(#execution{steps = Steps}) ->
    Steps.

%% @doc Показывает содержимое программы или прогона в виде map.
-spec inspect(program() | execution()) -> map().
inspect(#execution{} = Execution) ->
    #{
        program => inspect(Execution#execution.program),
        states => Execution#execution.states,
        queues => maps:map(fun(_Name, Queue) -> queue:to_list(Queue) end, Execution#execution.queues),
        counts => Execution#execution.counts,
        notify => Execution#execution.notify,
        ready => queue:to_list(Execution#execution.ready),
        scheduled => Execution#execution.scheduled,
        messages => Execution#execution.messages,
        requests => Execution#execution.requests,
        stale => Execution#execution.stale,
        blockers => Execution#execution.blockers,
        candidates => Execution#execution.candidates,
        steps => Execution#execution.steps,
        violations => lists:reverse(Execution#execution.violations)
    };
inspect(#program{} = Program) ->
    #{
        nodes => maps:map(fun(_Name, Node) -> inspect_node(Node) end, Program#program.nodes),
        edges => maps:map(fun(_Name, Edge) -> inspect_edge(Edge) end, Program#program.edges),
        edge_order => Program#program.edge_order,
        node_order => Program#program.node_order,
        inputs => Program#program.inputs,
        outputs => Program#program.outputs,
        summaries => Program#program.summaries
    }.

inspect_node(#pnode{module = Module, args = Args, depth = Depth, outputs = Outputs}) ->
    #{module => Module, args => Args, depth => Depth, outputs => Outputs}.

inspect_edge(#pedge{kind = Kind, loop = Loop, from = From, to = To}) ->
    #{kind => Kind, loop => Loop, from => From, to => To}.

build(Nodes, Edges) ->
    NodeOrder = lists:sort([Node#node.name || Node <- Nodes]),
    Slots = maps:from_list([{Node#node.name, node_slots(Node)} || Node <- Nodes]),
    PEdges = maps:from_list([{edge_name(Edge), pedge(Edge)} || Edge <- Edges]),
    EdgeOrder = lists:sort(maps:keys(PEdges)),
    lists:foreach(fun(Name) -> validate_slots(Name, maps:get(Name, PEdges), Slots) end, EdgeOrder),
    PNodes = maps:from_list([
        {Node#node.name, pnode(Node, maps:get(Node#node.name, Slots), EdgeOrder, PEdges)}
     || Node <- Nodes
    ]),
    #program{
        nodes = PNodes,
        edges = PEdges,
        edge_order = EdgeOrder,
        node_order = NodeOrder,
        inputs = [Name || Name <- EdgeOrder, (maps:get(Name, PEdges))#pedge.from =:= undefined],
        outputs = [Name || Name <- EdgeOrder, (maps:get(Name, PEdges))#pedge.to =:= undefined],
        summaries = summaries(EdgeOrder, PEdges)
    }.

%% @doc Считает минимальные сводки непустых путей. Начальные сводки берутся
%% из рёбер с обоими концами; каждая сводка, попавшая в таблицу,
%% продолжается каждым ребром из своего конца, пока список необработанных
%% не опустеет. Доминируемые сводки отбрасываются, поэтому лишние обороты
%% циклов вычисление не продлевают. Продолжение сводки, вытесненной позже,
%% доминируется продолжением вытеснившей и таблицы не меняет.
summaries(EdgeOrder, Edges) ->
    Arcs = lists:foldr(
        fun(Name, Acc) ->
            case maps:get(Name, Edges) of
                #pedge{kind = Kind, from = {From, _}, to = {To, _}} ->
                    maps:update_with(From, fun(Out) -> [{To, Kind} | Out] end, [{To, Kind}], Acc);
                #pedge{} ->
                    Acc
            end
        end,
        #{},
        EdgeOrder
    ),
    Initial = [
        {From, To, ari_vtime:summary(Kind)}
     || From <- lists:sort(maps:keys(Arcs)), {To, Kind} <- maps:get(From, Arcs)
    ],
    extend_summaries(Initial, #{}, Arcs).

extend_summaries([], Table, _Arcs) ->
    Table;
extend_summaries([{From, Via, Summary} | Pending], Table, Arcs) ->
    case add_summary({From, Via}, Summary, Table) of
        Table ->
            extend_summaries(Pending, Table, Arcs);
        Extended ->
            Next = [
                {From, To, ari_vtime:compose(Summary, ari_vtime:summary(Kind))}
             || {To, Kind} <- maps:get(Via, Arcs, [])
            ],
            extend_summaries(Next ++ Pending, Extended, Arcs)
    end.

%% @doc Добавляет сводку в антицепь пары узлов. Антицепь хранится
%% отсортированным списком, поэтому равные таблицы равны структурно.
add_summary(Key, Summary, Table) ->
    Summaries = maps:get(Key, Table, []),
    case lists:any(fun(Known) -> ari_vtime:dominates(Known, Summary) end, Summaries) of
        true ->
            Table;
        false ->
            Kept = [Known || Known <- Summaries, not ari_vtime:dominates(Summary, Known)],
            maps:put(Key, lists:sort([Summary | Kept]), Table)
    end.

%% @doc Проверяет модуль узла и возвращает его объявленные слоты.
node_slots(#node{name = Name, module = Module}) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> ok;
        {error, _Reason} -> invalid({unknown_module, Name, Module})
    end,
    lists:foreach(
        fun({Function, Arity} = Callback) ->
            case erlang:function_exported(Module, Function, Arity) of
                true -> ok;
                false -> invalid({missing_callback, Name, Module, Callback})
            end
        end,
        ?CALLBACKS
    ),
    {Module:input(), Module:output()}.

%% @doc Строит индекс маршрутизации узла. Объявленный выходной слот без
%% рёбер получает пустой список, чем отличается от неизвестного слота.
pnode(#node{name = Name, module = Module, args = Args, context = Context}, {_Inputs, Outputs}, EdgeOrder, Edges) ->
    #pnode{
        module = Module,
        args = Args,
        depth = length(Context),
        outputs = slot_edges(Name, Outputs, EdgeOrder, Edges)
    }.

slot_edges(Node, Slots, EdgeOrder, Edges) ->
    Empty = maps:from_list([{Slot, []} || Slot <- Slots]),
    lists:foldr(
        fun(Name, Acc) ->
            case (maps:get(Name, Edges))#pedge.from of
                {Node, Slot} -> maps:update_with(Slot, fun(Names) -> [Name | Names] end, Acc);
                _Other -> Acc
            end
        end,
        Empty,
        EdgeOrder
    ).

validate_slots(Name, #pedge{from = From, to = To}, Slots) ->
    validate_slot(Name, From, output, Slots),
    validate_slot(Name, To, input, Slots).

validate_slot(_Name, undefined, _Direction, _Slots) ->
    ok;
validate_slot(Name, {Node, Slot}, Direction, Slots) ->
    {Inputs, Outputs} = maps:get(Node, Slots),
    {Declared, Reason} =
        case Direction of
            input -> {Inputs, unknown_input_slot};
            output -> {Outputs, unknown_output_slot}
        end,
    case lists:member(Slot, Declared) of
        true -> ok;
        false -> invalid({Reason, Name, Node, Slot})
    end.

pedge(#edge{from = From, to = To}) ->
    #pedge{kind = message, from = From, to = To};
pedge(#ingress{loop = Loop, from = From, to = To}) ->
    #pedge{kind = ingress, loop = Loop, from = From, to = To};
pedge(#egress{loop = Loop, from = From, to = To}) ->
    #pedge{kind = egress, loop = Loop, from = From, to = To};
pedge(#feedback{loop = Loop, from = From, to = To}) ->
    #pedge{kind = feedback, loop = Loop, from = From, to = To}.

edge_name(#edge{name = Name}) -> Name;
edge_name(#ingress{name = Name}) -> Name;
edge_name(#egress{name = Name}) -> Name;
edge_name(#feedback{name = Name}) -> Name.

invalid(Reason) ->
    throw({compile_error, Reason}).

%% Создание прогона.

initialize(#program{node_order = NodeOrder} = Program, Inputs) ->
    validate_inputs(Program, Inputs, []),
    {States, Notify, Candidates} = lists:foldl(
        fun(Name, {States, Notify, Candidates}) ->
            {State, Requests} = init_node(Name, maps:get(Name, Program#program.nodes)),
            {Added, NewNotify} = put_requests(Name, Requests, Notify),
            {States#{Name => State}, NewNotify, [{Name, Time} || Time <- Added] ++ Candidates}
        end,
        {#{}, #{}, []},
        NodeOrder
    ),
    {Queues, Counts} = load_inputs(Program, Inputs),
    Ready = queue:from_list([
        {edge, Name}
     || Name <- Program#program.inputs, not queue:is_empty(maps:get(Name, Queues))
    ]),
    schedule(#execution{
        program = Program,
        states = States,
        queues = Queues,
        counts = Counts,
        notify = Notify,
        ready = Ready,
        scheduled = #{},
        messages = #{},
        requests = #{},
        stale = all,
        blockers = #{},
        candidates = Candidates
    }).

validate_inputs(_Program, [], _Seen) ->
    ok;
validate_inputs(#program{inputs = Inputs} = Program, [{Name, Messages} | Rest], Seen) ->
    lists:member(Name, Inputs) orelse rejected({unknown_input, Name}),
    lists:member(Name, Seen) andalso rejected({duplicate_input, Name}),
    Depth = target_depth(Program, Name),
    lists:foreach(
        fun({_Message, Time} = Item) ->
            ari_vtime:valid(Time, Depth) orelse rejected({invalid_input, Name, Item})
        end,
        Messages
    ),
    validate_inputs(Program, Rest, [Name | Seen]).

target_depth(#program{edges = Edges, nodes = Nodes}, EdgeName) ->
    #pedge{to = {Node, _Slot}} = maps:get(EdgeName, Edges),
    (maps:get(Node, Nodes))#pnode.depth.

%% @doc Вызывает `init/1` узла. Исключение и результат не той формы дают
%% `init_crashed`, запрос времени чужой глубины — `invalid_notification`.
init_node(Name, #pnode{module = Module, args = Args, depth = Depth}) ->
    {State, Requests} =
        try
            case Module:init(Args) of
                {_State, _Requests} = Result when is_list(_Requests) -> Result;
                Other -> erlang:error({badmatch, Other})
            end
        catch
            Class:Reason:Stack ->
                rejected({init_crashed, Name, {Class, Reason, Stack}})
        end,
    lists:foreach(
        fun(Time) ->
            ari_vtime:valid(Time, Depth) orelse rejected({invalid_notification, Name, Time})
        end,
        Requests
    ),
    {State, Requests}.

%% @doc Добавляет запросы узла в `notify` и возвращает новые времена;
%% узлы без запросов ключа не имеют.
put_requests(Name, Requests, Notify) ->
    Known = maps:get(Name, Notify, ordsets:new()),
    case ordsets:union(ordsets:from_list(Requests), Known) of
        Known -> {[], Notify};
        Merged -> {ordsets:subtract(Merged, Known), maps:put(Name, Merged, Notify)}
    end.

%% @doc Записывает запрос узла: кладёт в `notify`, фронтир запросов и
%% кандидаты на проверку; повторный запрос известного времени ничего не
%% меняет.
request(Node, Time, #execution{notify = Notify} = Execution) ->
    case put_requests(Node, [Time], Notify) of
        {[], Notify} ->
            Execution;
        {[Time], Updated} ->
            Inserted = insert(request, Node, Time, Execution#execution{notify = Updated}),
            Inserted#execution{candidates = [{Node, Time} | Inserted#execution.candidates]}
    end.

%% Фронтиры.

%% @doc Добавляет время в фронтир узла. Свидетели вытесненных времён
%% переходят к новому: меньшее время блокирует всё, что блокировали они.
%% Устаревший фронтир узла пересобирается целиком, и вставка пропускается.
insert(_Kind, _Node, _Time, #execution{stale = all} = Execution) ->
    Execution;
insert(Kind, Node, Time, #execution{stale = Stale, blockers = Blockers} = Execution) ->
    case maps:is_key({Kind, Node}, Stale) of
        true ->
            Execution;
        false ->
            {Frontier, Dropped} = ari_progress:insert(Node, Time, frontier(Kind, Execution)),
            Moved = lists:foldl(
                fun(Old, Acc) ->
                    case maps:take({Kind, Node, Old}, Acc) of
                        error -> Acc;
                        {Witnessed, Rest} -> maps:update_with({Kind, Node, Time}, fun(Known) -> Witnessed ++ Known end, Witnessed, Rest)
                    end
                end,
                Blockers,
                Dropped
            ),
            set_frontier(Kind, Frontier, Execution#execution{blockers = Moved})
    end.

%% @doc Учитывает исчезновение времени узла: запросы, которым оно
%% свидетельствовало блокировку, возвращаются в кандидаты, а фронтир узла
%% помечается устаревшим. Сообщение снимается с ребра в порядке очереди и
%% минимальным обычно не является, поэтому фронтир сообщений помечается,
%% только если время в него входило: исчезновение неминимального времени
%% минимумов не меняет. Запрос исполняется допустимым и обычно минимален,
%% и его снятие помечает узел без обхода фронтира. До первого запроса
%% свидетелей нет и помечать нечего.
release(_Kind, _Node, _Time, #execution{stale = all} = Execution) ->
    Execution;
release(Kind, Node, Time, #execution{stale = Stale, blockers = Blockers} = Execution) ->
    {Released, Rest} =
        case maps:take({Kind, Node, Time}, Blockers) of
            error -> {[], Blockers};
            Taken -> Taken
        end,
    Marked =
        case Kind =:= request orelse lists:member(Time, maps:get(Node, frontier(message, Execution), [])) of
            true -> Stale#{{Kind, Node} => true};
            false -> Stale
        end,
    Execution#execution{
        stale = Marked,
        blockers = Rest,
        candidates = Released ++ Execution#execution.candidates
    }.

%% @doc Пересобирает устаревшие фронтиры. Время, выпавшее из фронтира при
%% пересборке, освобождает своих свидетельствуемых: их блокирует меньшее
%% время, всплывшее на его место, и проверка найдёт нового свидетеля.
refresh(#execution{stale = all} = Execution) ->
    Execution#execution{
        messages = exact(message, Execution),
        requests = exact(request, Execution),
        stale = #{}
    };
refresh(#execution{stale = Stale} = Execution) ->
    Rebuilt = maps:fold(
        fun({Kind, Node}, true, Acc) ->
            Old = maps:get(Node, frontier(Kind, Acc), []),
            New = ari_progress:minimal(times(Kind, Node, Acc)),
            Released = lists:foldl(
                fun(Time, Inner) ->
                    case lists:member(Time, New) of
                        true -> Inner;
                        false -> release(Kind, Node, Time, Inner)
                    end
                end,
                Acc,
                Old
            ),
            Frontier = frontier(Kind, Released),
            Updated =
                case New of
                    [] -> maps:remove(Node, Frontier);
                    _ -> maps:put(Node, New, Frontier)
                end,
            set_frontier(Kind, Updated, Released)
        end,
        Execution,
        Stale
    ),
    Rebuilt#execution{stale = #{}}.

exact(message, #execution{counts = Counts}) -> ari_progress:message_frontier(Counts);
exact(request, #execution{notify = Notify}) -> ari_progress:request_frontier(Notify).

%% @doc Времена узла среди живых сообщений или запросов.
times(message, Node, #execution{counts = Counts}) -> maps:keys(maps:get(Node, Counts, #{}));
times(request, Node, #execution{notify = Notify}) -> maps:get(Node, Notify, []).

frontier(message, #execution{messages = Messages}) -> Messages;
frontier(request, #execution{requests = Requests}) -> Requests.

set_frontier(message, Frontier, Execution) -> Execution#execution{messages = Frontier};
set_frontier(request, Frontier, Execution) -> Execution#execution{requests = Frontier}.

%% @doc Заводит очередь на каждое ребро и кладёт вход во входные очереди,
%% считая сообщения по pointstamp'ам узла-получателя.
load_inputs(#program{edge_order = EdgeOrder, edges = Edges}, Inputs) ->
    Empty = maps:from_list([{Name, queue:new()} || Name <- EdgeOrder]),
    lists:foldl(
        fun({Name, Messages}, {Queues, Counts}) ->
            #pedge{to = {Node, _Slot}} = maps:get(Name, Edges),
            NewCounts = lists:foldl(
                fun({_Message, Time}, Acc) -> increment(Node, Time, Acc) end,
                Counts,
                Messages
            ),
            {maps:put(Name, queue:from_list(Messages), Queues), NewCounts}
        end,
        {Empty, #{}},
        Inputs
    ).

increment(Node, Time, Counts) ->
    Times = maps:get(Node, Counts, #{}),
    maps:put(Node, maps:update_with(Time, fun(Count) -> Count + 1 end, 1, Times), Counts).

%% @doc Ставит в хвост `ready` допустимые кандидаты: узлы в `node_order`,
%% времена внутри узла в порядке термов — порядок термов пар даёт то же.
%% Заблокированный кандидат получает свидетеля и ждёт его исчезновения.
%% Без кандидатов проверять нечего, и устаревшие фронтиры ждут следующей
%% проверки.
schedule(#execution{candidates = []} = Execution) ->
    Execution;
schedule(#execution{} = Execution) ->
    Refreshed = refresh(Execution),
    Candidates = lists:usort(Refreshed#execution.candidates),
    check(Candidates, Refreshed#execution{candidates = []}).

check(Candidates, #execution{program = Program, messages = Messages, requests = Requests} = Execution) ->
    #program{summaries = Summaries} = Program,
    lists:foldl(
        fun({Name, Time} = Request, #execution{scheduled = Scheduled, ready = Ready} = Acc) ->
            case ari_progress:blocker(Name, Time, Messages, Requests, Summaries) of
                none ->
                    Acc#execution{
                        ready = queue:in({notify, Name, Time}, Ready),
                        scheduled = Scheduled#{Request => true}
                    };
                Blocker ->
                    Acc#execution{
                        blockers = maps:update_with(
                            Blocker, fun(Known) -> [Request | Known] end, [Request], Acc#execution.blockers
                        )
                    }
            end
        end,
        Execution,
        Candidates
    ).

rejected(Reason) ->
    throw({new_error, Reason}).

%% Шаг.

%% @doc Выполняет один переход с головы `ready`. Возвращает `none`, если
%% переходов нет.
step(#execution{ready = Ready} = Execution) ->
    case queue:out(Ready) of
        {empty, _} ->
            none;
        {{value, Item}, Rest} ->
            Next = transition(Item, Execution#execution{ready = Rest}),
            {ok, Next#execution{steps = Next#execution.steps + 1}}
    end.

%% @doc Снимает сообщение с ребра и отдаёт узлу-получателю. Обработанное
%% ребро возвращается в хвост `ready`, если в нём остались сообщения.
%% Проверка запросов идёт после применения результата и только если
%% исчез ключ `counts`.
transition({edge, Name}, #execution{program = Program} = Execution) ->
    #pedge{to = {Node, Slot}} = maps:get(Name, Program#program.edges),
    {{value, {Message, Time}}, Queue} = queue:out(maps:get(Name, Execution#execution.queues)),
    {Consumed, Removed} = consume({Node, Time}, Execution#execution{queues = maps:put(Name, Queue, Execution#execution.queues)}),
    Callback = fun(Module, State) -> Module:handle_message(Slot, Message, Time, State) end,
    Applied = invoke(Node, message, Time, Callback, Consumed),
    Requeued =
        case queue:is_empty(Queue) of
            true -> Applied;
            false -> Applied#execution{ready = queue:in({edge, Name}, Applied#execution.ready)}
        end,
    case Removed of
        true -> schedule(Requeued);
        false -> Requeued
    end;
%% @doc Снимает запрос и отметку `scheduled` и вызывает обработчик
%% уведомления. Снятие запроса всегда запускает проверку ожидающих.
transition({notify, Node, Time}, #execution{notify = Notify, scheduled = Scheduled} = Execution) ->
    Consumed = release(request, Node, Time, Execution#execution{
        notify = remove_request(Node, Time, Notify),
        scheduled = maps:remove({Node, Time}, Scheduled)
    }),
    Callback = fun(Module, State) -> Module:handle_notification(Time, State) end,
    schedule(invoke(Node, notification, Time, Callback, Consumed)).

%% @doc Вызывает callback узла и применяет его результат. Исключение в
%% callback даёт `crash`, исключение при применении — `invalid_result`;
%% в обоих случаях состояние узла и очереди остаются как после потребления
%% события.
invoke(Node, Kind, Time, Callback, #execution{program = Program, states = States} = Execution) ->
    #pnode{module = Module} = maps:get(Node, Program#program.nodes),
    State = maps:get(Node, States),
    try Callback(Module, State) of
        Result ->
            case apply_result(Node, Kind, Time, Result, Execution) of
                {ok, Applied} ->
                    Applied;
                {error, Exception} ->
                    violate({invalid_result, Node, Kind, Time, Exception}, Execution)
            end
    catch
        Class:Reason:Stack ->
            violate({crash, Node, Kind, Time, {Class, Reason, Stack}}, Execution)
    end.

%% @doc Строит новое состояние исполнения из результата callback за один
%% проход. Время каждого запроса и выхода сверяется с временем входа;
%% нарушители отбрасываются с `time_rule`, остальное применяется.
apply_result(Node, Kind, Time, Result, #execution{program = Program} = Execution) ->
    #pnode{depth = Depth, outputs = Outputs} = maps:get(Node, Program#program.nodes),
    try
        {State, Requests, Emitted} = Result,
        WithRequests = lists:foldl(
            fun(Requested, Acc) ->
                case allowed(Time, Requested, Depth) of
                    true ->
                        request(Node, Requested, Acc);
                    false ->
                        violate({time_rule, Node, Kind, Time, Requested}, Acc)
                end
            end,
            Execution,
            Requests
        ),
        WithOutputs = lists:foldl(
            fun({Slot, Message, Stamp}, Acc) ->
                case allowed(Time, Stamp, Depth) of
                    true ->
                        Edges = maps:get(Slot, Outputs),
                        lists:foldl(
                            fun(Edge, Inner) -> deliver(Edge, Message, Stamp, Inner) end,
                            Acc,
                            Edges
                        );
                    false ->
                        violate({time_rule, Node, Kind, Time, Stamp}, Acc)
                end
            end,
            WithRequests,
            Emitted
        ),
        {ok, WithOutputs#execution{states = maps:put(Node, State, WithOutputs#execution.states)}}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

%% @doc Проверяет время результата: оно имеет форму времени глубины узла
%% и не раньше входного. Время не той формы — исключение и `invalid_result`.
allowed(InputTime, Time, Depth) ->
    ari_vtime:valid(Time, Depth) orelse erlang:error({invalid_time, Time}),
    ari_vtime:le(InputTime, Time).

%% @doc Кладёт сообщение в очередь ребра, преобразуя время по виду ребра.
%% Ребро с получателем учитывается в `counts` и встаёт в `ready`, если его
%% очередь была пуста.
deliver(Name, Message, Time, #execution{program = Program, queues = Queues} = Execution) ->
    #pedge{kind = Kind, to = To} = maps:get(Name, Program#program.edges),
    Arrival = transform(Kind, Time),
    Queue = maps:get(Name, Queues),
    Delivered = Execution#execution{queues = maps:put(Name, queue:in({Message, Arrival}, Queue), Queues)},
    case To of
        undefined ->
            Delivered;
        {Node, _Slot} ->
            Counted = produce({Node, Arrival}, Delivered),
            case queue:is_empty(Queue) of
                true -> Counted#execution{ready = queue:in({edge, Name}, Counted#execution.ready)};
                false -> Counted
            end
    end.

transform(message, Time) -> Time;
transform(ingress, Time) -> ari_vtime:ingress(Time);
transform(feedback, Time) -> ari_vtime:feedback(Time);
transform(egress, Time) -> ari_vtime:egress(Time).

%% @doc Учитывает новое сообщение в `counts`; новый ключ входит в фронтир
%% сообщений, если его не доминирует известное время.
produce({Node, Time}, #execution{counts = Counts} = Execution) ->
    Counted = Execution#execution{counts = increment(Node, Time, Counts)},
    case maps:is_key(Time, maps:get(Node, Counts, #{})) of
        true -> Counted;
        false -> insert(message, Node, Time, Counted)
    end.

%% @doc Снимает сообщение со счёта и сообщает, исчез ли ключ. Исчезнувший
%% ключ освобождает запросы, которым свидетельствовал.
consume({Node, Time}, #execution{counts = Counts} = Execution) ->
    Times = maps:get(Node, Counts),
    case maps:get(Time, Times) of
        1 ->
            Remaining =
                case maps:remove(Time, Times) of
                    Empty when map_size(Empty) =:= 0 -> maps:remove(Node, Counts);
                    Rest -> maps:put(Node, Rest, Counts)
                end,
            {release(message, Node, Time, Execution#execution{counts = Remaining}), true};
        Count ->
            {Execution#execution{counts = maps:put(Node, maps:put(Time, Count - 1, Times), Counts)}, false}
    end.

remove_request(Node, Time, Notify) ->
    case ordsets:del_element(Time, maps:get(Node, Notify)) of
        [] -> maps:remove(Node, Notify);
        Rest -> maps:put(Node, Rest, Notify)
    end.

violate(Violation, #execution{violations = Violations} = Execution) ->
    Execution#execution{violations = [Violation | Violations]}.
