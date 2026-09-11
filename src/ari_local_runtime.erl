%% @doc Исполняет граф целиком внутри одного Erlang-процесса.
%%
%% `compile/1` переводит плоский `#graph{}` в неизменную программу:
%% проверяет модули узлов и слоты на концах рёбер, строит индексы
%% маршрутизации, фиксирует стабильные порядки узлов и рёбер и считает
%% минимальные сводки непустых путей между узлами.
%%
%% `new/2` создаёт прогон по программе: вызывает `init/1` каждого узла,
%% наполняет входные очереди и ставит в `ready` начальные переходы.
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

-export([compile/1, inspect/1, new/2]).
-export_type([
    compile_error/0,
    exception/0,
    execution/0,
    inputs/0,
    new_error/0,
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
    outputs :: #{slot() => [name()]},
    %% Рёбра каждого объявленного входного слота в порядке `edge_order`.
    inputs :: #{slot() => [name()]}
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
    steps = 0 :: non_neg_integer(),
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
        steps => Execution#execution.steps,
        violations => Execution#execution.violations
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

inspect_node(#pnode{module = Module, args = Args, depth = Depth, outputs = Outputs, inputs = Inputs}) ->
    #{module => Module, args => Args, depth => Depth, outputs => Outputs, inputs => Inputs}.

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
%% из рёбер с обоими концами; каждый найденный путь продолжается ещё одним
%% ребром до неподвижной точки. Доминируемые сводки отбрасываются, поэтому
%% лишние обороты циклов вычисление не продлевают.
summaries(EdgeOrder, Edges) ->
    Arcs = [
        {From, To, Kind}
     || Name <- EdgeOrder,
        #pedge{kind = Kind, from = {From, _}, to = {To, _}} <- [maps:get(Name, Edges)]
    ],
    Initial = lists:foldl(
        fun({From, To, Kind}, Table) ->
            add_summary({From, To}, ari_vtime:summary(Kind), Table)
        end,
        #{},
        Arcs
    ),
    extend_summaries(Initial, Arcs).

extend_summaries(Table, Arcs) ->
    Extended = maps:fold(
        fun({From, Via}, Summaries, Acc) ->
            lists:foldl(
                fun({Summary, {_Via, To, Kind}}, Inner) ->
                    Composed = ari_vtime:compose(Summary, ari_vtime:summary(Kind)),
                    add_summary({From, To}, Composed, Inner)
                end,
                Acc,
                [{Summary, Arc} || Summary <- Summaries, {V, _, _} = Arc <- Arcs, V =:= Via]
            )
        end,
        Table,
        Table
    ),
    case Extended =:= Table of
        true -> Table;
        false -> extend_summaries(Extended, Arcs)
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

%% @doc Строит индексы маршрутизации узла. Объявленный слот без рёбер
%% получает пустой список, чем отличается от неизвестного слота.
pnode(#node{name = Name, module = Module, args = Args, context = Context}, {Inputs, Outputs}, EdgeOrder, Edges) ->
    #pnode{
        module = Module,
        args = Args,
        depth = length(Context),
        outputs = slot_edges(Name, Outputs, #pedge.from, EdgeOrder, Edges),
        inputs = slot_edges(Name, Inputs, #pedge.to, EdgeOrder, Edges)
    }.

slot_edges(Node, Slots, Field, EdgeOrder, Edges) ->
    Empty = maps:from_list([{Slot, []} || Slot <- Slots]),
    lists:foldr(
        fun(Name, Acc) ->
            case element(Field, maps:get(Name, Edges)) of
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
    {States, Notify} = lists:foldl(
        fun(Name, {States, Notify}) ->
            {State, Requests} = init_node(Name, maps:get(Name, Program#program.nodes)),
            {States#{Name => State}, put_requests(Name, Requests, Notify)}
        end,
        {#{}, #{}},
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
        scheduled = #{}
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

%% @doc Добавляет запросы узла в `notify`; узлы без запросов ключа не имеют.
put_requests(_Name, [], Notify) ->
    Notify;
put_requests(Name, Requests, Notify) ->
    Known = maps:get(Name, Notify, ordsets:new()),
    maps:put(Name, ordsets:union(ordsets:from_list(Requests), Known), Notify).

%% @doc Заводит очередь на каждое ребро и кладёт вход во входные очереди,
%% считая сообщения по pointstamp'ам узла-получателя.
load_inputs(#program{edge_order = EdgeOrder, edges = Edges}, Inputs) ->
    Empty = maps:from_list([{Name, queue:new()} || Name <- EdgeOrder]),
    lists:foldl(
        fun({Name, Messages}, {Queues, Counts}) ->
            #pedge{to = {Node, _Slot}} = maps:get(Name, Edges),
            NewCounts = lists:foldl(
                fun({_Message, Time}, Acc) -> increment({Node, Time}, Acc) end,
                Counts,
                Messages
            ),
            {maps:put(Name, queue:from_list(Messages), Queues), NewCounts}
        end,
        {Empty, #{}},
        Inputs
    ).

increment(Key, Counts) ->
    maps:update_with(Key, fun(Count) -> Count + 1 end, 1, Counts).

%% @doc Ставит в хвост `ready` допустимые запросы, ещё не поставленные:
%% узлы в `node_order`, времена внутри узла в порядке термов.
schedule(#execution{program = Program, notify = Notify} = Execution) ->
    #program{node_order = NodeOrder, summaries = Summaries} = Program,
    lists:foldl(
        fun(Name, Acc) ->
            lists:foldl(
                fun(Time, #execution{scheduled = Scheduled, ready = Ready} = Inner) ->
                    case
                        not maps:is_key({Name, Time}, Scheduled) andalso
                            ari_progress:admissible(Name, Time, Inner#execution.counts, Notify, Summaries)
                    of
                        true ->
                            Inner#execution{
                                ready = queue:in({notify, Name, Time}, Ready),
                                scheduled = Scheduled#{{Name, Time} => true}
                            };
                        false ->
                            Inner
                    end
                end,
                Acc,
                maps:get(Name, Notify, [])
            )
        end,
        Execution,
        NodeOrder
    ).

rejected(Reason) ->
    throw({new_error, Reason}).
