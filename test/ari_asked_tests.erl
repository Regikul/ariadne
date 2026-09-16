-module(ari_asked_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Keeping
%%%===================================================================

a_notification_is_found_once_added_and_gone_once_removed_test() ->
    T = ari_vtime:new(0),
    A0 = ari_asked:new(),
    ?assertEqual(none, ari_asked:find(count, T, A0)),
    A1 = ari_asked:add(count, T, [self()], A0),
    ?assertEqual({value, [self()]}, ari_asked:find(count, T, A1)),
    A2 = ari_asked:remove(count, T, A1),
    ?assertEqual(none, ari_asked:find(count, T, A2)),
    ?assertEqual([], ari_asked:to_list(A2)).

adding_a_notification_again_replaces_its_value_test() ->
    T = ari_vtime:new(0),
    A = ari_asked:add(count, T, second, ari_asked:add(count, T, first, ari_asked:new())),
    ?assertEqual([{count, T, second}], ari_asked:to_list(A)).

removing_a_notification_not_asked_for_fails_test() ->
    ?assertError(_, ari_asked:remove(count, ari_vtime:new(0), ari_asked:new())).

%%%===================================================================
%%% Finding the complete ones
%%%===================================================================

the_first_is_the_earliest_complete_of_the_earliest_vertex_test() ->
    A = asked([{second, 1}, {first, 2}, {first, 1}, {second, 0}]),
    ?assertEqual(none, ari_asked:first(fun(_, _) -> false end, A)),
    ?assertEqual(
        {value, {first, ari_vtime:new(1), []}},
        ari_asked:first(fun(_, T) -> T =/= ari_vtime:new(0) end, A)
    ),
    ?assertEqual(
        {value, {second, ari_vtime:new(0), []}},
        ari_asked:first(fun(_, _) -> true end, A)
    ).

the_due_are_every_complete_one_earliest_first_taken_off_test() ->
    A = asked([{second, 1}, {first, 2}, {first, 1}, {second, 0}]),
    {Due, Left} = ari_asked:due(fun(_, T) -> T =/= ari_vtime:new(2) end, A),
    ?assertEqual(
        [{second, ari_vtime:new(0), []}, {first, ari_vtime:new(1), []}, {second, ari_vtime:new(1), []}],
        Due
    ),
    ?assertEqual([{first, ari_vtime:new(2), []}], ari_asked:to_list(Left)).

outside_of_a_loop_the_first_incomplete_time_ends_the_walk_test() ->
    A = asked([{count, N} || N <- lists:seq(0, 9)]),
    %% Asking about a time past the first incomplete one is a failure.
    Complete = fun(count, Time) ->
        case Time =:= ari_vtime:new(0) orelse Time =:= ari_vtime:new(1) of
            true -> Time =:= ari_vtime:new(0);
            false -> error({asked_past_the_block, Time})
        end
    end,
    ?assertEqual({value, {count, ari_vtime:new(0), []}}, ari_asked:first(Complete, A)),
    {Due, _Left} = ari_asked:due(Complete, A),
    ?assertEqual([{count, ari_vtime:new(0), []}], Due).

inside_of_a_loop_an_incomplete_time_blocks_those_it_precedes_alone_test() ->
    %% {0, [1]} precedes {0, [2]}; {1, [0]} is incomparable with both.
    Blocked = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(0))),
    Later = ari_vtime:feedback(Blocked),
    Aside = ari_vtime:ingress(ari_vtime:new(1)),
    A = lists:foldl(
        fun(T, Acc) -> ari_asked:add(inc, T, [], Acc) end,
        ari_asked:new(),
        [Later, Aside, Blocked]
    ),
    Complete = fun
        (inc, T) when T =:= Blocked -> false;
        (inc, T) when T =:= Aside -> true;
        (inc, T) -> error({asked_a_blocked_time, T})
    end,
    ?assertEqual({value, {inc, Aside, []}}, ari_asked:first(Complete, A)),
    {Due, Left} = ari_asked:due(Complete, A),
    ?assertEqual([{inc, Aside, []}], Due),
    ?assertEqual([{inc, Blocked, []}, {inc, Later, []}], lists:sort(ari_asked:to_list(Left))).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Notifications of the vertices at the epochs given, with `[]' for
%% a value.
asked(Pairs) ->
    lists:foldl(
        fun({Vertex, Epoch}, Acc) -> ari_asked:add(Vertex, ari_vtime:new(Epoch), [], Acc) end,
        ari_asked:new(),
        Pairs
    ).
