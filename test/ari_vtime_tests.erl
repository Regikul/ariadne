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

edge_summary_test_() ->
    Time = {5, [3, 1]},
    [
        ?_assertEqual(Expected, ari_vtime:transfer(ari_vtime:summary(Kind), Time))
     || {Kind, Expected} <- [
        {message, Time},
        {ingress, ari_vtime:ingress(Time)},
        {feedback, ari_vtime:feedback(Time)},
        {egress, ari_vtime:egress(Time)}
    ]
    ].

summary_table_test_() ->
    [
        ?_assertEqual(Expected, ari_vtime:transfer(ari_vtime:summary(Pop, Bump, Push), Time))
     || {{Pop, Bump, Push}, Time, Expected} <- [
        {{0, 0, [0]}, {5, []}, {5, [0]}},
        {{0, 1, []}, {5, [0]}, {5, [1]}},
        {{0, 2, []}, {5, [0]}, {5, [2]}},
        {{1, 0, []}, {5, [3]}, {5, []}},
        {{0, 0, []}, {5, []}, {5, []}},
        {{1, 1, [0]}, {5, [3, 0]}, {5, [0, 1]}}
    ]
    ].

%% Композиция сводок совпадает с последовательным применением рёбер на
%% всех путях длины до пяти, допустимых для времени глубины два.
compose_matches_sequence_test() ->
    Time = {5, [3, 1]},
    Kinds = [message, ingress, feedback, egress],
    Paths = lists:append([paths(Kinds, Length) || Length <- lists:seq(1, 5)]),
    Valid = [Path || Path <- Paths, valid_path(Path, 2)],
    ?assert(length(Valid) > 100),
    lists:foreach(
        fun(Path) ->
            Composed = lists:foldl(
                fun(Kind, Acc) -> ari_vtime:compose(Acc, ari_vtime:summary(Kind)) end,
                ari_vtime:summary(message),
                Path
            ),
            Applied = lists:foldl(fun(Kind, Acc) -> apply_edge(Kind, Acc) end, Time, Path),
            ?assertEqual({Path, Applied}, {Path, ari_vtime:transfer(Composed, Time)})
        end,
        Valid
    ).

apply_edge(message, Time) -> Time;
apply_edge(ingress, Time) -> ari_vtime:ingress(Time);
apply_edge(feedback, Time) -> ari_vtime:feedback(Time);
apply_edge(egress, Time) -> ari_vtime:egress(Time).

paths(_Kinds, 0) ->
    [[]];
paths(Kinds, Length) ->
    [[Kind | Rest] || Kind <- Kinds, Rest <- paths(Kinds, Length - 1)].

valid_path([], _Depth) -> true;
valid_path([message | Rest], Depth) -> valid_path(Rest, Depth);
valid_path([ingress | Rest], Depth) -> valid_path(Rest, Depth + 1);
valid_path([feedback | Rest], Depth) -> Depth > 0 andalso valid_path(Rest, Depth);
valid_path([egress | Rest], Depth) -> Depth > 0 andalso valid_path(Rest, Depth - 1).

compose_cases_test_() ->
    Summary = fun({Pop, Bump, Push}) -> ari_vtime:summary(Pop, Bump, Push) end,
    [
        ?_assertEqual(Summary(Expected), ari_vtime:compose(Summary(First), Summary(Second)))
     || {First, Second, Expected} <- [
        %% второй путь снимает меньше, чем добавил первый
        {{1, 2, [4, 7]}, {1, 3, [0]}, {1, 2, [0, 10]}},
        %% второй путь снимает ровно добавленное первым
        {{1, 2, [4]}, {1, 3, [0]}, {1, 5, [0]}},
        %% второй путь снимает и уцелевшую координату первого
        {{1, 2, [4]}, {3, 3, [0]}, {3, 3, [0]}}
    ]
    ].

dominates_test() ->
    Summary = fun({Pop, Bump, Push}) -> ari_vtime:summary(Pop, Bump, Push) end,
    ?assert(ari_vtime:dominates(Summary({0, 1, []}), Summary({0, 2, []}))),
    ?assertNot(ari_vtime:dominates(Summary({0, 2, []}), Summary({0, 1, []}))),
    ?assert(ari_vtime:dominates(Summary({1, 0, [0, 2]}), Summary({1, 0, [1, 2]}))),
    ?assertNot(ari_vtime:dominates(Summary({1, 0, [0, 3]}), Summary({1, 0, [1, 2]}))),
    ?assert(ari_vtime:dominates(Summary({1, 1, [0]}), Summary({1, 1, [0]}))),
    ?assertNot(ari_vtime:dominates(Summary({0, 0, []}), Summary({1, 0, []}))),
    ?assertNot(ari_vtime:dominates(Summary({0, 0, []}), Summary({0, 0, [0]}))).
