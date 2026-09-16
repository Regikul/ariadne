-module(ari_vtime_tests).

-include_lib("eunit/include/eunit.hrl").

%% These two tests call egress/1 and feedback/1 on a timestamp outside
%% of every loop, where the call cannot succeed. That is what they
%% check, and dialyzer sees the same thing and says so.
-dialyzer({nowarn_function, [
    new_is_outside_of_every_loop_test/0,
    nested_loops_unwind_in_order_test/0
]}).

%%%===================================================================
%%% Entering the graph
%%%===================================================================

new_orders_epochs_test() ->
    ?assert(ari_vtime:le(ari_vtime:new(1), ari_vtime:new(2))),
    ?assertNot(ari_vtime:le(ari_vtime:new(2), ari_vtime:new(1))).

new_is_reflexive_test() ->
    ?assert(ari_vtime:le(ari_vtime:new(7), ari_vtime:new(7))).

new_is_outside_of_every_loop_test() ->
    ?assertError(function_clause, ari_vtime:egress(ari_vtime:new(0))),
    ?assertError(function_clause, ari_vtime:feedback(ari_vtime:new(0))).

%%%===================================================================
%%% Edges of a loop scope
%%%===================================================================

egress_undoes_ingress_test() ->
    Vtime = ari_vtime:new(3),
    ?assertEqual(Vtime, ari_vtime:egress(ari_vtime:ingress(Vtime))).

egress_forgets_the_iteration_test() ->
    Vtime = ari_vtime:new(3),
    Iterated = iterate(ari_vtime:ingress(Vtime), 5),
    ?assertEqual(Vtime, ari_vtime:egress(Iterated)).

egress_leaves_the_enclosing_loop_alone_test() ->
    Outer = iterate(ari_vtime:ingress(ari_vtime:new(0)), 2),
    Inner = iterate(ari_vtime:ingress(Outer), 4),
    ?assertEqual(Outer, ari_vtime:egress(Inner)).

ingress_does_not_move_the_enclosing_loops_test() ->
    Outer = iterate(ari_vtime:ingress(ari_vtime:new(0)), 2),
    ?assertEqual(Outer, ari_vtime:egress(ari_vtime:ingress(Outer))).

nested_loops_unwind_in_order_test() ->
    Vtime = ari_vtime:new(1),
    Nested = ari_vtime:ingress(ari_vtime:ingress(ari_vtime:ingress(Vtime))),
    ?assertEqual(
        Vtime,
        ari_vtime:egress(ari_vtime:egress(ari_vtime:egress(Nested)))
    ),
    ?assertError(function_clause, ari_vtime:egress(Vtime)).

%%%===================================================================
%%% Iterating a loop
%%%===================================================================

feedback_advances_the_time_test() ->
    Vtime = ari_vtime:ingress(ari_vtime:new(0)),
    Next = ari_vtime:feedback(Vtime),
    ?assert(ari_vtime:le(Vtime, Next)),
    ?assertNot(ari_vtime:le(Next, Vtime)).

feedback_advances_by_one_iteration_test() ->
    Vtime = ari_vtime:ingress(ari_vtime:new(0)),
    ?assertEqual(iterate(Vtime, 3), ari_vtime:feedback(iterate(Vtime, 2))).

feedback_moves_the_innermost_loop_only_test() ->
    Inner = iterate(vtime(0, [0, 0]), 1),
    Outer = vtime(0, [0, 1]),
    ?assertEqual(vtime(0, [1, 0]), Inner),
    ?assertNot(ari_vtime:le(Inner, Outer)),
    ?assertNot(ari_vtime:le(Outer, Inner)).

feedback_keeps_the_epoch_test() ->
    Earlier = iterate(ari_vtime:ingress(ari_vtime:new(4)), 10),
    Later = iterate(ari_vtime:ingress(ari_vtime:new(5)), 10),
    ?assert(ari_vtime:le(Earlier, Later)),
    ?assertNot(ari_vtime:le(Later, Earlier)).

%%%===================================================================
%%% The order
%%%===================================================================

le_compares_epochs_test() ->
    ?assert(ari_vtime:le(vtime(0, [1]), vtime(1, [2]))),
    ?assertNot(ari_vtime:le(vtime(1, [1]), vtime(0, [2]))).

le_compares_iterations_test() ->
    ?assert(ari_vtime:le(vtime(1, [1]), vtime(1, [2]))),
    ?assertNot(ari_vtime:le(vtime(1, [2]), vtime(1, [1]))).

le_needs_both_the_epoch_and_the_iterations_test() ->
    ?assertNot(ari_vtime:le(vtime(0, [2]), vtime(1, [1]))),
    ?assertNot(ari_vtime:le(vtime(1, [1]), vtime(0, [2]))).

le_leaves_opposite_loops_unordered_test() ->
    ?assertNot(ari_vtime:le(vtime(0, [0, 1]), vtime(0, [5, 0]))),
    ?assertNot(ari_vtime:le(vtime(0, [5, 0]), vtime(0, [0, 1]))).

le_is_reflexive_test() ->
    ?assertEqual([], [A || A <- sample(), not ari_vtime:le(A, A)]).

le_is_antisymmetric_test() ->
    ?assertEqual(
        [],
        [
            {A, B}
         || A <- sample(),
            B <- sample(),
            A =/= B,
            ari_vtime:le(A, B),
            ari_vtime:le(B, A)
        ]
    ).

le_is_transitive_test() ->
    ?assertEqual(
        [],
        [
            {A, B, C}
         || A <- sample(),
            B <- sample(),
            C <- sample(),
            ari_vtime:le(A, B),
            ari_vtime:le(B, C),
            not ari_vtime:le(A, C)
        ]
    ).

a_timestamp_is_outside_of_every_loop_until_it_enters_one_test() ->
    T = ari_vtime:new(3),
    ?assert(ari_vtime:outside(T)),
    ?assertNot(ari_vtime:outside(ari_vtime:ingress(T))),
    ?assert(ari_vtime:outside(ari_vtime:egress(ari_vtime:ingress(T)))).

le_needs_one_and_the_same_loop_depth_test() ->
    ?assertError(
        function_clause,
        ari_vtime:le(ari_vtime:new(0), ari_vtime:ingress(ari_vtime:new(0)))
    ),
    ?assertError(
        function_clause,
        ari_vtime:le(vtime(0, [0, 0]), vtime(0, [0]))
    ),
    ?assertError(
        function_clause,
        ari_vtime:le(vtime(1, [0]), vtime(0, [0, 0]))
    ),
    ?assertError(
        function_clause,
        ari_vtime:le(vtime(0, [5, 5]), vtime(1, [0]))
    ).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Builds the timestamp of epoch `Epoch' inside of
%% `length(Iterations)' nested loops, the iteration of the innermost
%% loop first, the way the item itself would reach that place of the
%% graph.
-spec vtime(Epoch :: non_neg_integer(), Iterations :: [non_neg_integer()]) ->
    ari_vtime:t().
vtime(Epoch, Iterations) ->
    lists:foldl(
        fun (Iteration, Vtime) ->
            iterate(ari_vtime:ingress(Vtime), Iteration)
        end,
        ari_vtime:new(Epoch),
        lists:reverse(Iterations)
    ).

%% Passes the item along the back edge of its innermost loop `Times'
%% times.
-spec iterate(ari_vtime:t(), Times :: non_neg_integer()) -> ari_vtime:t().
iterate(Vtime, 0) ->
    Vtime;
iterate(Vtime, Times) ->
    iterate(ari_vtime:feedback(Vtime), Times - 1).

%% The timestamps of two nested loops the order is checked on.
-spec sample() -> [ari_vtime:t()].
sample() ->
    [
        vtime(Epoch, [Inner, Outer])
     || Epoch <- [0, 1],
        Inner <- [0, 1, 2],
        Outer <- [0, 1]
    ].
