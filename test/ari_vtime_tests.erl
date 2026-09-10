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

partial_order_test() ->
    Epoch = ari_vtime:new(10),
    Outer0 = ari_vtime:ingress(Epoch),
    Inner0Outer0 = ari_vtime:ingress(Outer0),
    Inner1Outer0 = ari_vtime:feedback(Inner0Outer0),
    Outer1 = ari_vtime:feedback(Outer0),
    Inner0Outer1 = ari_vtime:ingress(Outer1),
    ?assertNot(ari_vtime:le(Inner1Outer0, Inner0Outer1)),
    ?assertNot(ari_vtime:le(Inner0Outer1, Inner1Outer0)).

epoch_order_test() ->
    ?assert(ari_vtime:le(ari_vtime:new(10), ari_vtime:new(11))),
    ?assertNot(ari_vtime:le(ari_vtime:new(11), ari_vtime:new(10))).
