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
    ?assertMatch({error, {{unknown_vertex, {input, nowhere}}, _}}, ari_concurrent_sup:start_link(broken, Broken, 1)).

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
    {ok, {Flags, [ari_concurrent_runtime:child_spec(embedded, Graph, 1)]}}.

start(Name, Graph, Workers) ->
    {ok, Sup} = ari_concurrent_sup:start_link(Name, Graph, Workers),
    Sup.

%% Shuts the branch down the way a supervisor above would.
stop(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, shutdown} -> ok
    end.

%% Everything received under the tag `Tag' so far.
receive_all(Tag) ->
    receive
        {Tag, Value} -> [Value | receive_all(Tag)]
    after 0 ->
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

%% A vertex reporting its termination to `Pid'.
reporting(Pid) ->
    ari_graph:graph([
        ari_graph:in(input, {reporter, in}),
        ari_graph:node(reporter, ari_test_reporter, {reporter, Pid}),
        ari_graph:out(output, {reporter, out})
    ]).
