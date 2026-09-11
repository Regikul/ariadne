%% @doc Проверяет управление прогоном: бюджет, покой и результаты.
-module(ari_local_runtime_run_tests).

-include_lib("eunit/include/eunit.hrl").

start(Items, Inputs) ->
    {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
    {ok, Execution} = ari_local_runtime:new(Program, Inputs),
    Execution.

relay(Name) ->
    ari_graph:node(Name, ari_relay_node, #{}).

%% Цепочка `a -> b -> c` и узел `d`, копящий сообщения до уведомления.
chain_items() ->
    [
        relay(a),
        relay(b),
        ari_graph:node(c, ari_relay_node, #{shift => -1}),
        ari_graph:node(d, ari_notify_node, #{}),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:edge(b_to_c, {b, output}, {c, input}),
        ari_graph:edge(b_to_d, {b, output}, {d, input}),
        ari_graph:out(out_c, {c, output}),
        ari_graph:out(out_d, {d, output})
    ].

chain_inputs() ->
    [{input, [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}]}].

loop_items(Turns) ->
    [
        relay(source),
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
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ].

%% Разовый прогон из спецификации.
run(Execution) ->
    {done, Done} = ari_local_runtime:advance(Execution, infinity),
    {ari_local_runtime:outputs(Done), ari_local_runtime:violations(Done)}.

results_test() ->
    Execution = start(chain_items(), chain_inputs()),
    {done, Done} = ari_local_runtime:advance(Execution, infinity),
    ?assertEqual(
        #{
            out_c => [],
            out_d => [{{batch, [m1, m2]}, {5, []}}, {{batch, [m3]}, {6, []}}]
        },
        ari_local_runtime:outputs(Done)
    ),
    ?assertEqual(
        [
            {time_rule, c, message, {5, []}, {4, []}},
            {time_rule, c, message, {5, []}, {4, []}},
            {time_rule, c, message, {6, []}, {5, []}}
        ],
        ari_local_runtime:violations(Done)
    ),
    %% три сообщения в `a`, `b`, `c`, `d` и два уведомления в `d`
    ?assertEqual(14, ari_local_runtime:steps(Done)),
    #{ready := Ready, notify := Notify, scheduled := Scheduled, counts := Counts} =
        ari_local_runtime:inspect(Done),
    ?assertEqual({[], #{}, #{}, #{}}, {Ready, Notify, Scheduled, Counts}).

run_helper_test() ->
    Execution = start(loop_items(3), [{input, [{m, {5, []}}]}]),
    ?assertEqual({#{output => [{m, {5, []}}]}, []}, run(Execution)).

done_is_stable_test() ->
    Execution = start(chain_items(), chain_inputs()),
    {done, Done} = ari_local_runtime:advance(Execution, infinity),
    ?assertEqual({done, Done}, ari_local_runtime:advance(Done, 1)),
    ?assertEqual({done, Done}, ari_local_runtime:advance(Done, infinity)).

budget_boundary_test() ->
    Execution = start(chain_items(), chain_inputs()),
    {more, Partial} = ari_local_runtime:advance(Execution, 13),
    ?assertEqual(13, ari_local_runtime:steps(Partial)),
    ?assertMatch({done, _}, ari_local_runtime:advance(Partial, 1)),
    {done, Exact} = ari_local_runtime:advance(Execution, 14),
    ?assertEqual(14, ari_local_runtime:steps(Exact)),
    {done, Over} = ari_local_runtime:advance(Execution, 100),
    ?assertEqual(Exact, Over).

continuation_matches_single_run_test() ->
    Execution = start(chain_items(), chain_inputs()),
    {done, Whole} = ari_local_runtime:advance(Execution, infinity),
    {more, First} = ari_local_runtime:advance(Execution, 5),
    {more, Second} = ari_local_runtime:advance(First, 5),
    {done, Third} = ari_local_runtime:advance(Second, infinity),
    ?assertEqual(Whole, Third).

%% Снимки состояния после каждого шага при бюджете 1 совпадают со снимками
%% на тех же шагах при бюджете 3.
budgets_share_one_trace_test() ->
    Execution = start(chain_items(), chain_inputs()),
    ByOne = snapshots(Execution, 1),
    ByThree = snapshots(Execution, 3),
    ?assertEqual(14, maps:size(ByOne)),
    ?assertEqual([3, 6, 9, 12, 14], lists:sort(maps:keys(ByThree))),
    maps:foreach(fun(Steps, Snapshot) -> ?assertEqual(Snapshot, maps:get(Steps, ByOne)) end, ByThree).

snapshots(Execution, Budget) ->
    snapshots(Execution, Budget, #{}).

snapshots(Execution, Budget, Acc) ->
    case ari_local_runtime:advance(Execution, Budget) of
        {done, Next} ->
            Acc#{ari_local_runtime:steps(Next) => ari_local_runtime:inspect(Next)};
        {more, Next} ->
            snapshots(Next, Budget, Acc#{ari_local_runtime:steps(Next) => ari_local_runtime:inspect(Next)})
    end.

divergent_loop_returns_on_budget_test() ->
    Execution = start(loop_items(infinity), [{input, [{m, {5, []}}]}]),
    {more, First} = ari_local_runtime:advance(Execution, 50),
    ?assertEqual(50, ari_local_runtime:steps(First)),
    {more, Second} = ari_local_runtime:advance(First, 50),
    ?assertEqual(100, ari_local_runtime:steps(Second)),
    #{queues := Queues} = ari_local_runtime:inspect(Second),
    ?assertEqual([], maps:get(output, Queues)),
    %% шаг 1 — `source`, далее `body` на чётных шагах: 50 оборотов начаты
    ?assertEqual([{m, {5, [49]}}], maps:get(to_back, Queues)).

divergent_requests_return_on_budget_test() ->
    Items = [
        ari_graph:node(a, ari_notify_node, #{initial => [{5, []}], forever => [{5, []}]}),
        ari_graph:out(output, {a, output})
    ],
    Execution = start(Items, []),
    {more, Partial} = ari_local_runtime:advance(Execution, 7),
    ?assertEqual(7, ari_local_runtime:steps(Partial)),
    #{ready := Ready, notify := Notify, scheduled := Scheduled} = ari_local_runtime:inspect(Partial),
    ?assertEqual([{notify, a, {5, []}}], Ready),
    ?assertEqual(#{a => [{5, []}]}, Notify),
    ?assertEqual(#{{a, {5, []}} => true}, Scheduled),
    ?assertEqual(7, length(maps:get(output, ari_local_runtime:outputs(Partial)))).
