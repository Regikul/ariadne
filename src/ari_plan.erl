%%%-------------------------------------------------------------------
%%% @doc
%%% Plan of a dataflow graph: the description checked and prepared
%%% for running.
%%%
%%% {@link prepare/1} takes the graph built by {@link ari_graph:graph/1}
%%% and puts it against the callback modules of its vertices (see
%%% {@link ariadne_vertex}): every end of an edge has to be a slot of
%%% the right side of an existing vertex, every border edge has to
%%% agree with the scopes of its ends, and every cycle has to advance
%%% the timestamp. What comes out is what a runtime needs and the
%%% description does not give directly: the edges leaving every
%%% output slot, so that a message a vertex sends can be turned into
%%% events, and the path summaries of the graph (see {@link
%%% ari_summaries}), so that the runtime can tell when a time is
%%% complete.
%%%
%%% A plan is immutable. It holds no state of a run -- no vertex
%%% states, no pending messages, no outstanding notifications; those
%%% belong to the runtime, which can run one plan many times, and two
%%% runtimes can share one and the same plan.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_plan).

-include("ari_graph.hrl").

-export([
    prepare/1,
    vertices/1,
    vertex/2,
    edges/1,
    edge/2,
    outgoing/2,
    inputs/1,
    outputs/1,
    summaries/1
]).

-export_type([
    t/0,
    kind/0
]).

%% What an edge does to the timestamp of an item.
-type kind() :: message | ingress | egress | feedback.

%% A prepared vertex: the callback module, its arguments and the
%% scope the vertex sits in.
-record(pvertex, {
    callback :: module(),
    args :: term(),
    scope :: atom() | undefined
}).

%% The slots of the vertices, as their callback modules declare them.
%% Needed to check the ends of the edges and dropped afterwards.
-type slots() :: #{atom() => {Inputs :: [atom()], Outputs :: [atom()]}}.

%% A prepared edge. An end left `undefined' is the outside world.
-record(pedge, {
    kind :: kind(),
    from :: endpoint() | undefined,
    to :: endpoint() | undefined
}).

-record(plan, {
    vertices :: #{atom() => #pvertex{}},
    edges :: #{atom() => #pedge{}},
    outgoing :: #{endpoint() => [atom()]},
    summaries :: ari_summaries:t()
}).

-opaque t() :: #plan{}.

%%--------------------------------------------------------------------
%% @doc
%% Prepares the graph `Graph' for running.
%%
%% Fails with `{Reason, Detail}' if the graph is not fit to run:
%% <ul>
%% <li>`{duplicate_vertex, Name}', `{duplicate_edge, Name}' -- two
%% items of one and the same name;</li>
%% <li>`{duplicate_slot, {Vertex, Slot}}' -- the callback module of
%% `Vertex' names `Slot' twice, on one side or on both;</li>
%% <li>`{unknown_vertex, {Edge, Vertex}}' -- an end of `Edge' names a
%% vertex the graph does not have;</li>
%% <li>`{unknown_slot, {Edge, {Vertex, Slot}}}' -- an end of `Edge'
%% names a slot `Vertex' does not have on that side: the start of an
%% edge has to be an output slot, its end an input slot;</li>
%% <li>`{edge_across_scopes, Edge}' -- a plain edge with ends in
%% different scopes, which is not a border of any one scope;</li>
%% <li>`{feedback_outside_of_a_loop, Edge}' -- a back edge of no
%% loop;</li>
%% <li>`{scope_mismatch, Edge}' -- a border edge whose scope is not
%% the one of the vertex inside;</li>
%% <li>`{non_advancing_cycle, Location}' -- see {@link
%% ari_summaries:build/1}.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec prepare(Graph :: #graph{}) -> t().
prepare(#graph{nodes = Nodes, edges = Edges} = Graph) ->
    {Vertices, Slots} = prepare_vertices(Nodes),
    #plan{
        vertices = Vertices,
        edges = prepare_edges(Edges, Vertices, Slots),
        outgoing = outgoing_of(Edges),
        summaries = ari_summaries:build(Graph)
    }.

%%--------------------------------------------------------------------
%% @doc
%% The names of the vertices of the plan.
%% @end
%%--------------------------------------------------------------------
-spec vertices(Plan :: t()) -> [atom()].
vertices(#plan{vertices = Vertices}) ->
    maps:keys(Vertices).

%%--------------------------------------------------------------------
%% @doc
%% The callback module of the vertex `Name' and the arguments it
%% starts with.
%%
%% Fails with `{badkey, Name}' if the plan has no such vertex.
%% @end
%%--------------------------------------------------------------------
-spec vertex(Plan :: t(), Name :: atom()) -> {Callback :: module(), Args :: term()}.
vertex(#plan{vertices = Vertices}, Name) ->
    #pvertex{callback = Callback, args = Args} = maps:get(Name, Vertices),
    {Callback, Args}.

%%--------------------------------------------------------------------
%% @doc
%% The names of the edges of the plan.
%% @end
%%--------------------------------------------------------------------
-spec edges(Plan :: t()) -> [atom()].
edges(#plan{edges = Edges}) ->
    maps:keys(Edges).

%%--------------------------------------------------------------------
%% @doc
%% The kind of the edge `Name' and its ends. An end that is
%% `undefined' is the outside world.
%%
%% Fails with `{badkey, Name}' if the plan has no such edge.
%% @end
%%--------------------------------------------------------------------
-spec edge(Plan :: t(), Name :: atom()) ->
    {kind(), From :: endpoint() | undefined, To :: endpoint() | undefined}.
edge(#plan{edges = Edges}, Name) ->
    #pedge{kind = Kind, from = From, to = To} = maps:get(Name, Edges),
    {Kind, From, To}.

%%--------------------------------------------------------------------
%% @doc
%% The names of the edges leaving the output slot `From', in the
%% order they were written in. A message sent to the slot goes along
%% every one of them. An output slot no edge is attached to yields an
%% empty list.
%% @end
%%--------------------------------------------------------------------
-spec outgoing(Plan :: t(), From :: endpoint()) -> [atom()].
outgoing(#plan{outgoing = Outgoing}, From) ->
    maps:get(From, Outgoing, []).

%%--------------------------------------------------------------------
%% @doc
%% The names of the edges bringing items of the outside world into
%% the graph, see {@link ari_graph:in/2}.
%% @end
%%--------------------------------------------------------------------
-spec inputs(Plan :: t()) -> [atom()].
inputs(#plan{edges = Edges}) ->
    [Name || Name := #pedge{from = undefined} <- Edges].

%%--------------------------------------------------------------------
%% @doc
%% The names of the edges carrying items out of the graph, see
%% {@link ari_graph:out/2}.
%% @end
%%--------------------------------------------------------------------
-spec outputs(Plan :: t()) -> [atom()].
outputs(#plan{edges = Edges}) ->
    [Name || Name := #pedge{to = undefined} <- Edges].

%%--------------------------------------------------------------------
%% @doc
%% The path summaries of the graph.
%% @end
%%--------------------------------------------------------------------
-spec summaries(Plan :: t()) -> ari_summaries:t().
summaries(#plan{summaries = Summaries}) ->
    Summaries.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Prepares the vertices: asks every callback module for its slots
%% and checks that no name is used twice, among the vertices or among
%% the slots of one vertex. Returns the vertices and their slots.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec prepare_vertices([#vertex{}]) -> {#{atom() => #pvertex{}}, slots()}.
prepare_vertices(Nodes) ->
    lists:foldl(
        fun(#vertex{name = Name, callback = Callback, args = Args, scope = Scope}, {Vertices, Slots}) ->
            is_map_key(Name, Vertices) andalso error({duplicate_vertex, Name}),
            Inputs = Callback:inputs(),
            Outputs = Callback:outputs(),
            All = Inputs ++ Outputs,
            case All -- lists:usort(All) of
                [] -> ok;
                [Slot | _] -> error({duplicate_slot, {Name, Slot}})
            end,
            {
                Vertices#{Name => #pvertex{callback = Callback, args = Args, scope = Scope}},
                Slots#{Name => {Inputs, Outputs}}
            }
        end,
        {#{}, #{}},
        Nodes
    ).

%%--------------------------------------------------------------------
%% @doc
%% Prepares the edges: checks that no name is used twice, that every
%% end is a slot of the right side of a vertex of the graph, and that
%% the edge agrees with the scopes of its ends.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec prepare_edges([edge()], #{atom() => #pvertex{}}, slots()) ->
    #{atom() => #pedge{}}.
prepare_edges(Edges, Vertices, Slots) ->
    lists:foldl(
        fun(Edge, Prepared) ->
            {Name, Kind, From, To} = unpack(Edge),
            is_map_key(Name, Prepared) andalso error({duplicate_edge, Name}),
            check_endpoint(Name, From, outputs, Slots),
            check_endpoint(Name, To, inputs, Slots),
            check_scopes(Edge, scope_of(From, Vertices), scope_of(To, Vertices)),
            Prepared#{Name => #pedge{kind = Kind, from = From, to = To}}
        end,
        #{},
        Edges
    ).

-spec unpack(edge()) ->
    {atom(), kind(), endpoint() | undefined, endpoint() | undefined}.
unpack(#edge{name = Name, from = From, to = To}) ->
    {Name, message, From, To};
unpack(#ingress{name = Name, from = From, to = To}) ->
    {Name, ingress, From, To};
unpack(#egress{name = Name, from = From, to = To}) ->
    {Name, egress, From, To};
unpack(#feedback{name = Name, from = From, to = To}) ->
    {Name, feedback, From, To}.

%%--------------------------------------------------------------------
%% @doc
%% Checks that the endpoint `Endpoint' of the edge `Edge' is a slot
%% of the side `Side' of a vertex of the graph. The outside world is
%% not checked.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec check_endpoint(
    Edge :: atom(),
    Endpoint :: endpoint() | undefined,
    Side :: inputs | outputs,
    slots()
) -> ok.
check_endpoint(_Edge, undefined, _Side, _Slots) ->
    ok;
check_endpoint(Edge, {Vertex, Slot} = Endpoint, Side, Slots) ->
    case Slots of
        #{Vertex := {Inputs, Outputs}} ->
            OfSide = case Side of
                inputs -> Inputs;
                outputs -> Outputs
            end,
            case lists:member(Slot, OfSide) of
                true -> ok;
                false -> error({unknown_slot, {Edge, Endpoint}})
            end;
        _ ->
            error({unknown_vertex, {Edge, Vertex}})
    end.

%%--------------------------------------------------------------------
%% @doc
%% The scope of the vertex an end of an edge belongs to. The outside
%% world sits outside of every scope.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec scope_of(endpoint() | undefined, #{atom() => #pvertex{}}) -> atom() | undefined.
scope_of(undefined, _Vertices) ->
    undefined;
scope_of({Vertex, _Slot}, Vertices) ->
    #pvertex{scope = Scope} = maps:get(Vertex, Vertices),
    Scope.

%%--------------------------------------------------------------------
%% @doc
%% Checks that the edge agrees with the scopes of its ends: a plain
%% edge joins one and the same scope, a border edge carries the scope
%% of the end inside of it, a back edge carries the scope of both
%% ends and is inside of a loop.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec check_scopes(edge(), From :: atom() | undefined, To :: atom() | undefined) -> ok.
check_scopes(#edge{}, Scope, Scope) ->
    ok;
check_scopes(#edge{name = Name}, _From, _To) ->
    error({edge_across_scopes, Name});
check_scopes(#ingress{scope = Scope}, _From, Scope) ->
    ok;
check_scopes(#ingress{name = Name}, _From, _To) ->
    error({scope_mismatch, Name});
check_scopes(#egress{scope = Scope}, Scope, _To) ->
    ok;
check_scopes(#egress{name = Name}, _From, _To) ->
    error({scope_mismatch, Name});
check_scopes(#feedback{name = Name, scope = undefined}, _From, _To) ->
    error({feedback_outside_of_a_loop, Name});
check_scopes(#feedback{scope = Scope}, Scope, Scope) ->
    ok;
check_scopes(#feedback{name = Name}, _From, _To) ->
    error({scope_mismatch, Name}).

%%--------------------------------------------------------------------
%% @doc
%% Collects the edges leaving every output slot, in the order they
%% were written in.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec outgoing_of([edge()]) -> #{endpoint() => [atom()]}.
outgoing_of(Edges) ->
    lists:foldr(
        fun(Edge, Outgoing) ->
            case unpack(Edge) of
                {_Name, _Kind, undefined, _To} ->
                    Outgoing;
                {Name, _Kind, From, _To} ->
                    maps:update_with(From, fun(Names) -> [Name | Names] end, [Name], Outgoing)
            end
        end,
        #{},
        Edges
    ).
