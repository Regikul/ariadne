-module(ari_single_runtime_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ari_graph.hrl").

%%%===================================================================
%%% Messages
%%%===================================================================

messages_pass_through_the_graph_in_order_test() ->
    R0 = ari_single_runtime:new(passing()),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 0, [a, b, c], R0)),
    T = ari_vtime:new(0),
    ?assertMatch({[{a, T}, {b, T}, {c, T}], _}, ari_single_runtime:pull(output, R1)).

nothing_is_delivered_until_a_step_test() ->
    R = ari_single_runtime:push(input, 0, [a], ari_single_runtime:new(passing())),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R)).

a_step_delivers_one_message_test() ->
    R0 = ari_single_runtime:push(input, 0, [a, b], ari_single_runtime:new(passing())),
    {ok, R1} = ari_single_runtime:step(R0),
    {[{a, _}], R2} = ari_single_runtime:pull(output, R1),
    {ok, R3} = ari_single_runtime:step(R2),
    {[{b, _}], R4} = ari_single_runtime:pull(output, R3),
    ?assertEqual(idle, ari_single_runtime:step(R4)).

running_an_idle_runtime_changes_nothing_test() ->
    R = ari_single_runtime:new(passing()),
    ?assertEqual(R, ari_single_runtime:run(R)).

a_message_goes_along_every_edge_of_its_slot_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {source, in}),
        ari_graph:node(source, ari_test_pass, []),
        ari_graph:edge(to_left, {source, out}, {left, in}),
        ari_graph:edge(to_right, {source, out}, {right, in}),
        ari_graph:node(left, ari_test_pass, []),
        ari_graph:node(right, ari_test_pass, []),
        ari_graph:out(left_output, {left, out}),
        ari_graph:out(right_output, {right, out})
    ])),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 0, [a], R0)),
    ?assertMatch({[{a, _}], _}, ari_single_runtime:pull(left_output, R1)),
    ?assertMatch({[{a, _}], _}, ari_single_runtime:pull(right_output, R1)).

the_edges_of_a_slot_merge_into_one_stream_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(left, {pass, in}),
        ari_graph:in(right, {pass, in}),
        ari_graph:node(pass, ari_test_pass, []),
        ari_graph:out(output, {pass, out})
    ])),
    R1 = ari_single_runtime:push(left, 0, [a], R0),
    R2 = ari_single_runtime:push(right, 0, [b], R1),
    R3 = ari_single_runtime:push(left, 0, [c], R2),
    R4 = ari_single_runtime:run(R3),
    ?assertMatch({[{a, _}, {b, _}, {c, _}], _}, ari_single_runtime:pull(output, R4)).

a_message_to_a_slot_without_edges_is_dropped_test() ->
    %% Nothing is attached to `continue', where a number below the
    %% limit goes.
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:node(inc, ari_test_until, 3),
        ari_graph:out(output, {inc, done})
    ])),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 0, [0], R0)),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R1)).

pull_takes_the_items_away_test() ->
    R0 = ari_single_runtime:push(input, 0, [a], ari_single_runtime:new(passing())),
    {[{a, _}], R1} = ari_single_runtime:pull(output, ari_single_runtime:run(R0)),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R1)).

%%%===================================================================
%%% Notifications
%%%===================================================================

a_notification_waits_for_the_epoch_to_close_test() ->
    R0 = ari_single_runtime:new(counting()),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 0, [a, b], R0)),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R1)),
    R2 = ari_single_runtime:run(ari_single_runtime:close(input, 0, R1)),
    ?assertEqual([{2, ari_vtime:new(0)}], element(1, ari_single_runtime:pull(output, R2))).

a_notification_waits_for_every_input_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(left, {count, in}),
        ari_graph:in(right, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ])),
    R1 = ari_single_runtime:push(left, 0, [a], R0),
    R2 = ari_single_runtime:push(right, 0, [b], R1),
    R3 = ari_single_runtime:run(ari_single_runtime:close(left, 0, R2)),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R3)),
    R4 = ari_single_runtime:run(ari_single_runtime:close(right, 0, R3)),
    ?assertMatch({[{2, _}], _}, ari_single_runtime:pull(output, R4)).

a_closed_epoch_completes_while_a_later_one_is_open_test() ->
    R0 = ari_single_runtime:new(counting()),
    R1 = ari_single_runtime:push(input, 0, [a, b], R0),
    R2 = ari_single_runtime:push(input, 1, [c], R1),
    R3 = ari_single_runtime:run(ari_single_runtime:close(input, 0, R2)),
    {First, R4} = ari_single_runtime:pull(output, R3),
    ?assertEqual([{2, ari_vtime:new(0)}], First),
    R5 = ari_single_runtime:run(ari_single_runtime:close(input, 1, R4)),
    ?assertEqual([{1, ari_vtime:new(1)}], element(1, ari_single_runtime:pull(output, R5))).

a_notification_may_be_asked_for_a_later_time_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {waiter, in}),
        ari_graph:node(waiter, ari_test_waiter, [2]),
        ari_graph:out(output, {waiter, done})
    ])),
    R1 = ari_single_runtime:push(input, 0, [a], R0),
    R2 = ari_single_runtime:run(ari_single_runtime:close(input, 1, R1)),
    ?assertMatch({[], _}, ari_single_runtime:pull(output, R2)),
    R3 = ari_single_runtime:run(ari_single_runtime:close(input, 2, R2)),
    ?assertEqual([{fired, ari_vtime:new(2)}], element(1, ari_single_runtime:pull(output, R3))).

a_notification_asked_for_twice_is_delivered_once_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {waiter, in}),
        ari_graph:node(waiter, ari_test_waiter, [0, 0]),
        ari_graph:out(output, {waiter, done})
    ])),
    R1 = ari_single_runtime:push(input, 0, [a, b], R0),
    R2 = ari_single_runtime:run(ari_single_runtime:close(input, 0, R1)),
    ?assertMatch({[{fired, _}], _}, ari_single_runtime:pull(output, R2)).

a_notification_waits_for_the_messages_upstream_test() ->
    %% The counter is notified only once the passer has passed
    %% everything of the epoch on, however many steps that takes.
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {pass, in}),
        ari_graph:node(pass, ari_test_pass, []),
        ari_graph:edge(counted, {pass, out}, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ])),
    R1 = ari_single_runtime:close(input, 0, ari_single_runtime:push(input, 0, [a, b, c], R0)),
    R2 = ari_single_runtime:run(R1),
    ?assertMatch({[{3, _}], _}, ari_single_runtime:pull(output, R2)).

%%%===================================================================
%%% Loops
%%%===================================================================

a_loop_iterates_until_the_vertex_is_done_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, 3),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:out(output, {inc, done})
    ])),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 0, [0, 1], R0)),
    T = ari_vtime:new(0),
    ?assertMatch({[{3, T}, {3, T}], _}, ari_single_runtime:pull(output, R1)).

iterations_complete_one_after_another_test() ->
    %% The tracker is notified at every iteration, and the reports
    %% come in the order of the iterations.
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {tracker, in}),
        ari_graph:loop(spin, [
            ari_graph:node(tracker, ari_test_tracker, 2),
            ari_graph:feedback(again, {tracker, continue}, {tracker, in})
        ]),
        ari_graph:out(output, {tracker, done})
    ])),
    R1 = ari_single_runtime:close(input, 0, ari_single_runtime:push(input, 0, [0], R0)),
    R2 = ari_single_runtime:run(R1),
    T0 = ari_vtime:ingress(ari_vtime:new(0)),
    T1 = ari_vtime:feedback(T0),
    T2 = ari_vtime:feedback(T1),
    Left = ari_vtime:new(0),
    ?assertMatch(
        {[{{1, T0}, Left}, {{2, T1}, Left}, {{3, T2}, Left}], _},
        ari_single_runtime:pull(output, R2)
    ).

an_epoch_does_not_complete_while_the_loop_spins_test() ->
    %% The counter after the loop is notified only once the loop has
    %% let every item of the epoch out.
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, 5),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:edge(counted, {inc, done}, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ])),
    R1 = ari_single_runtime:close(input, 0, ari_single_runtime:push(input, 0, [0, 3], R0)),
    R2 = ari_single_runtime:run(R1),
    ?assertMatch({[{2, _}], _}, ari_single_runtime:pull(output, R2)).

an_output_inside_of_a_loop_leaves_the_loop_test() ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, 2),
            ari_graph:feedback(again, {inc, continue}, {inc, in}),
            ari_graph:out(output, {inc, done})
        ])
    ])),
    R1 = ari_single_runtime:run(ari_single_runtime:push(input, 4, [0], R0)),
    ?assertEqual([{2, ari_vtime:new(4)}], element(1, ari_single_runtime:pull(output, R1))).

%%%===================================================================
%%% Inputs and outputs
%%%===================================================================

an_input_has_to_exist_test() ->
    R = ari_single_runtime:new(passing()),
    ?assertError({unknown_input, nowhere}, ari_single_runtime:push(nowhere, 0, [a], R)),
    ?assertError({unknown_input, nowhere}, ari_single_runtime:close(nowhere, 0, R)).

an_output_has_to_exist_test() ->
    R = ari_single_runtime:new(passing()),
    ?assertError({unknown_output, nowhere}, ari_single_runtime:pull(nowhere, R)).

a_closed_epoch_takes_no_items_test() ->
    R = ari_single_runtime:close(input, 1, ari_single_runtime:new(passing())),
    ?assertError({closed, {input, 0}}, ari_single_runtime:push(input, 0, [a], R)),
    ?assertError({closed, {input, 1}}, ari_single_runtime:push(input, 1, [a], R)),
    ?assertNotEqual(R, ari_single_runtime:push(input, 2, [a], R)).

closing_an_epoch_again_changes_nothing_test() ->
    R = ari_single_runtime:close(input, 1, ari_single_runtime:new(passing())),
    ?assertEqual(R, ari_single_runtime:close(input, 0, R)),
    ?assertEqual(R, ari_single_runtime:close(input, 1, R)).

%%%===================================================================
%%% Misbehaving vertices
%%%===================================================================

a_message_is_not_sent_into_the_past_test() ->
    Past = ari_vtime:new(0),
    R = ari_single_runtime:push(input, 1, [a], ari_single_runtime:new(rogue({time, Past}))),
    ?assertError({message_in_the_past, {rogue, Past}}, ari_single_runtime:run(R)).

a_message_is_not_sent_to_another_depth_test() ->
    Deeper = ari_vtime:ingress(ari_vtime:new(0)),
    R = ari_single_runtime:push(input, 0, [a], ari_single_runtime:new(rogue({time, Deeper}))),
    ?assertError({message_in_the_past, {rogue, Deeper}}, ari_single_runtime:run(R)).

a_notification_is_not_asked_for_the_past_test() ->
    Past = ari_vtime:new(0),
    R = ari_single_runtime:push(input, 1, [a], ari_single_runtime:new(rogue({notify, Past}))),
    ?assertError({notification_in_the_past, {rogue, Past}}, ari_single_runtime:run(R)).

a_message_is_sent_to_an_output_slot_test() ->
    R = ari_single_runtime:push(input, 0, [a], ari_single_runtime:new(rogue({slot, in}))),
    ?assertError({unknown_slot, {rogue, in}}, ari_single_runtime:run(R)).

%%%===================================================================
%%% Shutting down
%%%===================================================================

stop_terminates_every_vertex_test() ->
    Self = self(),
    R = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_reporter, {first, Self}),
        ari_graph:edge(between, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_reporter, {second, Self}),
        ari_graph:out(output, {second, out})
    ])),
    ?assertEqual(ok, ari_single_runtime:stop(R)),
    ?assertEqual([first, second], lists:sort(terminated([]))).

stop_terminates_every_vertex_when_one_fails_test() ->
    Self = self(),
    R = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_reporter, {first, Self, terminate}),
        ari_graph:edge(between, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_reporter, {second, Self}),
        ari_graph:out(output, {second, out})
    ])),
    ?assertError({terminate_failed, first}, ari_single_runtime:stop(R)),
    ?assertEqual([first, second], lists:sort(terminated([]))).

new_terminates_initialised_vertices_when_init_fails_test() ->
    Self = self(),
    Graph = ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_reporter, {first, Self}),
        ari_graph:edge(between, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_reporter, {second, Self, init}),
        ari_graph:edge(onward, {second, out}, {third, in}),
        ari_graph:node(third, ari_test_reporter, {third, Self}),
        ari_graph:out(output, {third, out})
    ]),
    ?assertError({init_failed, second}, ari_single_runtime:new(Graph)),
    ?assertEqual([first], terminated([])).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% A graph passing `input' on to `output' as it is.
-spec passing() -> #graph{}.
passing() ->
    ari_graph:graph([
        ari_graph:in(input, {pass, in}),
        ari_graph:node(pass, ari_test_pass, []),
        ari_graph:out(output, {pass, out})
    ]).

%% A graph counting the items of `input' per epoch.
-spec counting() -> #graph{}.
counting() ->
    ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]).

%% A graph of a single vertex breaking the rule `Rule', see
%% ari_test_rogue.
-spec rogue(Rule :: term()) -> #graph{}.
rogue(Rule) ->
    ari_graph:graph([
        ari_graph:in(input, {rogue, in}),
        ari_graph:node(rogue, ari_test_rogue, Rule),
        ari_graph:out(output, {rogue, out})
    ]).

%% The names the terminated vertices reported.
-spec terminated([atom()]) -> [atom()].
terminated(Names) ->
    receive
        {terminated, Name} -> terminated([Name | Names])
    after 0 ->
        Names
    end.
