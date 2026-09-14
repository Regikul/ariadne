%%%-------------------------------------------------------------------
%%% @doc
%%% Description of a dataflow graph.
%%%
%%% A graph is described by a list of items. A vertex is an operator:
%%% a name, the callback module running it and the arguments it starts
%%% with. An edge is a channel between two vertices, carrying a name
%%% of its own, unique over the whole graph. A loop scope, built by
%%% {@link loop/2}, holds a list of items of its own and stands in the
%%% list of the enclosing graph as a single item, so that scopes nest.
%%%
%%% {@link graph/1} unfolds the scopes and sorts the items into
%%% vertices and edges. Unfolding looks at the ends of every edge: an
%%% edge leading into a deeper scope becomes an ingress edge, an edge
%%% leading out of one becomes an egress edge, and an edge whose ends
%%% live in one and the same scope is left as it is. The place the
%%% edge is written at therefore does not matter, only its ends do.
%%% The back edge of a loop is the one exception: it is marked by hand
%%% with {@link feedback/3}, since the choice of the edge to close the
%%% loop on does not follow from the shape of the graph alone.
%%%
%%% The three kinds of boundary edge are the places where the
%%% timestamp of an item changes, see {@link ari_vtime:ingress/1},
%%% {@link ari_vtime:egress/1} and {@link ari_vtime:feedback/1}. Every
%%% boundary edge carries the name of the scope it crosses, and every
%%% vertex the name of the scope it sits in, so that a coordinate of a
%%% timestamp can be told from the loop it counts.
%%%
%%% Example usage:
%%%
%%% ```
%%% ari_graph:graph([
%%%     ari_graph:in(input, filter),
%%%     ari_graph:node(filter, filter_callback, []),
%%%     ari_graph:loop(processing, [
%%% 
%%%         ari_graph:node(prepare, prepare_callback, #{foo => bar}),
%%%         ari_graph:node(is_done, is_done_callback, []),
%%%
%%%         ari_graph:edge(into_processing, filter, prepare),
%%%         ari_graph:edge(into_done, prepare, is_done),
%%%         ari_graph:feedback(again, is_done, prepare)
%%%     ]),
%%%     ari_graph:edge(ready, is_done, finalize),
%%%     ari_graph:node(finalize, finalize_callback, []),
%%%     ari_graph:out(done, finalize)
%%% ])'''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(ari_graph).

-include("ari_graph.hrl").

-export([
    graph/1,
    in/2, out/2, edge/3, feedback/3,
    node/3,
    loop/2
]).

-type name()   :: atom().
-type vertex() :: #vertex{}.
-type edge()   :: #edge{} | #ingress{} | #egress{} | #feedback{}.
-type scope()  :: #scope{}.
-type item()   :: vertex() | edge() | scope().
-type graph()  :: #graph{}.

%% The names of the scopes a vertex sits in, the innermost one first.
%% A vertex outside of every loop has an empty path.
-type path() :: [name()].

%%--------------------------------------------------------------------
%% @doc
%% Builds the graph described by `Items': unfolds the loop scopes,
%% sorts the items into vertices and edges, marks every vertex with
%% the scope it sits in and turns the edges crossing the border of a
%% scope into ingress and egress edges.
%%
%% Items referring to names of vertices the description does not
%% define are left as they are.
%% @end
%%--------------------------------------------------------------------
-spec graph(Items :: [item()]) -> graph().
graph(Items) ->
    Paths = paths(Items, []),
    {Nodes, Edges} = unfold(Items, [], [], []),
    #graph{
        nodes = Nodes,
        edges = [boundary(Edge, Paths) || Edge <- Edges]
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds an edge bringing the items of the outside world into the
%% vertex `To'.
%% @end
%%--------------------------------------------------------------------
-spec in(Name :: name(), To :: name()) -> edge().
in(Name, To) ->
    #edge{
        name = Name,
        to = To
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds an edge carrying the items of the vertex `From' out of the
%% graph.
%% @end
%%--------------------------------------------------------------------
-spec out(Name :: name(), From :: name()) -> edge().
out(Name, From) ->
    #edge{
        name = Name,
        from = From
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds an edge from the vertex `From' to the vertex `To'. Whether
%% it stays a plain edge or becomes a boundary of a scope is decided
%% by {@link graph/1} from the scopes its ends sit in.
%% @end
%%--------------------------------------------------------------------
-spec edge(Name :: name(), From :: name(), To :: name()) -> edge().
edge(Name, From, To) ->
    #edge{
        name = Name,
        from = From,
        to = To
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds the back edge of a loop: the edge from the vertex `From' to
%% the vertex `To' that sends an item to the next iteration. Both ends
%% are expected to sit in one and the same scope, and the name of that
%% scope is filled in by {@link graph/1}.
%% @end
%%--------------------------------------------------------------------
-spec feedback(Name :: name(), From :: name(), To :: name()) -> edge().
feedback(Name, From, To) ->
    #feedback{
        name = Name,
        from = From,
        to = To
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds a vertex: the operator `Name' run by the callback module
%% `Callback' started with `InitArgs'.
%% @end
%%--------------------------------------------------------------------
-spec node(Name :: name(), Callback :: module(), InitArgs :: term()) -> vertex().
node(Name, Callback, InitArgs) ->
    #vertex{
        name = Name,
        callback = Callback,
        args = InitArgs
    }.

%%--------------------------------------------------------------------
%% @doc
%% Builds the loop scope `Name' out of `Items'. The result is a single
%% item of the enclosing description, so scopes nest by nesting the
%% calls.
%% @end
%%--------------------------------------------------------------------
-spec loop(Name :: name(), Items :: [item()]) -> scope().
loop(Name, Items) ->
    #scope{
        name = Name,
        items = Items
    }.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Collects the path of every vertex of `Items', given that `Items'
%% themselves sit at the path `Path'.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec paths(Items :: [item()], Path :: path()) -> #{name() => path()}.
paths(Items, Path) ->
    lists:foldl(
        fun
            (#scope{name = Name, items = Nested}, Paths) ->
                maps:merge(Paths, paths(Nested, [Name | Path]));
            (#vertex{name = Name}, Paths) ->
                Paths#{Name => Path};
            (_Item, Paths) ->
                Paths
        end,
        #{},
        Items
    ).

%%--------------------------------------------------------------------
%% @doc
%% Unfolds the scopes of `Items' into a list of vertices, each marked
%% with the scope it sits in, and a list of edges, each kept as it was
%% written. The order the items were written in is kept.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec unfold(Items :: [item()], Path :: path(), [vertex()], [edge()]) ->
    {[vertex()], [edge()]}.
unfold([], _Path, Nodes, Edges) ->
    {lists:reverse(Nodes), lists:reverse(Edges)};
unfold([#scope{name = Name, items = Items} | Rest], Path, Nodes, Edges) ->
    {NestedNodes, NestedEdges} = unfold(Items, [Name | Path], [], []),
    unfold(
        Rest,
        Path,
        lists:reverse(NestedNodes, Nodes),
        lists:reverse(NestedEdges, Edges)
    );
unfold([#vertex{} = Vertex | Rest], Path, Nodes, Edges) ->
    unfold(Rest, Path, [Vertex#vertex{scope = innermost(Path)} | Nodes], Edges);
unfold([Edge | Rest], Path, Nodes, Edges) ->
    unfold(Rest, Path, Nodes, [Edge | Edges]).

%%--------------------------------------------------------------------
%% @doc
%% Tells an edge apart by the scopes of its ends: one step deeper
%% makes it an ingress edge of that scope, one step out an egress edge
%% of the scope left behind, and ends of one and the same scope leave
%% the edge as it is. A back edge only gets the name of its scope
%% filled in.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec boundary(Edge :: edge(), Paths :: #{name() => path()}) -> edge().
boundary(#edge{name = Name, from = From, to = To} = Edge, Paths) ->
    FromPath = path(From, Paths),
    ToPath = path(To, Paths),
    case {FromPath, ToPath} of
        {Path, Path} ->
            Edge;
        {_, [Scope | FromPath]} ->
            #ingress{name = Name, from = From, to = To, scope = Scope};
        {[Scope | ToPath], _} ->
            #egress{name = Name, from = From, to = To, scope = Scope};
        _ ->
            Edge
    end;
boundary(#feedback{from = From} = Feedback, Paths) ->
    Feedback#feedback{scope = innermost(path(From, Paths))};
boundary(Edge, _Paths) ->
    Edge.

%%--------------------------------------------------------------------
%% @doc
%% The path of the vertex `Name'. A name no vertex of the description
%% carries is taken for a name of the outside world, which sits
%% outside of every scope.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec path(Name :: name(), Paths :: #{name() => path()}) -> path().
path(Name, Paths) ->
    maps:get(Name, Paths, []).

%%--------------------------------------------------------------------
%% @doc
%% The innermost scope of a path, or `undefined' outside of every
%% scope.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec innermost(Path :: path()) -> name() | undefined.
innermost([]) ->
    undefined;
innermost([Name | _Path]) ->
    Name.
