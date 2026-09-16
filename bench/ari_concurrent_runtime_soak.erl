%%%-------------------------------------------------------------------
%%% @doc
%%% A reproducible soak of the concurrent runtime against the single
%%% runtime. It feeds a random trace to a concurrent branch, replays
%%% the trace in the single runtime, and compares their output. A short
%%% and a ten times longer run expose growth of the branch heaps.
%%% `pushes' is the long run's number of pushes; alternatively,
%%% `duration' is its concurrent feeding time in milliseconds. The
%%% short run is one tenth of either.
%%%
%%% A heap passes when the long peak is at most twice the short peak,
%%% with 256 KB allowed for a small heap allocation step. The retained
%%% process memory after a full collection has the same rule with 64 KB.
%%%
%%% ```
%%% ari_concurrent_runtime_soak:run(#{
%%%     seed => {17, 23, 42}, shape => counting, workers => 4,
%%%     pushes => 100000, batch => 100, window => 16,
%%%     max_in_flight => 1000
%%% }).
%%% '''
%%% @end
%%%-------------------------------------------------------------------

-module(ari_concurrent_runtime_soak).

-include("ari_graph.hrl").

-export([run/0, run/1]).

-define(NAME, ari_soak).
-spec run() -> ok | {error, soak_failed}.
run() ->
    run(#{}).

-spec run(map()) -> ok | {error, soak_failed}.
run(Given) ->
    Opts = options(Given),
    io:format("ariadne soak ~p~n", [Opts]),
    {ShortLoad, LongLoad} = loads(Opts),
    Short = measure(short, ShortLoad, Opts),
    Long = measure(long, LongLoad, Opts),
    Failures = failures(Short, Long),
    Verdict = case Failures of [] -> pass; _ -> fail end,
    print_result(Short, Long, Verdict, Failures),
    case Verdict of
        pass -> ok;
        fail -> {error, soak_failed}
    end.

options(Given) ->
    Defaults = #{
        seed => {17, 23, 42}, workers => 4, shape => pipeline,
        pushes => 10000, batch => 16, window => 8, depth => 4,
        loop_limit => 10, max_in_flight => 1000, timeout => 60000
    },
    Opts0 = maps:merge(Defaults, Given),
    Opts = case Given of #{duration := _} -> maps:remove(pushes, Opts0); _ -> Opts0 end,
    validate(Opts),
    Opts.

validate(#{seed := Seed, workers := Workers, shape := Shape, batch := Batch,
           window := Window, depth := Depth, loop_limit := Limit,
           max_in_flight := InFlight, timeout := Timeout} = Opts) ->
    true = is_tuple(Seed) orelse is_integer(Seed),
    true = is_integer(Workers) andalso Workers > 0,
    true = lists:member(Shape, [pipeline, exchange, counting, loop]),
    true = is_integer(Batch) andalso Batch > 0,
    true = is_integer(Window) andalso Window > 0,
    true = is_integer(Depth) andalso Depth > 0,
    true = is_integer(Limit) andalso Limit >= 0,
    true = InFlight =:= infinity orelse is_integer(InFlight) andalso InFlight > 0,
    true = is_integer(Timeout) andalso Timeout > 0,
    case Opts of
        #{duration := Duration} -> true = is_integer(Duration) andalso Duration >= 10;
        #{pushes := Pushes} -> true = is_integer(Pushes) andalso Pushes >= 10
    end.

loads(#{duration := Duration}) ->
    {{duration, max(1, Duration div 10)}, {duration, Duration}};
loads(#{pushes := Pushes}) ->
    {{pushes, max(1, Pushes div 10)}, {pushes, Pushes}}.

measure(Label, Load, Opts) ->
    Shape = maps:get(shape, Opts),
    {Concurrent, Actions} = concurrent(Load, Opts),
    Expected = single(Actions, Shape, graph(Opts)),
    Actual = maps:get(output, Concurrent),
    Comparison = compare(Shape, Expected, Actual),
    Stats = maps:get(stats, Concurrent),
    io:format("~p pushes=~b closes=~b elements=~b~n", [
        Label, maps:get(pushes, Stats), maps:get(closes, Stats), maps:get(elements, Stats)
    ]),
    Concurrent#{label => Label, comparison => Comparison}.

concurrent(Load, Opts) ->
    Shape = maps:get(shape, Opts),
    RuntimeOpts = #{
        workers => maps:get(workers, Opts),
        max_in_flight => maps:get(max_in_flight, Opts)
    },
    {ok, Sup} = ari_concurrent_sup:start_link(?NAME, graph(Opts), RuntimeOpts),
    unlink(Sup),
    Workers = pg:get_local_members(?NAME, workers),
    [Coordinator] = pg:get_local_members(?NAME, coordinator),
    Collector = collector(self(), Shape),
    Watcher = ari_concurrent_runtime_bench:watcher([Coordinator | Workers]),
    try
        rand:seed(exsss, maps:get(seed, Opts)),
        Started = erlang:monotonic_time(millisecond),
        {Actions, Stats} = feed(Load, Opts),
        Collector ! {target, maps:get(elements, Stats)},
        {Output, TimedOut} = await(Collector, maps:get(timeout, Opts)),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        Peaks = ari_concurrent_runtime_bench:unwatch(Watcher),
        Empty = empty(Coordinator),
        Final = final_memory(Coordinator, Workers),
        {#{
            output => Output, stats => Stats, elapsed => Elapsed,
            timed_out => TimedOut, empty => Empty,
            worker_peak => lists:max([maps:get({heap, W}, Peaks) || W <- Workers]),
            coordinator_peak => maps:get({heap, Coordinator}, Peaks),
            coordinator_mailbox => maps:get({mailbox, Coordinator}, Peaks),
            worker_final => lists:max([maps:get(W, Final) || W <- Workers]),
            coordinator_final => maps:get(Coordinator, Final)
        }, Actions}
    after
        is_process_alive(Collector) andalso exit(Collector, kill),
        is_process_alive(Watcher) andalso exit(Watcher, kill),
        stop(Sup)
    end.

feed(Load, Opts) ->
    State = #{earliest => 0, pushes => 0, closes => 0, elements => 0, actions => []},
    State2 = generate(Load, Opts, State),
    Last = maps:get(earliest, State2) + maps:get(window, Opts) - 1,
    ok = ari_concurrent_runtime:close(?NAME, input, Last),
    Actions = lists:reverse([{close, Last} | maps:get(actions, State2)]),
    {Actions, maps:with([pushes, closes, elements], State2#{closes => maps:get(closes, State2) + 1})}.

generate({pushes, N} = Load, Opts, #{pushes := N} = State) ->
    done(Load, Opts, State);
generate({duration, Deadline}, Opts, State) when is_integer(Deadline) ->
    generate({until, erlang:monotonic_time(millisecond) + Deadline}, Opts, State);
generate({until, Deadline} = Load, Opts, State) ->
    case erlang:monotonic_time(millisecond) >= Deadline andalso maps:get(pushes, State) > 0 of
        true -> done(Load, Opts, State);
        false -> generate(Load, Opts, step(Opts, State))
    end;
generate(Load, Opts, State) ->
    generate(Load, Opts, step(Opts, State)).

done(_Load, _Opts, State) -> State.

step(Opts, #{earliest := Earliest, closes := Closes, actions := Actions} = State) ->
    State2 = case rand:uniform(5) of
        1 ->
            ok = ari_concurrent_runtime:close(?NAME, input, Earliest),
            State#{earliest := Earliest + 1, closes := Closes + 1,
                   actions := [{close, Earliest} | Actions]};
        _ ->
            push(Opts, State)
    end,
    case rand:uniform(200) of
        1 -> timer:sleep(1);
        N when N =< 5 -> erlang:yield();
        _ -> ok
    end,
    State2.

push(Opts, #{earliest := Earliest, pushes := Pushes, elements := Elements,
             actions := Actions} = State) ->
    Epoch = Earliest + rand:uniform(maps:get(window, Opts)) - 1,
    Size = rand:uniform(maps:get(batch, Opts)),
    Shape = maps:get(shape, Opts),
    Limit = maps:get(loop_limit, Opts),
    Messages = [message(Shape, Elements + I, Limit) || I <- lists:seq(1, Size)],
    ok = ari_concurrent_runtime:push(?NAME, input, Epoch, Messages),
    State#{pushes := Pushes + 1, elements := Elements + Size,
           actions := [{push, Epoch, Messages} | Actions]}.

message(loop, N, Limit) -> N rem (Limit + 1);
message(_Shape, N, _Limit) -> N.

single(Actions, Shape, Graph) ->
    R0 = ari_single_runtime:new(Graph),
    R1 = lists:foldl(fun single_action/2, R0, Actions),
    {Output, R2} = ari_single_runtime:pull(output, ari_single_runtime:run(R1)),
    ok = ari_single_runtime:stop(R2),
    aggregate(Shape, Output).

single_action({push, Epoch, Messages}, Runtime) ->
    ari_single_runtime:push(input, Epoch, Messages, Runtime);
single_action({close, Epoch}, Runtime) ->
    ari_single_runtime:close(input, Epoch, Runtime).

collector(Parent, Shape) ->
    spawn_link(fun() ->
        _ = process_flag(message_queue_data, off_heap),
        {_, _} = ari_concurrent_runtime:subscribe(?NAME, output),
        Parent ! {subscribed, self()},
        collect(Parent, Shape, #{}, 0, undefined)
    end),
    receive {subscribed, Collector} -> Collector end.

collect(Parent, Shape, Output, Count, Target) ->
    receive
        {ariadne, ?NAME, output, Message, Time} ->
            {Output2, Count2} = add(Shape, Message, Time, Output, Count),
            maybe_finish(Parent, Shape, Output2, Count2, Target);
        {target, N} ->
            maybe_finish(Parent, Shape, Output, Count, N);
        force ->
            finish(Parent, Shape, Output, Count, true)
    end.

maybe_finish(Parent, Shape, Output, Count, Target) when is_integer(Target), Count >= Target ->
    finish(Parent, Shape, Output, Count, false);
maybe_finish(Parent, Shape, Output, Count, Target) ->
    collect(Parent, Shape, Output, Count, Target).

finish(Parent, Shape, Output, Count, TimedOut) ->
    settle(),
    {Output2, _Count2} = drain(Shape, Output, Count),
    Parent ! {collected, self(), Output2, TimedOut}.

drain(Shape, Output, Count) ->
    receive
        {ariadne, ?NAME, output, Message, Time} ->
            {Output2, Count2} = add(Shape, Message, Time, Output, Count),
            drain(Shape, Output2, Count2)
    after 0 ->
        {Output, Count}
    end.

add(counting, Message, Time, Output, Count) ->
    {maps:update_with(Time, fun(N) -> N + Message end, Message, Output), Count + Message};
add(_Shape, Message, Time, Output, Count) ->
    Key = {Message, Time},
    {maps:update_with(Key, fun(N) -> N + 1 end, 1, Output), Count + 1}.

aggregate(Shape, Output) ->
    element(1, lists:foldl(
        fun({Message, Time}, {Acc, Count}) -> add(Shape, Message, Time, Acc, Count) end,
        {#{}, 0}, Output
    )).

await(Collector, Timeout) ->
    receive
        {collected, Collector, Output, TimedOut} -> {Output, TimedOut}
    after Timeout ->
        Collector ! force,
        receive
            {collected, Collector, Output, _} -> {Output, true}
        after 5000 ->
            error(collector_stuck)
        end
    end.

settle() ->
    Workers = pg:get_local_members(?NAME, workers),
    [Coordinator] = pg:get_local_members(?NAME, coordinator),
    lists:foreach(fun sys:get_state/1, Workers ++ [Coordinator] ++ Workers).

empty(Coordinator) ->
    case sys:get_state(Coordinator) of
        {coordinator, _Name, _Plan,
         {progress, Pending, Times, Frontier, InFlight, _Inputs},
         _Count, _Workers, _Next, _Limit, Waiting, Asked} ->
            map_size(Pending) =:= 0 andalso map_size(Times) =:= 0 andalso
                map_size(Frontier) =:= 0 andalso InFlight =:= 0 andalso
                queue:is_empty(Waiting) andalso map_size(Asked) =:= 0;
        _ ->
            false
    end.

final_memory(Coordinator, Workers) ->
    Pids = [Coordinator | Workers],
    [true = erlang:garbage_collect(Pid) || Pid <- Pids],
    maps:from_list([{Pid, element(2, process_info(Pid, memory))} || Pid <- Pids]).

compare(_Shape, Expected, Expected) -> ok;
compare(Shape, Expected, Actual) ->
    Keys = lists:usort(maps:keys(Expected) ++ maps:keys(Actual)),
    Key = hd([K || K <- Keys, maps:get(K, Expected, 0) =/= maps:get(K, Actual, 0)]),
    {mismatch, mismatch(Shape, Key), maps:get(Key, Expected, 0), maps:get(Key, Actual, 0)}.

mismatch(counting, Time) -> #{time => Time};
mismatch(_Shape, {Message, Time}) -> #{time => Time, message => Message}.

failures(Short, Long) ->
    Checks = [
        {short_output, maps:get(comparison, Short) =:= ok},
        {long_output, maps:get(comparison, Long) =:= ok},
        {short_empty, maps:get(empty, Short)},
        {long_empty, maps:get(empty, Long)},
        {short_timeout, not maps:get(timed_out, Short)},
        {long_timeout, not maps:get(timed_out, Long)},
        {worker_peak, bounded(worker_peak, Short, Long, 256 * 1024)},
        {coordinator_peak, bounded(coordinator_peak, Short, Long, 256 * 1024)},
        {worker_final, bounded(worker_final, Short, Long, 64 * 1024)},
        {coordinator_final, bounded(coordinator_final, Short, Long, 64 * 1024)}
    ],
    [Name || {Name, false} <- Checks].

bounded(Key, Short, Long, Slack) ->
    Small = maps:get(Key, Short),
    maps:get(Key, Long) =< max(2 * Small, Small + Slack).

print_result(Short, Long, Verdict, Failures) ->
    io:format("          elapsed  worker peak  coord peak  coord mailbox  worker final  coord final~n"),
    lists:foreach(fun(Result) ->
        io:format("~-5s ~9b ~12b ~11b ~14b ~13b ~12b~n", [
            maps:get(label, Result), maps:get(elapsed, Result),
            maps:get(worker_peak, Result) div 1024,
            maps:get(coordinator_peak, Result) div 1024,
            maps:get(coordinator_mailbox, Result), maps:get(worker_final, Result) div 1024,
            maps:get(coordinator_final, Result) div 1024
        ]),
        case maps:get(comparison, Result) of
            ok -> ok;
            Difference -> io:format("~p first difference: ~p~n", [maps:get(label, Result), Difference])
        end
    end, [Short, Long]),
    io:format("verdict: ~s", [string:uppercase(atom_to_list(Verdict))]),
    case Failures of [] -> io:format("~n"); _ -> io:format(" ~p~n", [Failures]) end.

graph(#{shape := pipeline, depth := Depth}) -> chain(Depth, fun(_I) -> #{} end);
graph(#{shape := exchange, depth := Depth}) ->
    chain(Depth, fun(I) -> #{key => fun(Message) -> {I, Message} end} end);
graph(#{shape := counting}) ->
    ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]);
graph(#{shape := loop, loop_limit := Limit}) ->
    ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, Limit),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:out(output, {inc, done})
    ]).

chain(Depth, EdgeOpts) ->
    Vertices = [list_to_atom("pass" ++ integer_to_list(I)) || I <- lists:seq(1, Depth)],
    Pairs = lists:zip(lists:droplast(Vertices), tl(Vertices)),
    ari_graph:graph(
        [ari_graph:in(input, {hd(Vertices), in})] ++
        [ari_graph:node(V, ari_test_pass, []) || V <- Vertices] ++
        [ari_graph:edge(list_to_atom("to_" ++ atom_to_list(B)), {A, out}, {B, in}, EdgeOpts(I))
         || {I, {A, B}} <- lists:enumerate(2, Pairs)] ++
        [ari_graph:out(output, {lists:last(Vertices), out})]
    ).

stop(Sup) ->
    case is_process_alive(Sup) of
        false -> ok;
        true ->
            Ref = monitor(process, Sup),
            exit(Sup, shutdown),
            receive {'DOWN', Ref, process, Sup, _Reason} -> ok end
    end.
