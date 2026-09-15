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

accepted_events_are_queued_as_they_are_test() ->
    T = ari_vtime:new(0),
    E0 = ari_engine:accept([{input, a, T}, {link, b, T}], engine(chain())),
    {{input, a, T}, E1} = ari_engine:dequeue(E0),
    {{link, b, T}, E2} = ari_engine:dequeue(E1),
    ?assertEqual(empty, ari_engine:dequeue(E2)).

%%%===================================================================
%%% The copies
%%%===================================================================

a_message_of_a_key_of_this_copy_is_queued_test() ->
    T = ari_vtime:new(0),
    [Mine | _] = of_copy(1, 2),
    {E0, _} = ari_engine:push(input, [Mine], T, ari_engine:new(ari_plan:prepare(keyed()), 1, 2)),
    {Event, E1} = ari_engine:dequeue(E0),
    {E2, Delta} = ari_engine:deliver(Event, E1),
    ?assertEqual({[{{edge, input}, T}], [{{edge, link}, T}]}, Delta),
    ?assertMatch({{link, Mine, T}, _}, ari_engine:dequeue(E2)),
    ?assertMatch({#{}, _}, ari_engine:outbox(E2)).

a_message_of_a_key_of_another_copy_goes_to_the_outbox_test() ->
    T = ari_vtime:new(0),
    [Theirs | _] = of_copy(1, 2),
    {E0, _} = ari_engine:push(input, [Theirs], T, ari_engine:new(ari_plan:prepare(keyed()), 2, 2)),
    {Event, E1} = ari_engine:dequeue(E0),
    {E2, Delta} = ari_engine:deliver(Event, E1),
    ?assertEqual({[{{edge, input}, T}], [{{edge, link}, T}]}, Delta),
    ?assertEqual(empty, ari_engine:dequeue(E2)),
    {Outbox, E3} = ari_engine:outbox(E2),
    ?assertEqual(#{1 => [{link, Theirs, T}]}, Outbox),
    ?assertEqual({#{}, E3}, ari_engine:outbox(E3)).

the_outbox_keeps_the_order_of_the_messages_of_a_copy_test() ->
    T = ari_vtime:new(0),
    Theirs = of_copy(1, 2),
    {E0, _} = ari_engine:push(input, Theirs, T, ari_engine:new(ari_plan:prepare(keyed()), 2, 2)),
    E1 = deliver_all(E0),
    {Outbox, _E2} = ari_engine:outbox(E1),
    ?assertEqual(#{1 => [{link, N, T} || N <- Theirs]}, Outbox).

the_only_copy_queues_every_key_test() ->
    T = ari_vtime:new(0),
    {E0, _} = ari_engine:push(input, [1, 2], T, engine(keyed())),
    E1 = deliver_all(E0),
    ?assertMatch({#{}, _}, ari_engine:outbox(E1)),
    ?assertMatch([{1, T}, {2, T}], element(1, ari_engine:pull(output, E1))).

%%%===================================================================
%%% Helpers
%%%===================================================================

engine(Graph) ->
    ari_engine:new(ari_plan:prepare(Graph)).

%% Delivers every message of the queue.
deliver_all(Engine) ->
    case ari_engine:dequeue(Engine) of
        {Event, Engine2} ->
            {Engine3, _Delta} = ari_engine:deliver(Event, Engine2),
            deliver_all(Engine3);
        empty ->
            Engine
    end.

%% Some numbers, keyed by themselves, that belong to copy `Copy' of
%% `Count', see ari_plan:partition/4.
of_copy(Copy, Count) ->
    [N || N <- lists:seq(1, 20), erlang:phash2(N, Count) + 1 =:= Copy].

%% The chain with its link partitioned by the message, a number
%% keyed by itself.
keyed() ->
    ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {second, in}, #{key => fun(N) -> N end}),
        ari_graph:node(second, ari_test_pass, []),
        ari_graph:out(output, {second, out})
    ]).

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
