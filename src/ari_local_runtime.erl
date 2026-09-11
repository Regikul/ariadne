%% @doc Исполняет граф целиком внутри одного Erlang-процесса.
%%
%% `compile/1` переводит плоский `#graph{}` в неизменную программу:
%% проверяет модули узлов и слоты на концах рёбер, строит индексы
%% маршрутизации, фиксирует стабильные порядки узлов и рёбер и считает
%% минимальные сводки непустых путей между узлами.
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
-module(ari_local_runtime).

-include("ariadne.hrl").

-export([compile/1, inspect/1]).
-export_type([compile_error/0, program/0]).

-type kind() :: message | ingress | egress | feedback.
-type endpoint() :: {name(), slot()} | undefined.

-type compile_error() ::
    {unknown_module, name(), module()}
    | {missing_callback, name(), module(), {atom(), arity()}}
    | {unknown_input_slot, name(), name(), slot()}
    | {unknown_output_slot, name(), name(), slot()}.

-record(pnode, {
    module :: module(),
    args :: term(),
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

%% @doc Показывает содержимое программы в виде map.
-spec inspect(program()) -> map().
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

inspect_node(#pnode{module = Module, args = Args, outputs = Outputs, inputs = Inputs}) ->
    #{module => Module, args => Args, outputs => Outputs, inputs => Inputs}.

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
pnode(#node{name = Name, module = Module, args = Args}, {Inputs, Outputs}, EdgeOrder, Edges) ->
    #pnode{
        module = Module,
        args = Args,
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
