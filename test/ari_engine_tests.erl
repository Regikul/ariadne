-module(ari_engine_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Deltas
%%%===================================================================

pushing_adds_the_work_of_every_item_test() ->
    T = ari_vtime:new(0),
    {_E, Delta} = ari_engine:push(input, [a, b], T, engine(passing())),
    ?assertEqual({[], [{{edge, input}, T}, {{edge, input}, T}]}, Delta).

pushing_on_an_output_adds_nothing_test() ->
    T = ari_vtime:new(0),
    {E, Delta} = ari_engine:push(output, [a], T, engine(passing())),
    ?assertEqual({[], []}, Delta),
    ?assertMatch({[{a, T}], _}, ari_engine:pull(output, E)).

delivering_releases_the_message_and_adds_what_was_sent_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [a], T, engine(chain())),
    {Event, E1} = ari_engine:dequeue(E0),
    {_E2, Delta} = ari_engine:deliver(Event, E1),
    ?assertEqual({[{{edge, input}, T}], [{{edge, link}, T}]}, Delta).

a_message_going_along_two_edges_is_added_twice_test() ->
    T = ari_vtime:new(0),
    E0 = engine(ari_graph:graph([
        ari_graph:in(input, {source, in}),
        ari_graph:node(source, ari_test_pass, []),
        ari_graph:edge(to_left, {source, out}, {left, in}),
        ari_graph:edge(to_right, {source, out}, {right, in}),
        ari_graph:node(left, ari_test_pass, []),
        ari_graph:node(right, ari_test_pass, [])
    ])),
    {E1, _} = ari_engine:push(input, [a], T, E0),
    {Event, E2} = ari_engine:dequeue(E1),
    {_E3, {_Released, Added}} = ari_engine:deliver(Event, E2),
    ?assertEqual([{{edge, to_left}, T}, {{edge, to_right}, T}], Added).

delivering_adds_the_notifications_asked_for_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [a], T, engine(waiting([0, 1]))),
    {Event, E1} = ari_engine:dequeue(E0),
    {E2, Delta} = ari_engine:deliver(Event, E1),
    ?assertEqual(
        {[{{edge, input}, T}], [{{vertex, waiter}, T}, {{vertex, waiter}, ari_vtime:new(1)}]},
        Delta
    ),
    ?assertEqual(
        [{waiter, T}, {waiter, ari_vtime:new(1)}],
        lists:sort(ari_engine:notifications(E2))
    ).

a_notification_asked_for_again_is_added_once_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [a, b], T, engine(waiting([0]))),
    {Event1, E1} = ari_engine:dequeue(E0),
    {E2, {_, Added1}} = ari_engine:deliver(Event1, E1),
    {Event2, E3} = ari_engine:dequeue(E2),
    {E4, {_, Added2}} = ari_engine:deliver(Event2, E3),
    ?assertEqual([{{vertex, waiter}, T}], Added1),
    ?assertEqual([], Added2),
    ?assertEqual([{waiter, T}], ari_engine:notifications(E4)).

notifying_releases_the_notification_and_adds_what_was_sent_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [a], T, engine(waiting([0]))),
    {Event, E1} = ari_engine:dequeue(E0),
    {E2, _} = ari_engine:deliver(Event, E1),
    {E3, Delta} = ari_engine:notify(waiter, T, E2),
    ?assertEqual({[{{vertex, waiter}, T}], []}, Delta),
    ?assertEqual([], ari_engine:notifications(E3)),
    ?assertMatch({[{fired, T}], _}, ari_engine:pull(done, E3)).

a_notification_not_asked_for_is_refused_test() ->
    T = ari_vtime:new(0),
    ?assertError(
        {unknown_notification, {waiter, T}},
        ari_engine:notify(waiter, T, engine(waiting([0])))
    ).

%%%===================================================================
%%% The queue
%%%===================================================================

messages_are_dequeued_in_the_order_they_were_pushed_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [a, b], T, engine(passing())),
    {{input, a, T}, E1} = ari_engine:dequeue(E0),
    {{input, b, T}, E2} = ari_engine:dequeue(E1),
    ?assertEqual(empty, ari_engine:dequeue(E2)).

%%%===================================================================
%%% Helpers
%%%===================================================================

engine(Graph) ->
    ari_engine:new(ari_plan:prepare(Graph)).

%% An input passed straight to an output.
passing() ->
    ari_graph:graph([
        ari_graph:in(input, {pass, in}),
        ari_graph:node(pass, ari_test_pass, []),
        ari_graph:out(output, {pass, out})
    ]).

%% Two passing vertices one after the other.
chain() ->
    ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_pass, []),
        ari_graph:out(output, {second, out})
    ]).

%% A vertex asking to be notified at `Epochs' on every message.
waiting(Epochs) ->
    ari_graph:graph([
        ari_graph:in(input, {waiter, in}),
        ari_graph:node(waiter, ari_test_waiter, Epochs),
        ari_graph:out(done, {waiter, done})
    ]).
