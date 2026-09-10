%% @doc Проверяет операции над многомерным логическим временем.
-module(ari_vtime_tests).

-include_lib("eunit/include/eunit.hrl").

loop_transitions_test() ->
    Epoch = ari_vtime:new(10),
    Iteration0 = ari_vtime:ingress(Epoch),
    Iteration1 = ari_vtime:feedback(Iteration0),
    ?assert(ari_vtime:le(Iteration0, Iteration1)),
    ?assertEqual(Epoch, ari_vtime:egress(Iteration1)).

nested_loops_test() ->
    Outer0 = ari_vtime:ingress(ari_vtime:new(10)),
    Inner0 = ari_vtime:ingress(Outer0),
    Inner1 = ari_vtime:feedback(Inner0),
    ?assert(ari_vtime:le(Inner0, Inner1)),
    ?assertEqual(Outer0, ari_vtime:egress(Inner1)).

outer_iteration_resets_inner_test() ->
    Epoch = ari_vtime:new(10),
    Outer0 = ari_vtime:ingress(Epoch),
    Inner0Outer0 = ari_vtime:ingress(Outer0),
    Inner1Outer0 = ari_vtime:feedback(Inner0Outer0),
    Outer1 = ari_vtime:feedback(ari_vtime:egress(Inner1Outer0)),
    Inner0Outer1 = ari_vtime:ingress(Outer1),
    ?assert(ari_vtime:le(Inner1Outer0, Inner0Outer1)),
    ?assertNot(ari_vtime:le(Inner0Outer1, Inner1Outer0)).

partial_order_test() ->
    EarlierEpochLaterIteration = ari_vtime:feedback(ari_vtime:ingress(ari_vtime:new(10))),
    LaterEpochEarlierIteration = ari_vtime:ingress(ari_vtime:new(11)),
    ?assertNot(ari_vtime:le(EarlierEpochLaterIteration, LaterEpochEarlierIteration)),
    ?assertNot(ari_vtime:le(LaterEpochEarlierIteration, EarlierEpochLaterIteration)).

iteration_order_test_() ->
    [
        ?_assertEqual(Expected, ari_vtime:le({5, Left}, {5, Right}))
     || {Left, Right, Expected} <- [
        {[], [], true},
        {[3, 0], [3, 0], true},
        {[3, 0], [4, 0], true},
        {[4, 0], [3, 0], false},
        {[3, 0], [0, 1], true},
        {[0, 1], [3, 0], false},
        {[9, 2, 0], [0, 0, 1], true},
        {[0, 0, 1], [9, 2, 0], false},
        {[9, 2, 1], [0, 3, 1], true},
        {[0, 3, 1], [9, 2, 1], false}
    ]
    ].

epoch_order_test() ->
    ?assert(ari_vtime:le(ari_vtime:new(10), ari_vtime:new(11))),
    ?assertNot(ari_vtime:le(ari_vtime:new(11), ari_vtime:new(10))).
