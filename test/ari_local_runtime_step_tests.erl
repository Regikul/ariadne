%% @doc Проверяет один атомарный переход локального runtime.
-module(ari_local_runtime_step_tests).

-include_lib("eunit/include/eunit.hrl").

compile(Items) ->
    {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
    Program.

start(Items, Inputs) ->
    {ok, Execution} = ari_local_runtime:new(compile(Items), Inputs),
    Execution.

steps(Execution, Count) ->
    {_, Next} = ari_local_runtime:advance(Execution, Count),
    Next.

inspect(Execution) ->
    ari_local_runtime:inspect(Execution).

relay(Name) ->
    relay(Name, #{}).

relay(Name, Args) ->
    ari_graph:node(Name, ari_relay_node, Args).

fan_out_items() ->
    [
        relay(a),
        relay(b),
        relay(c),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:edge(a_to_c, {a, output}, {c, input}),
        ari_graph:out(out_b, {b, output}),
        ari_graph:out(out_c, {c, output})
    ].

message_step_test() ->
    Inputs = [{input, [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}]}],
    Execution = steps(start(fan_out_items(), Inputs), 1),
    #{queues := Queues, counts := Counts, ready := Ready, states := States, steps := Steps} =
        inspect(Execution),
    ?assertEqual(
        #{input => [{m2, {5, []}}, {m3, {6, []}}], a_to_b => [{m1, {5, []}}], a_to_c => [{m1, {5, []}}], out_b => [], out_c => []},
        Queues
    ),
    ?assertEqual(#{a => #{{5, []} => 1, {6, []} => 1}, b => #{{5, []} => 1}, c => #{{5, []} => 1}}, Counts),
    ?assertEqual([{edge, a_to_b}, {edge, a_to_c}, {edge, input}], Ready),
    ?assertEqual({#{}, 1}, maps:get(a, States)),
    ?assertEqual(1, Steps).

fifo_and_fan_out_test() ->
    Inputs = [{input, [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}]}],
    {done, Execution} = ari_local_runtime:advance(start(fan_out_items(), Inputs), infinity),
    #{queues := Queues, counts := Counts, ready := Ready, steps := Steps, violations := Violations} =
        inspect(Execution),
    Expected = [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}],
    ?assertEqual(Expected, maps:get(out_b, Queues)),
    ?assertEqual(Expected, maps:get(out_c, Queues)),
    ?assertEqual([], maps:get(input, Queues)),
    ?assertEqual(#{}, Counts),
    ?assertEqual([], Ready),
    ?assertEqual(9, Steps),
    ?assertEqual([], Violations).

loop_items(Turns) ->
    [
        relay(source),
        relay(sink),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(iteration, [
            ari_graph:node(body, ari_loop_node, #{turns => Turns}),
            relay(back),
            ari_graph:in(enter, {body, input}),
            ari_graph:edge(to_back, {body, next}, {back, input}),
            ari_graph:feedback(next, {back, output}, {body, input}),
            ari_graph:out(leave, {body, exit})
        ]),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ].

edges_transform_time_test() ->
    Execution = start(loop_items(2), [{input, [{m, {5, []}}]}]),
    AfterIngress = steps(Execution, 1),
    ?assertEqual([{m, {5, [0]}}], maps:get(enter, maps:get(queues, inspect(AfterIngress)))),
    AfterBody = steps(AfterIngress, 1),
    ?assertEqual([{m, {5, [0]}}], maps:get(to_back, maps:get(queues, inspect(AfterBody)))),
    AfterFeedback = steps(AfterBody, 1),
    #{queues := Queues, counts := Counts} = inspect(AfterFeedback),
    ?assertEqual([{m, {5, [1]}}], maps:get(next, Queues)),
    ?assertEqual(#{body => #{{5, [1]} => 1}}, Counts),
    {done, Done} = ari_local_runtime:advance(AfterFeedback, infinity),
    #{queues := FinalQueues, steps := Steps, violations := Violations} = inspect(Done),
    ?assertEqual([{m, {5, []}}], maps:get(output, FinalQueues)),
    ?assertEqual(7, Steps),
    ?assertEqual([], Violations).

time_rule_on_output_test() ->
    Items = [relay(a, #{shift => -1}), ari_graph:in(input, {a, input}), ari_graph:out(output, {a, output})],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{queues := Queues, counts := Counts, states := States, violations := Violations} = inspect(Execution),
    ?assertEqual([{time_rule, a, message, {5, []}, {4, []}}], Violations),
    ?assertEqual([], maps:get(output, Queues)),
    ?assertEqual(#{}, Counts),
    ?assertEqual({#{shift => -1}, 1}, maps:get(a, States)).

time_rule_on_request_test() ->
    Items = [relay(a, #{request => [-1, 1]}), ari_graph:in(input, {a, input}), ari_graph:out(output, {a, output})],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{queues := Queues, notify := Notify, ready := Ready, violations := Violations} = inspect(Execution),
    ?assertEqual([{time_rule, a, message, {5, []}, {4, []}}], Violations),
    ?assertEqual([{m, {5, []}}], maps:get(output, Queues)),
    ?assertEqual(#{a => [{6, []}]}, Notify),
    ?assertEqual([{notify, a, {6, []}}], Ready).

crash_in_message_test() ->
    Items = [relay(a, #{crash => true}), ari_graph:in(input, {a, input}), ari_graph:out(output, {a, output})],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{queues := Queues, counts := Counts, states := States, violations := Violations, steps := Steps} =
        inspect(Execution),
    ?assertMatch([{crash, a, message, {5, []}, {error, boom, [_ | _]}}], Violations),
    ?assertEqual(#{input => [], output => []}, Queues),
    ?assertEqual(#{}, Counts),
    ?assertEqual({#{crash => true}, 0}, maps:get(a, States)),
    ?assertEqual(1, Steps).

malformed_result_test() ->
    Items = [relay(a, #{result => nonsense}), ari_graph:in(input, {a, input}), ari_graph:out(output, {a, output})],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{states := States, violations := Violations} = inspect(Execution),
    ?assertMatch([{invalid_result, a, message, {5, []}, {error, {badmatch, nonsense}, _}}], Violations),
    ?assertEqual({#{result => nonsense}, 0}, maps:get(a, States)).

invalid_time_in_result_test() ->
    Result = {state, [], [{output, m, {5, [0]}}]},
    Items = [relay(a, #{result => Result}), ari_graph:in(input, {a, input}), ari_graph:out(output, {a, output})],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{queues := Queues, violations := Violations} = inspect(Execution),
    ?assertMatch([{invalid_result, a, message, {5, []}, {error, {invalid_time, {5, [0]}}, _}}], Violations),
    ?assertEqual([], maps:get(output, Queues)).

%% Ошибка на втором выходе отбрасывает первый выход, состояние и накопленное
%% нарушение `time_rule`; входное сообщение остаётся потреблённым.
late_routing_error_discards_everything_test() ->
    Result = {state, [], [{output, m, {4, []}}, {bogus, m, {5, []}}]},
    Items = [
        relay(a, #{result => Result}),
        relay(b),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(output, {a, output}, {b, input})
    ],
    Execution = steps(start(Items, [{input, [{m, {5, []}}]}]), 1),
    #{queues := Queues, counts := Counts, ready := Ready, states := States, violations := Violations} =
        inspect(Execution),
    ?assertMatch([{invalid_result, a, message, {5, []}, {error, {badkey, bogus}, _}}], Violations),
    ?assertEqual(#{input => [], output => []}, Queues),
    ?assertEqual(#{}, Counts),
    ?assertEqual([], Ready),
    ?assertEqual({#{result => Result}, 0}, maps:get(a, States)).

notify_items(Args) ->
    [
        ari_graph:node(a, ari_notify_node, Args),
        ari_graph:in(input, {a, input}),
        ari_graph:out(output, {a, output})
    ].

notification_batches_messages_test() ->
    Inputs = [{input, [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}]}],
    Execution = start(notify_items(#{}), Inputs),
    AfterFirst = steps(Execution, 1),
    ?assertEqual(#{a => [{5, []}]}, maps:get(notify, inspect(AfterFirst))),
    ?assertEqual([{edge, input}], maps:get(ready, inspect(AfterFirst))),
    AfterSecond = steps(AfterFirst, 1),
    ?assertEqual([{edge, input}, {notify, a, {5, []}}], maps:get(ready, inspect(AfterSecond))),
    AfterThird = steps(AfterSecond, 1),
    ?assertEqual([{notify, a, {5, []}}, {notify, a, {6, []}}], maps:get(ready, inspect(AfterThird))),
    {done, Done} = ari_local_runtime:advance(AfterThird, infinity),
    #{queues := Queues, notify := Notify, scheduled := Scheduled, steps := Steps} = inspect(Done),
    ?assertEqual([{{batch, [m1, m2]}, {5, []}}, {{batch, [m3]}, {6, []}}], maps:get(output, Queues)),
    ?assertEqual(#{}, Notify),
    ?assertEqual(#{}, Scheduled),
    ?assertEqual(5, Steps).

rerequest_from_notification_test() ->
    Execution = start(notify_items(#{initial => [{5, []}], on_notify => #{{5, []} => [{5, []}]}}), []),
    AfterFirst = steps(Execution, 1),
    #{notify := Notify, ready := Ready, scheduled := Scheduled, steps := Steps} = inspect(AfterFirst),
    ?assertEqual(#{a => [{5, []}]}, Notify),
    ?assertEqual([{notify, a, {5, []}}], Ready),
    ?assertEqual(#{{a, {5, []}} => true}, Scheduled),
    ?assertEqual(1, Steps),
    {done, Done} = ari_local_runtime:advance(AfterFirst, infinity),
    #{queues := Queues, notify := FinalNotify, steps := FinalSteps} = inspect(Done),
    ?assertEqual([{{batch, []}, {5, []}}, {{batch, []}, {5, []}}], maps:get(output, Queues)),
    ?assertEqual(#{}, FinalNotify),
    ?assertEqual(2, FinalSteps).

pending_rerequest_keeps_position_test() ->
    Execution = start(notify_items(#{initial => [{5, []}, {7, []}], on_notify => #{{5, []} => [{7, []}]}}), []),
    ?assertEqual([{notify, a, {5, []}}, {notify, a, {7, []}}], maps:get(ready, inspect(Execution))),
    AfterFirst = steps(Execution, 1),
    #{notify := Notify, ready := Ready, scheduled := Scheduled} = inspect(AfterFirst),
    ?assertEqual(#{a => [{7, []}]}, Notify),
    ?assertEqual([{notify, a, {7, []}}], Ready),
    ?assertEqual(#{{a, {7, []}} => true}, Scheduled).

no_duplicate_after_rechecks_test() ->
    Items = [
        relay(a),
        ari_graph:node(b, ari_notify_node, #{}),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:out(output, {b, output})
    ],
    Inputs = [{input, [{m1, {5, []}}, {m2, {6, []}}, {m3, {7, []}}]}],
    Execution = steps(start(Items, Inputs), 3),
    ?assertEqual([{notify, b, {5, []}}, {edge, a_to_b}, {edge, input}], maps:get(ready, inspect(Execution))),
    {done, Done} = ari_local_runtime:advance(Execution, infinity),
    #{queues := Queues, violations := Violations} = inspect(Done),
    ?assertEqual(
        [{{batch, [m1]}, {5, []}}, {{batch, [m2]}, {6, []}}, {{batch, [m3]}, {7, []}}],
        maps:get(output, Queues)
    ),
    ?assertEqual([], Violations).

crash_in_notification_test() ->
    Execution = steps(start(notify_items(#{initial => [{5, []}], crash_on => [{5, []}]}), []), 1),
    #{notify := Notify, ready := Ready, scheduled := Scheduled, violations := Violations} = inspect(Execution),
    ?assertMatch([{crash, a, notification, {5, []}, {error, boom, [_ | _]}}], Violations),
    ?assertEqual(#{}, Notify),
    ?assertEqual([], Ready),
    ?assertEqual(#{}, Scheduled).

%% Обработчик уведомления `4` запрашивает `5`, пока `6` уже стоит в
%% `ready`: в ациклическом узле запросы друг друга не блокируют, поэтому
%% `5` встаёт в хвост за `6`, а `6` исполняется, не будучи минимумом
%% фронтира запросов.
later_request_below_scheduled_test() ->
    Items = notify_items(#{initial => [{4, []}, {6, []}], on_notify => #{{4, []} => [{5, []}]}}),
    Execution = start(Items, []),
    ?assertEqual([{notify, a, {4, []}}, {notify, a, {6, []}}], maps:get(ready, inspect(Execution))),
    AfterFirst = steps(Execution, 1),
    #{ready := Ready, requests := Requests} = inspect(AfterFirst),
    ?assertEqual([{notify, a, {6, []}}, {notify, a, {5, []}}], Ready),
    ?assertEqual(#{a => [{5, []}]}, Requests),
    AfterSecond = steps(AfterFirst, 1),
    #{notify := Notify, requests := Remaining, scheduled := Scheduled} = inspect(AfterSecond),
    ?assertEqual(#{a => [{5, []}]}, Notify),
    ?assertEqual(#{a => [{5, []}]}, Remaining),
    ?assertEqual(#{{a, {5, []}} => true}, Scheduled),
    {done, Done} = ari_local_runtime:advance(AfterSecond, infinity),
    ?assertEqual(
        [{{batch, []}, {4, []}}, {{batch, []}, {6, []}}, {{batch, []}, {5, []}}],
        maps:get(output, ari_local_runtime:outputs(Done))
    ).

%% Запрос `agg 7` заблокирован сообщением `6` в `a`; пришедшее в `a`
%% меньшее `5` вытесняет `6` из фронтира и наследует его свидетельство.
smaller_time_inherits_witness_test() ->
    Items = [
        relay(s),
        relay(t),
        relay(a),
        ari_graph:node(agg, ari_notify_node, #{}),
        ari_graph:in(e1, {agg, input}),
        ari_graph:in(e2, {s, input}),
        ari_graph:in(e3, {t, input}),
        ari_graph:edge(s_to_a, {s, output}, {a, input}),
        ari_graph:edge(t_to_a, {t, output}, {a, input}),
        ari_graph:edge(a_to_agg, {a, output}, {agg, input}),
        ari_graph:out(output, {agg, output})
    ],
    Inputs = [{e1, [{m7, {7, []}}]}, {e2, [{m6, {6, []}}]}, {e3, [{m5, {5, []}}]}],
    Execution = start(Items, Inputs),
    AfterTwo = steps(Execution, 2),
    ?assertEqual(#{{message, a, {6, []}} => [{agg, {7, []}}]}, maps:get(blockers, inspect(AfterTwo))),
    AfterThree = steps(AfterTwo, 1),
    #{blockers := Blockers, messages := Messages} = inspect(AfterThree),
    ?assertEqual(#{{message, a, {5, []}} => [{agg, {7, []}}]}, Blockers),
    ?assertEqual([{5, []}], maps:get(a, Messages)),
    {done, Done} = ari_local_runtime:advance(AfterThree, infinity),
    ?assertEqual(
        [{{batch, [m5]}, {5, []}}, {{batch, [m6]}, {6, []}}, {{batch, [m7]}, {7, []}}],
        maps:get(output, ari_local_runtime:outputs(Done))
    ).
