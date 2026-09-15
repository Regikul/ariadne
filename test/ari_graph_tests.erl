-module(ari_graph_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ari_graph.hrl").

%%%===================================================================
%%% Building the description
%%%===================================================================

loop_keeps_its_items_test() ->
    Items = [
        ari_graph:node(prepare, prepare_callback, []),
        ari_graph:edge(into_done, {prepare, out}, {is_done, in})
    ],
    ?assertEqual(#scope{name = processing, items = Items},
                 ari_graph:loop(processing, Items)).

empty_description_gives_an_empty_graph_test() ->
    ?assertEqual(#graph{nodes = [], edges = []}, ari_graph:graph([])).

%%%===================================================================
%%% Unfolding the scopes
%%%===================================================================

graph_keeps_the_order_of_the_vertices_test() ->
    ?assertEqual(
        [filter, prepare, is_done, finalize],
        [Name || #vertex{name = Name} <- vertices(example())]
    ).

graph_keeps_the_order_of_the_edges_test() ->
    ?assertEqual(
        [input, into_processing, into_done, again, ready, done],
        [name_of(Edge) || Edge <- edges(example())]
    ).

graph_keeps_the_vertices_as_they_were_written_test() ->
    ?assertMatch(
        #vertex{callback = prepare_callback, args = #{foo := bar}},
        vertex(prepare, example())
    ).

vertices_carry_the_scope_they_sit_in_test() ->
    Graph = example(),
    ?assertMatch(#vertex{scope = undefined}, vertex(filter, Graph)),
    ?assertMatch(#vertex{scope = processing}, vertex(prepare, Graph)),
    ?assertMatch(#vertex{scope = processing}, vertex(is_done, Graph)),
    ?assertMatch(#vertex{scope = undefined}, vertex(finalize, Graph)).

nested_scopes_leave_the_innermost_one_on_a_vertex_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(outer, outer_callback, []),
        ari_graph:loop(outer_loop, [
            ari_graph:node(middle, middle_callback, []),
            ari_graph:loop(inner_loop, [
                ari_graph:node(inner, inner_callback, [])
            ])
        ])
    ]),
    ?assertMatch(#vertex{scope = undefined}, vertex(outer, Graph)),
    ?assertMatch(#vertex{scope = outer_loop}, vertex(middle, Graph)),
    ?assertMatch(#vertex{scope = inner_loop}, vertex(inner, Graph)).

%%%===================================================================
%%% Borders of a scope
%%%===================================================================

an_edge_into_a_scope_becomes_an_ingress_test() ->
    ?assertMatch(
        #ingress{from = {filter, out}, to = {prepare, in}, scope = processing},
        edge(into_processing, example())
    ).

an_edge_out_of_a_scope_becomes_an_egress_test() ->
    ?assertMatch(
        #egress{from = {is_done, out}, to = {finalize, in}, scope = processing},
        edge(ready, example())
    ).

an_edge_inside_a_scope_is_left_alone_test() ->
    ?assertMatch(
        #edge{from = {prepare, out}, to = {is_done, in}},
        edge(into_done, example())
    ).

a_back_edge_gets_the_name_of_its_scope_test() ->
    ?assertMatch(
        #feedback{from = {is_done, out}, to = {prepare, in}, scope = processing},
        edge(again, example())
    ).

the_place_an_edge_is_written_at_does_not_matter_test() ->
    Inside = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, []),
            ari_graph:edge(into_processing, {filter, out}, {prepare, in})
        ])
    ]),
    Outside = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:edge(into_processing, {filter, out}, {prepare, in}),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, [])
        ])
    ]),
    ?assertEqual(edge(into_processing, Inside), edge(into_processing, Outside)).

nested_scopes_have_borders_of_their_own_test() ->
    Graph = ari_graph:graph([
        ari_graph:loop(outer_loop, [
            ari_graph:node(outer, outer_callback, []),
            ari_graph:loop(inner_loop, [
                ari_graph:node(inner, inner_callback, []),
                ari_graph:edge(descend, {outer, out}, {inner, in}),
                ari_graph:edge(ascend, {inner, out}, {outer, in})
            ])
        ])
    ]),
    ?assertMatch(#ingress{scope = inner_loop}, edge(descend, Graph)),
    ?assertMatch(#egress{scope = inner_loop}, edge(ascend, Graph)).

a_border_written_by_hand_is_left_alone_test() ->
    Border = #ingress{
        name = into_processing,
        from = {filter, out},
        to = {prepare, in},
        scope = processing
    },
    Graph = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        Border,
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, [])
        ])
    ]),
    ?assertEqual(Border, edge(into_processing, Graph)).

%%%===================================================================
%%% Options
%%%===================================================================

an_edge_without_options_has_none_test() ->
    ?assertMatch(#edge{opts = #{}}, edge(into_done, example())),
    ?assertMatch(#feedback{opts = #{}}, edge(again, example())).

an_edge_keeps_its_options_test() ->
    Key = fun({K, _V}) -> K end,
    Graph = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:in(input, {filter, in}, #{key => Key}),
        ari_graph:edge(next, {filter, out}, {prepare, in}, #{key => Key}),
        ari_graph:node(prepare, prepare_callback, [])
    ]),
    ?assertMatch(#edge{opts = #{key := Key}}, edge(input, Graph)),
    ?assertMatch(#edge{opts = #{key := Key}}, edge(next, Graph)).

a_border_keeps_the_options_of_the_edge_it_was_test() ->
    Key = fun({K, _V}) -> K end,
    Graph = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:edge(descend, {filter, out}, {prepare, in}, #{key => Key}),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, []),
            ari_graph:feedback(again, {prepare, continue}, {prepare, in}, #{key => Key})
        ]),
        ari_graph:edge(ascend, {prepare, out}, {finalize, in}, #{key => Key}),
        ari_graph:node(finalize, finalize_callback, [])
    ]),
    ?assertMatch(#ingress{opts = #{key := Key}}, edge(descend, Graph)),
    ?assertMatch(#egress{opts = #{key := Key}}, edge(ascend, Graph)),
    ?assertMatch(#feedback{opts = #{key := Key}}, edge(again, Graph)).

%%%===================================================================
%%% The outside world
%%%===================================================================

the_ends_of_the_graph_stay_plain_edges_test() ->
    Graph = example(),
    ?assertMatch(#edge{from = undefined, to = {filter, in}}, edge(input, Graph)),
    ?assertMatch(#edge{from = {finalize, out}, to = undefined}, edge(done, Graph)).

an_end_of_the_graph_inside_a_loop_becomes_a_border_test() ->
    Graph = ari_graph:graph([
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, []),
            ari_graph:in(input, {prepare, in}),
            ari_graph:out(output, {prepare, out})
        ])
    ]),
    ?assertMatch(#ingress{to = {prepare, in}, scope = processing}, edge(input, Graph)),
    ?assertMatch(#egress{from = {prepare, out}, scope = processing}, edge(output, Graph)).

an_unknown_name_is_taken_for_the_outside_world_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:edge(nowhere_to_filter, {nowhere, out}, {filter, in})
    ]),
    ?assertMatch(#edge{from = {nowhere, out}, to = {filter, in}}, edge(nowhere_to_filter, Graph)).

%%%===================================================================
%%% What is not told apart yet
%%%===================================================================

%% Two borders at once are not expressed by one edge: the item would
%% need two coordinates of its timestamp added, and there is only one
%% edge to add them on. Such an edge is left as it is, and the check
%% of the description is to catch it later.
an_edge_crossing_two_borders_is_left_alone_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(source, source_callback, []),
        ari_graph:edge(straight_in, {source, out}, {inner, in}),
        ari_graph:loop(outer_loop, [
            ari_graph:loop(inner_loop, [
                ari_graph:node(inner, inner_callback, [])
            ])
        ])
    ]),
    ?assertMatch(#edge{from = {source, out}, to = {inner, in}}, edge(straight_in, Graph)).

%% Neighbouring scopes are of one and the same depth, but of different
%% loops, so an edge between them is neither an ingress nor an egress.
an_edge_between_neighbouring_scopes_is_left_alone_test() ->
    Graph = ari_graph:graph([
        ari_graph:loop(left_loop, [
            ari_graph:node(left, left_callback, [])
        ]),
        ari_graph:loop(right_loop, [
            ari_graph:node(right, right_callback, []),
            ari_graph:edge(sideways, {left, out}, {right, in})
        ])
    ]),
    ?assertMatch(#edge{from = {left, out}, to = {right, in}}, edge(sideways, Graph)).

%% Two scopes of one name could not be told apart by the name a vertex
%% carries, so the description is refused.
two_scopes_of_one_name_are_refused_test() ->
    ?assertError({duplicate_scope, spin}, ari_graph:graph([
        ari_graph:loop(spin, [
            ari_graph:node(left, left_callback, [])
        ]),
        ari_graph:loop(spin, [
            ari_graph:node(right, right_callback, [])
        ])
    ])).

a_scope_nested_in_a_scope_of_one_name_is_refused_test() ->
    ?assertError({duplicate_scope, spin}, ari_graph:graph([
        ari_graph:loop(spin, [
            ari_graph:loop(spin, [
                ari_graph:node(inner, inner_callback, [])
            ])
        ])
    ])).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% The graph of the example of the documentation of ari_graph.
-spec example() -> #graph{}.
example() ->
    ari_graph:graph([
        ari_graph:in(input, {filter, in}),
        ari_graph:node(filter, filter_callback, []),
        ari_graph:loop(processing, [
            ari_graph:edge(into_processing, {filter, out}, {prepare, in}),
            ari_graph:node(prepare, prepare_callback, #{foo => bar}),
            ari_graph:edge(into_done, {prepare, out}, {is_done, in}),
            ari_graph:node(is_done, is_done_callback, []),
            ari_graph:feedback(again, {is_done, out}, {prepare, in})
        ]),
        ari_graph:edge(ready, {is_done, out}, {finalize, in}),
        ari_graph:node(finalize, finalize_callback, []),
        ari_graph:out(done, {finalize, out})
    ]).

%% The vertices of the graph, in the order they were written in.
-spec vertices(#graph{}) -> [#vertex{}].
vertices(#graph{nodes = Nodes}) ->
    Nodes.

%% The edges of the graph, in the order they were written in.
-spec edges(#graph{}) -> [edge()].
edges(#graph{edges = Edges}) ->
    Edges.

%% The vertex named `Name'.
-spec vertex(Name :: atom(), #graph{}) -> #vertex{}.
vertex(Name, Graph) ->
    [Vertex] = [V || #vertex{name = N} = V <- vertices(Graph), N =:= Name],
    Vertex.

%% The edge named `Name', whichever kind of edge it has become.
-spec edge(Name :: atom(), #graph{}) -> edge().
edge(Name, Graph) ->
    [Edge] = [E || E <- edges(Graph), name_of(E) =:= Name],
    Edge.

%% The name of an edge of any kind.
-spec name_of(edge()) -> atom().
name_of(#edge{name = Name}) -> Name;
name_of(#ingress{name = Name}) -> Name;
name_of(#egress{name = Name}) -> Name;
name_of(#feedback{name = Name}) -> Name.
