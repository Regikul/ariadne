-module(ari_summaries_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Along a path
%%%===================================================================

an_edge_reaches_the_vertex_at_its_end_test() ->
    Table = example(),
    ?assert(reaches(Table, {edge, input}, vtime(1, []), filter, vtime(1, []))),
    ?assert(reaches(Table, {edge, input}, vtime(1, []), filter, vtime(2, []))),
    ?assertNot(reaches(Table, {edge, input}, vtime(1, []), filter, vtime(0, []))).

an_ingress_edge_starts_the_loop_test() ->
    Table = example(),
    ?assert(reaches(Table, {edge, into_processing}, vtime(1, []), prepare, vtime(1, [0]))),
    ?assert(reaches(Table, {edge, into_processing}, vtime(1, []), prepare, vtime(1, [3]))),
    ?assertNot(reaches(Table, {edge, into_processing}, vtime(2, []), prepare, vtime(1, [3]))).

a_feedback_edge_reaches_the_next_iteration_test() ->
    Table = example(),
    ?assert(reaches(Table, {edge, again}, vtime(1, [2]), prepare, vtime(1, [3]))),
    ?assertNot(reaches(Table, {edge, again}, vtime(1, [2]), prepare, vtime(1, [2]))).

an_item_in_the_loop_reaches_the_outside_test() ->
    Table = example(),
    ?assert(reaches(Table, {edge, into_done}, vtime(1, [5]), finalize, vtime(1, []))),
    ?assert(reaches(Table, {edge, into_done}, vtime(1, [5]), finalize, vtime(2, []))),
    ?assertNot(reaches(Table, {edge, into_done}, vtime(1, [5]), finalize, vtime(0, []))).

an_item_outside_does_not_reach_back_into_the_loop_test() ->
    Table = example(),
    ?assertNot(reaches(Table, {edge, ready}, vtime(1, []), prepare, vtime(1, [9]))),
    ?assertNot(reaches(Table, {edge, done}, vtime(1, []), filter, vtime(1, []))).

%%%===================================================================
%%% Around a cycle
%%%===================================================================

a_vertex_reaches_itself_by_the_empty_path_test() ->
    Table = example(),
    ?assert(reaches(Table, {vertex, is_done}, vtime(1, [2]), is_done, vtime(1, [2]))),
    ?assert(reaches(Table, {vertex, filter}, vtime(1, []), filter, vtime(1, []))),
    ?assertNot(reaches(Table, {vertex, filter}, vtime(2, []), filter, vtime(1, []))).

a_vertex_reaches_itself_around_the_loop_test() ->
    Table = example(),
    ?assert(reaches(Table, {vertex, is_done}, vtime(1, [2]), is_done, vtime(1, [3]))),
    ?assert(reaches(Table, {vertex, prepare}, vtime(1, [2]), is_done, vtime(1, [2]))),
    ?assertNot(reaches(Table, {vertex, is_done}, vtime(1, [2]), prepare, vtime(1, [2]))).

a_vertex_returns_to_itself_around_the_loop_alone_test() ->
    Table = example(),
    ?assert(ari_summaries:returns(Table, {vertex, is_done}, vtime(1, [2]), vtime(1, [3]))),
    ?assertNot(ari_summaries:returns(Table, {vertex, is_done}, vtime(1, [2]), vtime(1, [2]))),
    ?assertNot(ari_summaries:returns(Table, {vertex, filter}, vtime(1, []), vtime(2, []))).

a_cycle_without_a_feedback_is_refused_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(a, a_callback, []),
        ari_graph:node(b, b_callback, []),
        ari_graph:edge(forth, {a, out}, {b, in}),
        ari_graph:edge(back, {b, out}, {a, in})
    ]),
    ?assertError({non_advancing_cycle, _}, ari_summaries:build(Graph)).

a_cycle_starting_the_loop_over_is_refused_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(outside, outside_callback, []),
        ari_graph:loop(processing, [
            ari_graph:node(inside, inside_callback, []),
            ari_graph:edge(enter, {outside, out}, {inside, in}),
            ari_graph:edge(leave, {inside, out}, {outside, in})
        ])
    ]),
    ?assertError({non_advancing_cycle, _}, ari_summaries:build(Graph)).

%%%===================================================================
%%% Helpers
%%%===================================================================

reaches(Table, From, Time, To, Time2) ->
    ari_summaries:reaches(Table, From, Time, {vertex, To}, Time2).

vtime(Epoch, Iterations) ->
    lists:foldr(
        fun(Iteration, T) -> iterate(ari_vtime:ingress(T), Iteration) end,
        ari_vtime:new(Epoch),
        Iterations
    ).

iterate(T, 0) -> T;
iterate(T, N) -> iterate(ari_vtime:feedback(T), N - 1).

%% The summaries of the example of the documentation of ari_graph.
example() ->
    ari_summaries:build(ari_graph:graph([
        ari_graph:in(input, {filter, in}),
        ari_graph:node(filter, filter_callback, []),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, #{foo => bar}),
            ari_graph:node(is_done, is_done_callback, []),
            ari_graph:edge(into_processing, {filter, out}, {prepare, in}),
            ari_graph:edge(into_done, {prepare, out}, {is_done, in}),
            ari_graph:feedback(again, {is_done, continue}, {prepare, in})
        ]),
        ari_graph:edge(ready, {is_done, done}, {finalize, in}),
        ari_graph:node(finalize, finalize_callback, []),
        ari_graph:out(done, {finalize, out})
    ])).
