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
