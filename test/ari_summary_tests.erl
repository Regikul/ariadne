-module(ari_summary_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% The steps
%%%===================================================================

identity_leaves_the_time_alone_test() ->
    ?assertEqual([], [T || T <- times(), ari_summary:advance(ari_summary:identity(), T) =/= T]).

steps_match_the_edges_of_a_loop_test() ->
    T = vtime(1, [2, 3]),
    ?assertEqual(ari_vtime:ingress(T), ari_summary:advance(ari_summary:ingress(), T)),
    ?assertEqual(ari_vtime:egress(T), ari_summary:advance(ari_summary:egress(), T)),
    ?assertEqual(ari_vtime:feedback(T), ari_summary:advance(ari_summary:feedback(), T)).

advance_needs_a_deep_enough_time_test() ->
    ?assertError(function_clause, ari_summary:advance(ari_summary:egress(), ari_vtime:new(0))).

%%%===================================================================
%%% Composition
%%%===================================================================

egress_undoes_ingress_test() ->
    ?assertEqual(
        ari_summary:identity(),
        ari_summary:compose(ari_summary:ingress(), ari_summary:egress())
    ).

egress_forgets_the_iterations_of_the_loop_test() ->
    Iterated = ari_summary:compose(ari_summary:ingress(), ari_summary:feedback()),
    ?assertEqual(
        ari_summary:identity(),
        ari_summary:compose(Iterated, ari_summary:egress())
    ).

leaving_and_entering_again_starts_the_loop_over_test() ->
    Again = ari_summary:compose(ari_summary:egress(), ari_summary:ingress()),
    ?assertEqual(vtime(1, [0, 3]), ari_summary:advance(Again, vtime(1, [7, 3]))).

increments_add_up_test() ->
    Twice = ari_summary:compose(ari_summary:feedback(), ari_summary:feedback()),
    ?assertEqual(vtime(1, [5]), ari_summary:advance(Twice, vtime(1, [3]))).

an_increment_lands_on_the_pushed_counter_test() ->
    Entered = ari_summary:compose(ari_summary:ingress(), ari_summary:feedback()),
    ?assertEqual(vtime(1, [1, 3]), ari_summary:advance(Entered, vtime(1, [3]))).

compose_agrees_with_advancing_step_by_step_test() ->
    ?assertEqual(
        [],
        [
            {A, B, T}
         || A <- sample(),
            B <- sample(),
            T <- times(),
            fits(A, T),
            fits(B, ari_summary:advance(A, T)),
            ari_summary:advance(ari_summary:compose(A, B), T) =/=
                ari_summary:advance(B, ari_summary:advance(A, T))
        ]
    ).

compose_is_associative_test() ->
    ?assertEqual(
        [],
        [
            {A, B, C}
         || A <- sample(),
            B <- sample(),
            C <- sample(),
            ari_summary:compose(ari_summary:compose(A, B), C) =/=
                ari_summary:compose(A, ari_summary:compose(B, C))
        ]
    ).

%%%===================================================================
%%% The order
%%%===================================================================

identity_precedes_an_increment_test() ->
    ?assert(ari_summary:le(ari_summary:identity(), ari_summary:feedback())),
    ?assertNot(ari_summary:le(ari_summary:feedback(), ari_summary:identity())).

starting_over_precedes_staying_in_the_loop_test() ->
    Again = ari_summary:compose(ari_summary:egress(), ari_summary:ingress()),
    ?assert(ari_summary:le(Again, ari_summary:identity())),
    ?assert(ari_summary:le(Again, ari_summary:feedback())),
    ?assertNot(ari_summary:le(ari_summary:identity(), Again)).

a_pushed_counter_is_not_below_an_arbitrary_one_test() ->
    Again = ari_summary:compose(ari_summary:egress(), ari_summary:ingress()),
    Late = ari_summary:compose(Again, ari_summary:feedback()),
    ?assertNot(ari_summary:le(Late, ari_summary:identity())),
    ?assert(ari_summary:le(Late, ari_summary:feedback())).

le_agrees_with_the_order_of_the_times_test() ->
    ?assertEqual(
        [],
        [
            {A, B}
         || A <- sample(),
            B <- sample(),
            depth(A) =:= depth(B),
            ari_summary:le(A, B) =/=
                lists:all(
                    fun(T) ->
                        ari_vtime:le(ari_summary:advance(A, T), ari_summary:advance(B, T))
                    end,
                    [T || T <- times(), fits(A, T), fits(B, T)]
                )
        ]
    ).

le_needs_one_and_the_same_change_of_depth_test() ->
    ?assertError(
        function_clause,
        ari_summary:le(ari_summary:identity(), ari_summary:ingress())
    ).

%%%===================================================================
%%% Cycles
%%%===================================================================

a_feedback_advances_test() ->
    ?assert(ari_summary:advances(ari_summary:feedback())).

an_identity_does_not_advance_test() ->
    ?assertNot(ari_summary:advances(ari_summary:identity())).

starting_over_does_not_advance_test() ->
    Again = ari_summary:compose(ari_summary:egress(), ari_summary:ingress()),
    ?assertNot(ari_summary:advances(Again)),
    ?assertNot(ari_summary:advances(ari_summary:compose(Again, ari_summary:feedback()))).

an_outer_feedback_advances_the_inner_loop_test() ->
    Around = ari_summary:compose(
        ari_summary:compose(ari_summary:egress(), ari_summary:feedback()),
        ari_summary:ingress()
    ),
    ?assert(ari_summary:advances(Around)).

advances_needs_a_cycle_test() ->
    ?assertError(function_clause, ari_summary:advances(ari_summary:ingress())).

%%%===================================================================
%%% Minimal summaries
%%%===================================================================

minimal_drops_what_another_summary_precedes_test() ->
    Once = ari_summary:feedback(),
    Twice = ari_summary:compose(Once, Once),
    ?assertEqual([Once], ari_summary:minimal([Twice, Once, Twice])).

%% Starting the loop over at iteration 2 and stepping to the next
%% iteration are not ordered: which one ends up earlier depends on
%% the iteration the item was at.
minimal_keeps_unordered_summaries_test() ->
    Again = ari_summary:compose(ari_summary:egress(), ari_summary:ingress()),
    A = ari_summary:compose(Again, ari_summary:compose(ari_summary:feedback(), ari_summary:feedback())),
    B = ari_summary:feedback(),
    ?assertNot(ari_summary:le(A, B)),
    ?assertNot(ari_summary:le(B, A)),
    ?assertEqual(lists:sort([A, B]), lists:sort(ari_summary:minimal([A, B]))).

%%%===================================================================
%%% Helpers
%%%===================================================================

vtime(Epoch, Iterations) ->
    lists:foldr(
        fun(Iteration, T) -> iterate(ari_vtime:ingress(T), Iteration) end,
        ari_vtime:new(Epoch),
        Iterations
    ).

iterate(T, 0) -> T;
iterate(T, N) -> iterate(ari_vtime:feedback(T), N - 1).

%% Summaries of every path of up to three steps.
sample() ->
    Steps = [
        ari_summary:identity(),
        ari_summary:ingress(),
        ari_summary:egress(),
        ari_summary:feedback()
    ],
    lists:usort(
        Steps ++
        [ari_summary:compose(A, B) || A <- Steps, B <- Steps] ++
        [ari_summary:compose(ari_summary:compose(A, B), C) || A <- Steps, B <- Steps, C <- Steps]
    ).

times() ->
    [vtime(E, I) || E <- [0, 1], I <- [[], [0], [2], [0, 0], [1, 3], [3, 1], [2, 0, 1]]].

%% The change of depth a summary makes.
depth({Drop, _Incr, Push}) ->
    length(Push) - Drop.

%% Whether the time is deep enough for the summary: the counters it
%% drops have to be there, and so does the one it increments.
fits({Drop, 0, _Push}, {_Epoch, Iterations}) ->
    length(Iterations) >= Drop;
fits({Drop, _Incr, _Push}, {_Epoch, Iterations}) ->
    length(Iterations) > Drop.
