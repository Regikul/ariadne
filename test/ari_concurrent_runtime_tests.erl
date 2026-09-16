-module(ari_concurrent_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

%%%===================================================================
%%% The branch
%%%===================================================================

the_branch_starts_a_scope_with_the_workers_and_the_coordinator_test() ->
    Sup = start(scoped, chain(), 2),
    ?assertEqual(2, length(pg:get_local_members(scoped, workers))),
    ?assertMatch([_], pg:get_local_members(scoped, coordinator)),
    stop(Sup).

the_workers_are_numbered_test() ->
    Sup = start(numbered, chain(), 3),
    Workers = pg:get_local_members(numbered, workers),
    ?assertEqual([1, 2, 3], lists:sort([ari_crt_worker:index(W) || W <- Workers])),
    stop(Sup).

stopping_the_branch_terminates_every_vertex_of_every_worker_test() ->
    Sup = start(terminating, reporting(self()), 2),
    stop(Sup),
    ?assertEqual([reporter, reporter], receive_all(terminated)).

the_branch_is_embedded_by_its_child_spec_test() ->
    {ok, Sup} = supervisor:start_link(?MODULE, chain()),
    ?assertMatch([_], pg:get_local_members(embedded, workers)),
    ?assertMatch([_], pg:get_local_members(embedded, coordinator)),
    stop(Sup).

the_branch_refuses_a_broken_graph_test() ->
    process_flag(trap_exit, true),
    Broken = ari_graph:graph([
        ari_graph:in(input, {nowhere, in})
    ]),
    ?assertMatch(
        {error, {{unknown_vertex, {input, nowhere}}, _}},
        ari_concurrent_sup:start_link(broken, Broken, #{workers => 1})
    ).

the_branch_refuses_bad_options_test() ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{bad_option, {workers, undefined}}, _}},
        ari_concurrent_sup:start_link(unworked, chain(), #{})
    ),
    ?assertMatch(
        {error, {{bad_option, {max_in_flight, 0}}, _}},
        ari_concurrent_sup:start_link(unlimited, chain(), #{workers => 1, max_in_flight => 0})
    ),
    ?assertMatch(
        {error, {{bad_option, {max_heap_size, -1}}, _}},
        ari_concurrent_sup:start_link(unheaped, chain(), #{workers => 1, max_heap_size => -1})
    ).

%%%===================================================================
%%% The calls
%%%===================================================================

a_call_to_a_runtime_not_running_exits_test() ->
    ?assertExit({not_running, nobody}, ari_concurrent_runtime:push(nobody, input, 0, [a])).

the_calls_reach_the_coordinator_test() ->
    Sup = start(called, chain(), 1),
    ?assertEqual(ok, ari_concurrent_runtime:push(called, input, 0, [a])),
    ?assertEqual(ok, ari_concurrent_runtime:close(called, input, 0)),
    stop(Sup).

subscribing_joins_the_group_of_the_output_test() ->
    Sup = start(subscribed, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(subscribed, output),
    ?assertEqual([self()], pg:get_local_members(subscribed, {output, output})),
    stop(Sup).

an_input_has_to_exist_test() ->
    Sup = start(strict, chain(), 1),
    ?assertEqual({error, {unknown_input, other}}, ari_concurrent_runtime:push(strict, other, 0, [a])),
    ?assertEqual({error, {unknown_input, other}}, ari_concurrent_runtime:close(strict, other, 0)),
    stop(Sup).

a_closed_epoch_takes_no_items_and_the_runtime_goes_on_test() ->
    Sup = start(refusing, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(refusing, output),
    ok = ari_concurrent_runtime:close(refusing, input, 0),
    ?assertEqual({error, {closed, {input, 0}}}, ari_concurrent_runtime:push(refusing, input, 0, [a])),
    ok = ari_concurrent_runtime:push(refusing, input, 1, [b]),
    ?assertEqual({b, ari_vtime:new(1)}, receive_one(refusing, output)),
    stop(Sup).

%%%===================================================================
%%% Messages
%%%===================================================================

messages_pass_through_the_graph_to_the_subscribers_test() ->
    Sup = start(passing, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(passing, output),
    ok = ari_concurrent_runtime:push(passing, input, 0, [a, b, c]),
    T = ari_vtime:new(0),
    ?assertEqual([{a, T}, {b, T}, {c, T}], receive_n(3, passing, output)),
    stop(Sup).

the_items_are_spread_over_the_workers_in_turn_test() ->
    Sup = start(spread, tracing(), 2),
    ok = ari_concurrent_runtime:subscribe(spread, output),
    ok = ari_concurrent_runtime:push(spread, input, 0, [a, b, c, d]),
    Traced = [{Item, ari_crt_worker:index(Pid)} || {{Item, Pid}, _Time} <- receive_n(4, spread, output)],
    ?assertEqual([{a, 1}, {b, 2}, {c, 1}, {d, 2}], lists:keysort(1, Traced)),
    stop(Sup).

a_worker_keeps_the_order_of_its_items_test() ->
    Sup = start(ordered, tracing(), 2),
    ok = ari_concurrent_runtime:subscribe(ordered, output),
    ok = ari_concurrent_runtime:push(ordered, input, 0, [a, b, c, d]),
    Traced = [{Item, ari_crt_worker:index(Pid)} || {{Item, Pid}, _Time} <- receive_n(4, ordered, output)],
    ?assertEqual([a, c], [Item || {Item, 1} <- Traced]),
    ?assertEqual([b, d], [Item || {Item, 2} <- Traced]),
    stop(Sup).

a_long_queue_is_delivered_over_several_rounds_test() ->
    Sup = start(long, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(long, output),
    Items = lists:seq(1, 2500),
    ok = ari_concurrent_runtime:push(long, input, 0, Items),
    ?assertEqual(Items, [Item || {Item, _Time} <- receive_n(2500, long, output)]),
    stop(Sup).

a_worker_takes_in_what_came_while_it_was_busy_as_one_round_test() ->
    Sup = start(busy, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(busy, output),
    [Worker] = pg:get_local_members(busy, workers),
    [Coordinator] = pg:get_local_members(busy, coordinator),
    ok = sys:suspend(Worker),
    ok = ari_concurrent_runtime:push(busy, input, 0, [a, b]),
    ok = ari_concurrent_runtime:push(busy, input, 0, [c]),
    ok = ari_concurrent_runtime:push(busy, input, 0, [d, e]),
    1 = erlang:trace(Coordinator, true, ['receive']),
    ok = sys:resume(Worker),
    T = ari_vtime:new(0),
    ?assertEqual([{a, T}, {b, T}, {c, T}, {d, T}, {e, T}], receive_n(5, busy, output)),
    ?assertEqual(1, length(receive_reports(Coordinator))),
    stop(Sup).

a_worker_closes_a_round_that_ran_out_of_steps_whatever_is_waiting_test() ->
    %% Every item takes two steps through the chain; the pushes
    %% waiting make 3000 steps, three rounds of a thousand.
    Sup = start(rounds, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(rounds, output),
    [Worker] = pg:get_local_members(rounds, workers),
    [Coordinator] = pg:get_local_members(rounds, coordinator),
    ok = sys:suspend(Worker),
    Items = lists:seq(1, 1500),
    [ok = ari_concurrent_runtime:push(rounds, input, 0, Batch) || Batch <- batches(Items, 100)],
    1 = erlang:trace(Coordinator, true, ['receive']),
    ok = sys:resume(Worker),
    T = ari_vtime:new(0),
    ?assertEqual([{Item, T} || Item <- Items], receive_n(1500, rounds, output)),
    ?assertEqual(3, length(receive_reports(Coordinator))),
    stop(Sup).

%%%===================================================================
%%% The limit
%%%===================================================================

a_push_waits_while_the_messages_on_their_way_are_at_the_limit_test() ->
    Sup = start(limited, chain(), #{workers => 1, max_in_flight => 2}),
    ok = ari_concurrent_runtime:subscribe(limited, output),
    [Worker] = pg:get_local_members(limited, workers),
    ok = sys:suspend(Worker),
    ok = ari_concurrent_runtime:push(limited, input, 0, [a, b]),
    Pusher = push_from_another_process(limited, input, 0, [c]),
    wait_until_blocked(Pusher),
    ?assertEqual(nothing, receive_pushed()),
    ok = sys:resume(Worker),
    ?assertEqual(ok, receive_pushed()),
    T = ari_vtime:new(0),
    ?assertEqual([{a, T}, {b, T}, {c, T}], receive_n(3, limited, output)),
    stop(Sup).

the_pushes_waiting_are_taken_in_the_order_made_test() ->
    Sup = start(lined_up, chain(), #{workers => 1, max_in_flight => 1}),
    ok = ari_concurrent_runtime:subscribe(lined_up, output),
    [Worker] = pg:get_local_members(lined_up, workers),
    ok = sys:suspend(Worker),
    ok = ari_concurrent_runtime:push(lined_up, input, 0, [a]),
    lists:foreach(
        fun(Item) -> wait_until_blocked(push_from_another_process(lined_up, input, 0, [Item])) end,
        [b, c, d]
    ),
    ok = sys:resume(Worker),
    ?assertEqual([ok, ok, ok], [receive_pushed() || _ <- [b, c, d]]),
    T = ari_vtime:new(0),
    ?assertEqual([{a, T}, {b, T}, {c, T}, {d, T}], receive_n(4, lined_up, output)),
    stop(Sup).

closing_never_waits_test() ->
    Sup = start(closing, chain(), #{workers => 1, max_in_flight => 1}),
    [Worker] = pg:get_local_members(closing, workers),
    ok = sys:suspend(Worker),
    ok = ari_concurrent_runtime:push(closing, input, 0, [a]),
    wait_until_blocked(push_from_another_process(closing, input, 1, [b])),
    ?assertEqual(ok, ari_concurrent_runtime:close(closing, input, 0)),
    ok = sys:resume(Worker),
    ?assertEqual(ok, receive_pushed()),
    stop(Sup).

a_push_waiting_into_an_epoch_closed_meanwhile_is_refused_test() ->
    Sup = start(late, chain(), #{workers => 1, max_in_flight => 1}),
    [Worker] = pg:get_local_members(late, workers),
    ok = sys:suspend(Worker),
    ok = ari_concurrent_runtime:push(late, input, 0, [a]),
    wait_until_blocked(push_from_another_process(late, input, 0, [b])),
    ok = ari_concurrent_runtime:close(late, input, 0),
    ok = sys:resume(Worker),
    ?assertEqual({error, {closed, {input, 0}}}, receive_pushed()),
    stop(Sup).

%%%===================================================================
%%% The fuse
%%%===================================================================

a_worker_outgrowing_the_heap_allowed_stops_the_branch_test() ->
    process_flag(trap_exit, true),
    Heap = #{size => 200000, kill => true, error_logger => false},
    Sup = start(fused, hoarding(), #{workers => 1, max_heap_size => Heap}),
    [Worker] = pg:get_local_members(fused, workers),
    Ref = monitor(process, Worker),
    Pusher = spawn(fun() -> hoard(fused, [{N, N, N, N} || N <- lists:seq(1, 1000)]) end),
    receive
        {'DOWN', Ref, process, Worker, Reason} -> ?assertEqual(killed, Reason)
    after 5000 ->
        error(worker_still_running)
    end,
    receive
        {'EXIT', Sup, shutdown} -> ok
    after 5000 ->
        error(branch_still_running)
    end,
    exit(Pusher, kill),
    ?assertEqual([], pg:get_local_members(fused, workers)).

%%%===================================================================
%%% The keys
%%%===================================================================

the_items_of_a_partitioned_input_go_to_the_worker_of_their_key_test() ->
    Sup = start(keyed_input, tracing_keyed_input(), 3),
    ok = ari_concurrent_runtime:subscribe(keyed_input, output),
    Items = lists:seq(1, 20),
    ok = ari_concurrent_runtime:push(keyed_input, input, 0, Items),
    Traced = [{Item, ari_crt_worker:index(Pid)} || {{Item, Pid}, _Time} <- receive_n(20, keyed_input, output)],
    ?assertEqual([{Item, worker_of(Item, 3)} || Item <- Items], lists:keysort(1, Traced)),
    stop(Sup).

the_items_of_a_partitioned_edge_are_handed_to_the_worker_of_their_key_test() ->
    Sup = start(keyed_edge, tracing_keyed_edge(), 3),
    ok = ari_concurrent_runtime:subscribe(keyed_edge, output),
    Items = lists:seq(1, 20),
    ok = ari_concurrent_runtime:push(keyed_edge, input, 0, Items),
    Traced = [{Item, ari_crt_worker:index(Pid)} || {{{Item, _}, Pid}, _Time} <- receive_n(20, keyed_edge, output)],
    ?assertEqual([{Item, worker_of(Item, 3)} || Item <- Items], lists:keysort(1, Traced)),
    stop(Sup).

the_items_handed_over_by_a_worker_keep_their_order_test() ->
    Sup = start(handed, tracing_keyed_edge(), 3),
    ok = ari_concurrent_runtime:subscribe(handed, output),
    Items = lists:seq(1, 30),
    ok = ari_concurrent_runtime:push(handed, input, 0, Items),
    %% Every item, with the worker it came up on and the worker it
    %% was handed to.
    Traced = [{Sender, Receiver, Item} || {{{Item, Sender}, Receiver}, _Time} <- receive_n(30, handed, output)],
    Pairs = lists:usort([{Sender, Receiver} || {Sender, Receiver, _Item} <- Traced]),
    ?assert(length(Pairs) > 1),
    lists:foreach(
        fun({S, R}) ->
            Handed = [Item || {Sender, Receiver, Item} <- Traced, Sender =:= S, Receiver =:= R],
            ?assertEqual(lists:sort(Handed), Handed)
        end,
        Pairs
    ),
    stop(Sup).

the_items_handed_over_are_counted_before_they_are_delivered_test() ->
    Sup = start(handed_counted, counting_keyed_edge(), 3),
    ok = ari_concurrent_runtime:subscribe(handed_counted, output),
    Items = [1, 1, 1, 1, 2, 2, 3],
    ok = ari_concurrent_runtime:push(handed_counted, input, 0, Items),
    ok = ari_concurrent_runtime:close(handed_counted, input, 0),
    T = ari_vtime:new(0),
    Counts = maps:groups_from_list(fun(Item) -> worker_of(Item, 3) end, Items),
    Expected = lists:sort([{length(Of), T} || _Worker := Of <- Counts]),
    ?assertEqual(Expected, lists:sort(receive_n(map_size(Counts), handed_counted, output))),
    stop(Sup).

%%%===================================================================
%%% Notifications
%%%===================================================================

a_notification_waits_for_the_epoch_to_close_test() ->
    Sup = start(waiting, counting(), 1),
    ok = ari_concurrent_runtime:subscribe(waiting, output),
    ok = ari_concurrent_runtime:push(waiting, input, 0, [a, b, c]),
    settle(waiting),
    ?assertEqual(nothing, receive_any(waiting, output)),
    ok = ari_concurrent_runtime:close(waiting, input, 0),
    ?assertEqual({3, ari_vtime:new(0)}, receive_one(waiting, output)),
    stop(Sup).

every_worker_counts_the_items_it_was_given_test() ->
    Sup = start(counted, counting(), 2),
    ok = ari_concurrent_runtime:subscribe(counted, output),
    ok = ari_concurrent_runtime:push(counted, input, 0, [a, b, c, d, e]),
    ok = ari_concurrent_runtime:close(counted, input, 0),
    T = ari_vtime:new(0),
    ?assertEqual([{2, T}, {3, T}], lists:sort(receive_n(2, counted, output))),
    stop(Sup).

the_epochs_are_notified_in_order_test() ->
    Sup = start(epochs, counting(), 1),
    ok = ari_concurrent_runtime:subscribe(epochs, output),
    ok = ari_concurrent_runtime:push(epochs, input, 1, [a, b]),
    ok = ari_concurrent_runtime:push(epochs, input, 0, [c]),
    ok = ari_concurrent_runtime:close(epochs, input, 1),
    ?assertEqual([{1, ari_vtime:new(0)}, {2, ari_vtime:new(1)}], receive_n(2, epochs, output)),
    stop(Sup).

an_epoch_left_open_keeps_the_later_ones_from_completing_test() ->
    Sup = start(held, counting(), 1),
    ok = ari_concurrent_runtime:subscribe(held, output),
    ok = ari_concurrent_runtime:push(held, input, 0, [a]),
    ok = ari_concurrent_runtime:push(held, input, 1, [b]),
    ok = ari_concurrent_runtime:close(held, input, 0),
    ?assertEqual({1, ari_vtime:new(0)}, receive_one(held, output)),
    settle(held),
    ?assertEqual(nothing, receive_any(held, output)),
    ok = ari_concurrent_runtime:close(held, input, 1),
    ?assertEqual({1, ari_vtime:new(1)}, receive_one(held, output)),
    stop(Sup).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% The supervisor the branch is embedded into by
%% the_branch_is_embedded_by_its_child_spec_test.
init(Graph) ->
    Flags = #{strategy => one_for_one, intensity => 0, period => 1},
    {ok, {Flags, [ari_concurrent_runtime:child_spec(embedded, Graph, #{workers => 1})]}}.

start(Name, Graph, Workers) when is_integer(Workers) ->
    start(Name, Graph, #{workers => Workers});
start(Name, Graph, Opts) ->
    {ok, Sup} = ari_concurrent_sup:start_link(Name, Graph, Opts),
    Sup.

%% Shuts the branch down the way a supervisor above would.
stop(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, shutdown} -> ok
    end.

%% Pushes from a process of its own, which reports the reply as
%% `{pushed, Reply}'.
push_from_another_process(Name, Input, Epoch, Messages) ->
    Test = self(),
    spawn_link(fun() -> Test ! {pushed, ari_concurrent_runtime:push(Name, Input, Epoch, Messages)} end).

%% The reply of a push made from another process, or `nothing' if
%% none came within a while.
receive_pushed() ->
    receive
        {pushed, Reply} -> Reply
    after 100 ->
        nothing
    end.

%% Waits until the process `Pid' is stuck in a receive: a pusher
%% has no other place to wait but inside its call, so its message
%% has reached the coordinator by then.
wait_until_blocked(Pid) ->
    case process_info(Pid, status) of
        {status, waiting} -> ok;
        {status, _} -> wait_until_blocked(Pid)
    end.

%% Everything received under the tag `Tag' so far.
receive_all(Tag) ->
    receive
        {Tag, Value} -> [Value | receive_all(Tag)]
    after 0 ->
        []
    end.

%% The reports of the workers the coordinator `Coordinator' received
%% so far, as traced.
%% The list cut into batches of `Size'.
batches([], _Size) ->
    [];
batches(Items, Size) ->
    {Batch, Rest} = lists:split(min(Size, length(Items)), Items),
    [Batch | batches(Rest, Size)].

receive_reports(Coordinator) ->
    receive
        {trace, Coordinator, 'receive', {'$gen_cast', {delta, _Worker, _Sum}} = Report} ->
            [Report | receive_reports(Coordinator)]
    after 100 ->
        []
    end.

%% The next item of the output `Output' of the runtime `Name', with
%% its time.
receive_one(Name, Output) ->
    receive
        {ariadne, Name, Output, Message, Time} -> {Message, Time}
    after 1000 ->
        error({nothing_received, {Name, Output}})
    end.

%% The next `N' items of the output `Output' of the runtime `Name'.
receive_n(N, Name, Output) ->
    [receive_one(Name, Output) || _ <- lists:seq(1, N)].

%% An item of the output `Output' of the runtime `Name' received
%% already, or `nothing'.
receive_any(Name, Output) ->
    receive
        {ariadne, Name, Output, Message, Time} -> {Message, Time}
    after 0 ->
        nothing
    end.

%% Waits until the runtime `Name' has taken care of everything it was
%% told so far: whatever a worker was told before this call is done
%% by the time its reply comes, then the same for the coordinator,
%% then for the workers again, for what the coordinator told them.
settle(Name) ->
    Workers = pg:get_local_members(Name, workers),
    [Coordinator] = pg:get_local_members(Name, coordinator),
    lists:foreach(fun sys:get_state/1, Workers ++ [Coordinator] ++ Workers).

%% Two passing vertices one after the other.
chain() ->
    ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_pass, []),
        ari_graph:out(output, {second, out})
    ]).

%% A vertex counting the items of every epoch.
counting() ->
    ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]).

%% A vertex pairing every item with the process it ran in.
tracing() ->
    ari_graph:graph([
        ari_graph:in(input, {tracer, in}),
        ari_graph:node(tracer, ari_test_tracer, []),
        ari_graph:out(output, {tracer, out})
    ]).

%% The worker, of `Count', the runtime hands an item keyed by itself
%% to, see ari_plan:partition/4.
worker_of(Item, Count) ->
    erlang:phash2(Item, Count) + 1.

%% Items enter at the worker of their key.
tracing_keyed_input() ->
    ari_graph:graph([
        ari_graph:in(input, {tracer, in}, #{key => fun(N) -> N end}),
        ari_graph:node(tracer, ari_test_tracer, []),
        ari_graph:out(output, {tracer, out})
    ]).

%% Items are spread in turn and marked with the worker they came up
%% on, then handed to the worker of their key along the link and
%% marked again: `{{Item, Sender}, Receiver}'.
tracing_keyed_edge() ->
    ari_graph:graph([
        ari_graph:in(input, {sender, in}),
        ari_graph:node(sender, ari_test_tracer, []),
        ari_graph:edge(link, {sender, out}, {receiver, in}, #{key => fun({N, _Pid}) -> N end}),
        ari_graph:node(receiver, ari_test_tracer, []),
        ari_graph:out(output, {receiver, out})
    ]).

%% Items are spread in turn, then handed to the worker of their key
%% to be counted there.
counting_keyed_edge() ->
    ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {count, in}, #{key => fun(N) -> N end}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]).

%% A vertex keeping every item.
hoarding() ->
    ari_graph:graph([
        ari_graph:in(input, {hoarder, in}),
        ari_graph:node(hoarder, ari_test_hoarder, []),
        ari_graph:out(output, {hoarder, out})
    ]).

%% Pushes `Items' into the runtime `Name' over and over, until the
%% runtime is gone.
hoard(Name, Items) ->
    ok = ari_concurrent_runtime:push(Name, input, 0, Items),
    hoard(Name, Items).

%% A vertex reporting its termination to `Pid'.
reporting(Pid) ->
    ari_graph:graph([
        ari_graph:in(input, {reporter, in}),
        ari_graph:node(reporter, ari_test_reporter, {reporter, Pid}),
        ari_graph:out(output, {reporter, out})
    ]).
