-module(ari_progress_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% The inputs
%%%===================================================================

an_input_is_open_at_epoch_0_test() ->
    P = ari_progress:new([input]),
    ?assertEqual(ok, ari_progress:check_open(input, 0, P)),
    ?assertEqual(ok, ari_progress:check_open(input, 5, P)).

closing_shuts_the_epochs_up_to_the_one_given_test() ->
    {ok, P} = ari_progress:close(input, 1, ari_progress:new([input])),
    ?assertEqual({error, {closed, {input, 0}}}, ari_progress:check_open(input, 0, P)),
    ?assertEqual({error, {closed, {input, 1}}}, ari_progress:check_open(input, 1, P)),
    ?assertEqual(ok, ari_progress:check_open(input, 2, P)).

closing_an_epoch_closed_already_changes_nothing_test() ->
    {ok, P} = ari_progress:close(input, 3, ari_progress:new([input])),
    ?assertEqual({ok, P}, ari_progress:close(input, 1, P)).

an_unknown_input_is_refused_test() ->
    P = ari_progress:new([input]),
    ?assertEqual({error, {unknown_input, other}}, ari_progress:check_open(other, 0, P)),
    ?assertEqual({error, {unknown_input, other}}, ari_progress:close(other, 0, P)).

%%%===================================================================
%%% The counts
%%%===================================================================

work_added_keeps_a_time_from_completing_test() ->
    T = ari_vtime:new(0),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    ?assert(ari_progress:complete(summaries(), {second, T}, P0)),
    P1 = ari_progress:apply({[], [{{edge, link}, T}]}, P0),
    ?assertNot(ari_progress:complete(summaries(), {second, T}, P1)).

work_is_counted_item_by_item_test() ->
    T = ari_vtime:new(0),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{edge, link}, T}, {{edge, link}, T}]}, P0),
    P2 = ari_progress:apply({[{{edge, link}, T}], []}, P1),
    ?assertNot(ari_progress:complete(summaries(), {second, T}, P2)),
    P3 = ari_progress:apply({[{{edge, link}, T}], []}, P2),
    ?assert(ari_progress:complete(summaries(), {second, T}, P3)).

work_is_added_before_it_is_released_test() ->
    T = ari_vtime:new(0),
    P0 = ari_progress:new([input]),
    P1 = ari_progress:apply({[{{edge, link}, T}], [{{edge, link}, T}]}, P0),
    ?assertEqual(P0, P1).

the_messages_on_their_way_are_the_work_on_the_edges_test() ->
    T = ari_vtime:new(0),
    P0 = ari_progress:new([input]),
    ?assertEqual(0, ari_progress:in_flight(P0)),
    P1 = ari_progress:apply({[], [{{edge, link}, T}, {{edge, link}, T}, {{vertex, second}, T}]}, P0),
    ?assertEqual(2, ari_progress:in_flight(P1)),
    P2 = ari_progress:apply({[{{edge, link}, T}, {{vertex, second}, T}], [{{edge, out}, T}]}, P1),
    ?assertEqual(2, ari_progress:in_flight(P2)),
    P3 = ari_progress:apply({[{{edge, link}, T}, {{edge, out}, T}], []}, P2),
    ?assertEqual(0, ari_progress:in_flight(P3)).

releasing_work_never_added_fails_test() ->
    T = ari_vtime:new(0),
    ?assertError(
        {unbalanced, {{edge, link}, T}},
        ari_progress:apply({[{{edge, link}, T}], []}, ari_progress:new([input]))
    ).

%%%===================================================================
%%% The sums
%%%===================================================================

a_sum_counts_the_work_by_the_pointstamp_test() ->
    T = ari_vtime:new(0),
    Sum = ari_progress:sum(
        {[{{edge, input}, T}], [{{edge, link}, T}, {{edge, link}, T}, {{vertex, second}, T}]},
        ari_progress:sum({[], [{{edge, input}, T}, {{edge, input}, T}]}, #{})
    ),
    ?assertEqual(#{{{edge, input}, T} => 1, {{edge, link}, T} => 2, {{vertex, second}, T} => 1}, Sum).

work_added_and_released_within_a_sum_leaves_no_trace_test() ->
    T = ari_vtime:new(0),
    Sum = ari_progress:sum({[{{edge, link}, T}], []}, ari_progress:sum({[], [{{edge, link}, T}]}, #{})),
    ?assertEqual(#{}, Sum).

a_sum_applies_as_its_deltas_would_test() ->
    T0 = ari_vtime:new(0),
    T1 = ari_vtime:new(1),
    Deltas = [
        {[], [{{edge, input}, T0}, {{edge, input}, T0}, {{edge, input}, T1}]},
        {[{{edge, input}, T0}], [{{edge, link}, T0}, {{vertex, first}, T0}]},
        {[{{edge, input}, T0}, {{edge, link}, T0}], [{{vertex, second}, T0}]}
    ],
    P0 = ari_progress:new([input]),
    OneByOne = lists:foldl(fun ari_progress:apply/2, P0, Deltas),
    AtOnce = ari_progress:apply(lists:foldl(fun ari_progress:sum/2, #{}, Deltas), P0),
    ?assertEqual(OneByOne, AtOnce),
    ?assertEqual(1, ari_progress:in_flight(AtOnce)).

a_sum_releasing_more_than_there_is_fails_test() ->
    T = ari_vtime:new(0),
    P = ari_progress:apply({[], [{{edge, link}, T}]}, ari_progress:new([input])),
    ?assertError(
        {unbalanced, {{edge, link}, T}},
        ari_progress:apply(#{{{edge, link}, T} => -2}, P)
    ).

%%%===================================================================
%%% Completeness
%%%===================================================================

an_open_input_keeps_its_epoch_from_completing_test() ->
    P = ari_progress:new([input]),
    ?assertNot(ari_progress:complete(summaries(), {second, ari_vtime:new(0)}, P)),
    {ok, Closed} = ari_progress:close(input, 0, P),
    ?assert(ari_progress:complete(summaries(), {second, ari_vtime:new(0)}, Closed)).

an_open_input_reaches_no_further_than_its_first_open_epoch_test() ->
    {ok, P} = ari_progress:close(input, 0, ari_progress:new([input])),
    ?assertNot(ari_progress:complete(summaries(), {second, ari_vtime:new(1)}, P)),
    ?assert(ari_progress:complete(summaries(), {second, ari_vtime:new(0)}, P)).

work_downstream_does_not_keep_a_time_from_completing_test() ->
    T = ari_vtime:new(0),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{edge, link}, T}]}, P0),
    ?assert(ari_progress:complete(summaries(), {first, T}, P1)).

the_notification_itself_does_not_keep_its_time_from_completing_test() ->
    T = ari_vtime:new(0),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{vertex, second}, T}]}, P0),
    ?assert(ari_progress:complete(summaries(), {second, T}, P1)).

a_notification_upstream_keeps_a_time_from_completing_test() ->
    T = ari_vtime:new(0),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{vertex, first}, T}]}, P0),
    ?assertNot(ari_progress:complete(summaries(), {second, T}, P1)).

an_earlier_notification_of_the_vertex_itself_does_not_keep_a_later_time_from_completing_test() ->
    {ok, P0} = ari_progress:close(input, 1, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{vertex, second}, ari_vtime:new(0)}]}, P0),
    ?assert(ari_progress:complete(summaries(), {second, ari_vtime:new(1)}, P1)).

an_earlier_notification_of_the_vertex_itself_keeps_a_later_time_it_comes_back_at_test() ->
    Earlier = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(0))),
    {ok, P0} = ari_progress:close(input, 0, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{vertex, inc}, Earlier}]}, P0),
    ?assert(ari_progress:complete(looping(), {inc, Earlier}, P1)),
    ?assertNot(ari_progress:complete(looping(), {inc, ari_vtime:feedback(Earlier)}, P1)).

%%%===================================================================
%%% The frontier
%%%===================================================================

work_released_off_the_frontier_uncovers_the_work_behind_it_test() ->
    T0 = ari_vtime:new(0),
    T1 = ari_vtime:new(1),
    {ok, P0} = ari_progress:close(input, 1, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{edge, link}, T0}, {{edge, link}, T1}]}, P0),
    ?assertNot(ari_progress:complete(summaries(), {second, T0}, P1)),
    ?assertNot(ari_progress:complete(summaries(), {second, T1}, P1)),
    P2 = ari_progress:apply({[{{edge, link}, T0}], []}, P1),
    ?assert(ari_progress:complete(summaries(), {second, T0}, P2)),
    ?assertNot(ari_progress:complete(summaries(), {second, T1}, P2)),
    P3 = ari_progress:apply({[{{edge, link}, T1}], []}, P2),
    ?assert(ari_progress:complete(summaries(), {second, T1}, P3)).

work_at_incomparable_times_is_on_the_frontier_side_by_side_test() ->
    %% {0, [1]} and {1, [0]}: the second iteration of epoch 0 and the
    %% first of epoch 1, neither preceding the other.
    Later = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(0))),
    Next = ari_vtime:ingress(ari_vtime:new(1)),
    {ok, P0} = ari_progress:close(input, 1, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{edge, again}, Later}, {{edge, again}, Next}]}, P0),
    ?assertNot(ari_progress:complete(looping(), {inc, ari_vtime:feedback(Later)}, P1)),
    ?assertNot(ari_progress:complete(looping(), {inc, ari_vtime:feedback(Next)}, P1)),
    P2 = ari_progress:apply({[{{edge, again}, Later}], []}, P1),
    ?assert(ari_progress:complete(looping(), {inc, ari_vtime:feedback(Later)}, P2)),
    ?assertNot(ari_progress:complete(looping(), {inc, ari_vtime:feedback(Next)}, P2)).

work_of_several_epochs_at_one_iteration_uncovers_epoch_by_epoch_test() ->
    %% {0, [1]} and {1, [1]} are of one group, the first preceding the
    %% second; {2, [0]} is incomparable with both.
    First = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(0))),
    Second = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(1))),
    Aside = ari_vtime:ingress(ari_vtime:new(2)),
    Asked = fun(Time, P) -> ari_progress:complete(looping(), {inc, ari_vtime:feedback(Time)}, P) end,
    {ok, P0} = ari_progress:close(input, 2, ari_progress:new([input])),
    P1 = ari_progress:apply({[], [{{edge, again}, T} || T <- [Second, Aside, First]]}, P0),
    ?assertNot(Asked(First, P1)),
    ?assertNot(Asked(Second, P1)),
    ?assertNot(Asked(Aside, P1)),
    P2 = ari_progress:apply({[{{edge, again}, First}], []}, P1),
    ?assert(Asked(First, P2)),
    ?assertNot(Asked(Second, P2)),
    ?assertNot(Asked(Aside, P2)),
    P3 = ari_progress:apply({[{{edge, again}, Aside}], []}, P2),
    ?assertNot(Asked(Second, P3)),
    ?assert(Asked(Aside, P3)),
    P4 = ari_progress:apply({[{{edge, again}, Second}], []}, P3),
    ?assert(Asked(Second, P4)).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% The summaries of two vertices one after the other: `input' leads
%% to `first', `link' from `first' to `second'.
summaries() ->
    ari_summaries:build(ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_pass, []),
        ari_graph:out(output, {second, out})
    ])).

%% The summaries of a vertex iterating through a feedback edge:
%% `input' leads into the loop to `inc', `again' from `inc' back to
%% itself.
looping() ->
    ari_summaries:build(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, 3),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:out(output, {inc, done})
    ])).
