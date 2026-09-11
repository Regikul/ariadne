%% @doc Предоставляет DSL для описания и структурной сборки dataflow-графа.
%%
%% `node/3`, `in/2`, `edge/3`, `out/2`, `loop/2` и `feedback/3` создают
%% элементы сырого описания. `graph/1` раскрывает циклы и возвращает плоский
%% `#graph{nodes, edges}`.
%%
%% При раскрытии цикла одноимённые внешнее `out` и внутреннее `in`
%% преобразуются в `#ingress{}`, а внутреннее `out` и внешнее `in` —
%% в `#egress{}`. Feedback-рёбра связываются с содержащим их циклом.
%%
%% Сборка проверяет уникальность имён, существование узлов на концах рёбер
%% и ацикличность каждого контекста со свёрнутыми вложенными циклами,
%% исключая собственные feedback-рёбра. Проверяется и плоский граф. Несовмещённые
%% полурёбра цикла являются ошибкой.
%%
%% Каждый узел получает `#node.context` — список охватывающих циклов,
%% внутренний первым. Глубина времени узла равна длине этого списка.
%%
%% Модули узлов и соответствие слотов callbacks здесь не проверяются:
%% это ответственность сборки runtime.
%%
%% Некорректное описание завершается исключением
%% `error({invalid_graph, Reason})`.
-module(ari_graph).

-include("ariadne.hrl").

-export([edge/3, feedback/3, graph/1, in/2, loop/2, node/3, out/2]).

-type endpoint() :: {name(), slot()}.

%% @doc Создаёт описание узла.
-spec node(name(), module(), term()) -> #node{}.
node(Name, Module, Args) ->
    #node{name = Name, module = Module, args = Args}.

%% @doc Создаёт входное полуребро графа или цикла.
-spec in(name(), endpoint()) -> #edge{}.
in(Name, To) ->
    #edge{name = Name, to = To}.

%% @doc Создаёт обычное внутреннее ребро.
-spec edge(name(), endpoint(), endpoint()) -> #edge{}.
edge(Name, From, To) ->
    #edge{name = Name, from = From, to = To}.

%% @doc Создаёт выходное полуребро графа или цикла.
-spec out(name(), endpoint()) -> #edge{}.
out(Name, From) ->
    #edge{name = Name, from = From}.

%% @doc Создаёт ребро перехода к следующей итерации цикла.
-spec feedback(name(), endpoint(), endpoint()) -> #feedback{}.
feedback(Name, From, To) ->
    #feedback{name = Name, from = From, to = To}.

%% @doc Группирует сырой список элементов во временной контекст цикла.
-spec loop(name(), list()) -> #loop{}.
loop(Name, Items) when is_list(Items) ->
    #loop{name = Name, items = Items}.

%% @doc Собирает, раскрывает и проверяет описание графа.
-spec graph(list()) -> #graph{}.
graph(Items) when is_list(Items) ->
    {Nodes, Edges, Loops} = build(Items, []),
    validate_graph(Nodes, Edges, Loops),
    #graph{nodes = Nodes, edges = Edges}.

%% @doc Собирает один контекст и возвращает его плоские узлы, рёбра и циклы.
%% `Context` — список охватывающих циклов, внутренний первым.
build(Items, Context) ->
    {RawNodes, Rest} = lists:partition(fun(Item) -> is_record(Item, node) end, Items),
    Nodes = [Node#node{context = Context} || Node <- RawNodes],
    {Loops, RawEdges} = lists:partition(fun(Item) -> is_record(Item, loop) end, Rest),
    NodeNames = [Node#node.name || Node <- Nodes],
    Edges = [prepare_edge(Edge, NodeNames, Context) || Edge <- RawEdges],
    {LoopNodes, LoopEdges, LoopNames, RemainingEdges, LoopOwners} =
        build_loops(Loops, Edges, Context),
    AllEdges = RemainingEdges ++ LoopEdges,
    Owners = maps:merge(LoopOwners, maps:from_list([{Name, {node, Name}} || Name <- NodeNames])),
    ensure_context_acyclic(Context, Owners, AllEdges),
    {Nodes ++ LoopNodes, AllEdges, LoopNames}.

%% @doc Раскрывает циклы и соединяет их полурёбра с текущим контекстом.
build_loops([], Edges, _Context) ->
    {[], [], [], Edges, #{}};
build_loops([#loop{name = Name, items = Items} | Rest], Edges, Context) ->
    {Nodes, InnerEdges, InnerLoops} = build(Items, [Name | Context]),
    {ResolvedEdges, RemainingEdges} = resolve_boundaries(Name, InnerEdges, Edges),
    {RestNodes, RestEdges, RestLoops, FinalEdges, RestOwners} =
        build_loops(Rest, RemainingEdges, Context),
    {
        Nodes ++ RestNodes,
        ResolvedEdges ++ RestEdges,
        [Name | InnerLoops] ++ RestLoops,
        FinalEdges,
        maps:merge(RestOwners, maps:from_list([
            {Node#node.name, {loop, Name}} || Node <- Nodes
        ]))
    }.

%% @doc Сворачивает потомков каждого вложенного цикла в одну вершину.
%% Внутренние рёбра этих вершин уже проверены в дочерних контекстах.
%% Метки node/loop разделяют пространства имён узлов и циклов.
ensure_context_acyclic(Context, Owners, Edges) ->
    Names = lists:usort(maps:values(Owners)),
    Arcs = lists:filtermap(
        fun(Edge) ->
            case arc(Edge) of
                {true, {From, To}} ->
                    Source = maps:get(From, Owners),
                    Target = maps:get(To, Owners),
                    case {Source, Target} of
                        {{loop, Loop}, {loop, Loop}} -> false;
                        _ -> {true, {Source, Target}}
                    end;
                false -> false
            end
        end,
        Edges
    ),
    case acyclic(Names, Arcs) of
        true -> ok;
        false -> invalid({cycle_without_feedback, context_label(Context)})
    end.

prepare_edge(Edge, Nodes, Context) ->
    validate_edge(Edge, Nodes, Context),
    bind_feedback(Edge, Context).

bind_feedback(Edge = #feedback{}, [Loop | _]) ->
    Edge#feedback{loop = Loop};
bind_feedback(Edge, _Context) ->
    Edge.

resolve_boundaries(Loop, InnerEdges, OuterEdges) ->
    resolve_boundaries(Loop, InnerEdges, OuterEdges, []).

%% @doc Заменяет пересечения границы цикла на ingress- и egress-рёбра.
resolve_boundaries(_Loop, [], OuterEdges, ResolvedEdges) ->
    {lists:reverse(ResolvedEdges), OuterEdges};
resolve_boundaries(
    Loop,
    [#edge{name = Name, from = undefined, to = To} | Rest],
    OuterEdges,
    ResolvedEdges
) ->
    {From, RemainingEdges} = take_output(Loop, Name, OuterEdges),
    Ingress = #ingress{name = Name, loop = Loop, from = From, to = To},
    resolve_boundaries(Loop, Rest, RemainingEdges, [Ingress | ResolvedEdges]);
resolve_boundaries(
    Loop,
    [#edge{name = Name, from = From, to = undefined} | Rest],
    OuterEdges,
    ResolvedEdges
) ->
    {To, RemainingEdges} = take_input(Loop, Name, OuterEdges),
    Egress = #egress{name = Name, loop = Loop, from = From, to = To},
    resolve_boundaries(Loop, Rest, RemainingEdges, [Egress | ResolvedEdges]);
resolve_boundaries(Loop, [Edge | Rest], OuterEdges, ResolvedEdges) ->
    resolve_boundaries(Loop, Rest, OuterEdges, [Edge | ResolvedEdges]).

take_output(Loop, Name, Edges) ->
    case lists:keytake(Name, #edge.name, Edges) of
        {value, #edge{from = {_, _} = From, to = undefined}, Rest} ->
            {From, Rest};
        _ ->
            invalid({unmatched_loop_edge, Loop, Name, input})
    end.

take_input(Loop, Name, Edges) ->
    case lists:keytake(Name, #edge.name, Edges) of
        {value, #edge{from = undefined, to = {_, _} = To}, Rest} ->
            {To, Rest};
        _ ->
            invalid({unmatched_loop_edge, Loop, Name, output})
    end.

validate_edge(#edge{name = Name, from = undefined, to = undefined}, _Nodes, _Context) ->
    invalid({edge_without_ends, Name});
validate_edge(#edge{name = Name, from = undefined, to = To}, Nodes, _Context) ->
    validate_endpoint(Name, To, input, Nodes);
validate_edge(#edge{name = Name, from = From, to = undefined}, Nodes, _Context) ->
    validate_endpoint(Name, From, output, Nodes);
validate_edge(#edge{name = Name, from = {Node, _}, to = {Node, _}}, _Nodes, _Context) ->
    invalid({self_edge, Name, Node});
validate_edge(#edge{name = Name, from = {_, _} = From, to = {_, _} = To}, Nodes, _Context) ->
    validate_endpoint(Name, From, output, Nodes),
    validate_endpoint(Name, To, input, Nodes);
validate_edge(#edge{name = Name, from = From, to = To}, _Nodes, _Context) ->
    invalid({invalid_endpoints, Name, From, To});
validate_edge(#feedback{name = Name}, _Nodes, []) ->
    invalid({feedback_outside_loop, Name});
validate_edge(
    #feedback{name = Name, from = {Node, _}, to = {Node, _}},
    _Nodes,
    [_ | _]
) ->
    invalid({self_edge, Name, Node});
validate_edge(
    #feedback{name = Name, from = {_, _} = From, to = {_, _} = To},
    Nodes,
    [_ | _]
) ->
    validate_endpoint(Name, From, output, Nodes),
    validate_endpoint(Name, To, input, Nodes);
validate_edge(#feedback{name = Name, from = From, to = To}, _Nodes, [_ | _]) ->
    invalid({invalid_endpoints, Name, From, To}).

%% @doc Называет контекст в диагностике: плоский граф или ближайший цикл.
context_label([]) -> graph;
context_label([Loop | _]) -> {loop, Loop}.

validate_endpoint(Edge, {Node, _Slot}, _Direction, Nodes) ->
    case lists:member(Node, Nodes) of
        true -> ok;
        false -> invalid({unknown_node, Edge, Node})
    end;
validate_endpoint(Edge, Endpoint, Direction, _Nodes) ->
    invalid({invalid_endpoint, Edge, Direction, Endpoint}).

%% @doc Проверяет глобальные инварианты уже раскрытого графа.
validate_graph(Nodes, Edges, Loops) ->
    ensure_unique([Node#node.name || Node <- Nodes], node),
    ensure_unique([edge_name(Edge) || Edge <- Edges], edge),
    ensure_unique(Loops, loop),
    NodeNames = [Node#node.name || Node <- Nodes],
    lists:foreach(fun(Edge) -> validate_resolved_edge(Edge, NodeNames) end, Edges),
    ensure_acyclic(Nodes, Edges).

validate_resolved_edge(#ingress{name = Name, from = From, to = To}, Nodes) ->
    validate_resolved_edge(Name, From, To, Nodes);
validate_resolved_edge(#egress{name = Name, from = From, to = To}, Nodes) ->
    validate_resolved_edge(Name, From, To, Nodes);
validate_resolved_edge(#feedback{name = Name, from = From, to = To}, Nodes) ->
    validate_resolved_edge(Name, From, To, Nodes);
validate_resolved_edge(#edge{name = Name, from = undefined, to = To}, Nodes) ->
    validate_endpoint(Name, To, input, Nodes);
validate_resolved_edge(#edge{name = Name, from = From, to = undefined}, Nodes) ->
    validate_endpoint(Name, From, output, Nodes);
validate_resolved_edge(#edge{name = Name, from = From, to = To}, Nodes) ->
    validate_resolved_edge(Name, From, To, Nodes).

validate_resolved_edge(Name, {Node, _}, {Node, _}, _Nodes) ->
    invalid({self_edge, Name, Node});
validate_resolved_edge(Name, From, To, Nodes) ->
    validate_endpoint(Name, From, output, Nodes),
    validate_endpoint(Name, To, input, Nodes).

edge_name(#edge{name = Name}) -> Name;
edge_name(#ingress{name = Name}) -> Name;
edge_name(#egress{name = Name}) -> Name;
edge_name(#feedback{name = Name}) -> Name.

ensure_unique(Values, Kind) ->
    case duplicate(Values) of
        none -> ok;
        {some, Value} -> invalid({duplicate, Kind, Value})
    end.

duplicate([]) ->
    none;
duplicate([Value | Rest]) ->
    case lists:member(Value, Rest) of
        true -> {some, Value};
        false -> duplicate(Rest)
    end.

%% @doc Проверяет ацикличность графа после исключения feedback-рёбер.
ensure_acyclic(Nodes, Edges) ->
    Names = [Node#node.name || Node <- Nodes],
    Arcs = lists:filtermap(fun arc/1, Edges),
    case acyclic(Names, Arcs) of
        true -> ok;
        false -> invalid(cycle)
    end.

acyclic(Names, Arcs) ->
    Degrees0 = maps:from_list([{Name, 0} || Name <- Names]),
    {Adjacency, Degrees} = lists:foldl(fun add_arc/2, {#{}, Degrees0}, Arcs),
    Ready = [Name || {Name, 0} <- maps:to_list(Degrees)],
    visit(Ready, Adjacency, Degrees, 0) =:= length(Names).

arc(#edge{from = {From, _}, to = {To, _}}) -> {true, {From, To}};
arc(#ingress{from = {From, _}, to = {To, _}}) -> {true, {From, To}};
arc(#egress{from = {From, _}, to = {To, _}}) -> {true, {From, To}};
arc(#feedback{}) -> false;
arc(#edge{}) -> false.

add_arc({From, To}, {Adjacency, Degrees}) ->
    {
        maps:update_with(From, fun(Targets) -> [To | Targets] end, [To], Adjacency),
        maps:update_with(To, fun(Degree) -> Degree + 1 end, 1, Degrees)
    }.

visit([], _Adjacency, _Degrees, Count) ->
    Count;
visit([Node | Rest], Adjacency, Degrees, Count) ->
    {NewDegrees, NewReady} = lists:foldl(
        fun(Target, {CurrentDegrees, CurrentReady}) ->
            Degree = maps:get(Target, CurrentDegrees) - 1,
            Ready = case Degree of 0 -> [Target | CurrentReady]; _ -> CurrentReady end,
            {maps:put(Target, Degree, CurrentDegrees), Ready}
        end,
        {Degrees, []},
        maps:get(Node, Adjacency, [])
    ),
    visit(Rest ++ NewReady, Adjacency, NewDegrees, Count + 1).

invalid(Reason) ->
    error({invalid_graph, Reason}).
