%%%-------------------------------------------------------------------
%%% @doc
%%% Characterization of {@link ari_concurrent_runtime}: what the
%%% coordination costs over {@link ari_single_runtime}, how the time
%%% falls with the workers, and what the runtime holds in memory
%%% under load. Nothing is asserted; the numbers are printed for a
%%% person to read.
%%%
%%% The shapes of load of {@link ari_single_runtime_bench} are kept
%%% as they are, so a row of this table compares with a row of that
%%% one, and two are added for what only several processes have:
%%% <ul>
%%% <li>`pipeline' -- a chain of `K' passing vertices fed `M' messages
%%% of one epoch: the cost of delivering a message;</li>
%%% <li>`exchange' -- the same chain with every edge partitioned by
%%% the message, so that a message changes workers at every hop:
%%% the cost of handing a message to another worker;</li>
%%% <li>`epochs' -- a counting vertex fed `E' epochs of `M' messages,
%%% every epoch closed at the end: the cost of notifications;</li>
%%% <li>`stream' -- the counting vertex fed `E' epochs of `M'
%%% messages with `L' messages allowed on their way, every epoch
%%% closed as soon as it is pushed: the runtime as a service under
%%% a producer held back by the limit;</li>
%%% <li>`loop' -- a vertex iterating every one of `M' messages `L'
%%% times through a feedback edge: the work inside of a loop.</li>
%%% </ul>
%%%
%%% A load is run in a branch of its own, started before the clock
%%% and stopped after it; the clock runs from the first push to the
%%% last item the subscriber receives. The pushes are made from the
%%% process measuring, as a producer would.
%%%
%%% ```
%%% rebar3 as bench shell
%%% > ari_concurrent_runtime_bench:run().
%%% > ari_concurrent_runtime_bench:scaling().
%%% > ari_concurrent_runtime_bench:profile({exchange, {4, 100000}}, 4).
%%% '''
%%% @end
%%%-------------------------------------------------------------------

-module(ari_concurrent_runtime_bench).

-include("ari_graph.hrl").

-export([
    run/0,
    run/2,
    scaling/0,
    scaling/1,
    workers/0,
    profile/2
]).

-type shape() :: pipeline | exchange | epochs | stream | loop.
-type load() :: {shape(), Params :: tuple()}.

%% What one run of a load showed besides its time.
-type stats() :: #{
    %% How long the producer spent in the pushes and the closes.
    fed := non_neg_integer(),
    %% The share of the reductions of the branch made by the coordinator.
    share := float(),
    %% The longest mailbox of the coordinator seen.
    mailbox := non_neg_integer(),
    %% The largest heap of a worker and of the coordinator, in bytes.
    worker_peak := non_neg_integer(),
    coordinator_peak := non_neg_integer(),
    %% How many schedulers were busy on average.
    busy := float()
}.

-define(NAME, ari_bench).
-define(REPEATS, 5).
-define(SAMPLE_MS, 10).

%%--------------------------------------------------------------------
%% @doc
%% Measures the default grid of loads on one worker and prints a
%% table: the cost of the coordination, to compare with the table
%% of {@link ari_single_runtime_bench:run/0}.
%% @end
%%--------------------------------------------------------------------
-spec run() -> ok.
run() ->
    run(grid(), 1).

%%--------------------------------------------------------------------
%% @doc
%% Measures the loads given on `Workers' workers and prints a table:
%% the number of steps, the median time of a run with its spread
%% over the repetitions, the time of one step, the time the producer
%% spent in the pushes and the closes of the median run, the share
%% of the reductions of the branch made by the coordinator, the longest
%% mailbox of the coordinator seen, the peak heap of a worker and
%% of the coordinator, and the number of schedulers busy on average.
%% The share and the schedulers busy are those of the median run;
%% the mailbox and the peaks are the largest over the runs.
%% @end
%%--------------------------------------------------------------------
-spec run([load()], Workers :: pos_integer()) -> ok.
run(Loads, Workers) ->
    header(),
    lists:foreach(fun(Load) -> measure(Load, Workers) end, Loads).

%%--------------------------------------------------------------------
%% @doc
%% Measures a few loads of every shape over the row of workers of
%% {@link workers/0} and prints a table per load.
%% @end
%%--------------------------------------------------------------------
-spec scaling() -> ok.
scaling() ->
    lists:foreach(fun scaling/1, [
        {pipeline, {4, 100000}},
        {exchange, {4, 100000}},
        {epochs, {1000, 100}},
        {stream, {1000, 100, 1000}},
        {loop, {1000, 100}}
    ]).

%%--------------------------------------------------------------------
%% @doc
%% Measures the load given over the row of workers of {@link
%% workers/0} and prints a table.
%% @end
%%--------------------------------------------------------------------
-spec scaling(load()) -> ok.
scaling(Load) ->
    header(),
    lists:foreach(fun(Workers) -> measure(Load, Workers) end, workers()).

%%--------------------------------------------------------------------
%% @doc
%% The row of workers the scaling is measured over: the powers of
%% two up to the schedulers online, the schedulers online, and twice
%% as many for the price of oversubscription.
%% @end
%%--------------------------------------------------------------------
-spec workers() -> [pos_integer()].
workers() ->
    Online = erlang:system_info(schedulers_online),
    lists:usort([W || W <- [1, 2, 4, 8, 16, 32, 64], W < Online] ++ [Online, 2 * Online]).

%%--------------------------------------------------------------------
%% @doc
%% Profiles one run of the load given on `Workers' workers with
%% `eprof' and prints the functions by the time spent in them, over
%% the workers and the coordinator together.
%% @end
%%--------------------------------------------------------------------
-spec profile(load(), Workers :: pos_integer()) -> ok.
profile(Load, Workers) ->
    Sup = start(Load, Workers),
    Pids = [coordinator() | workers_of()],
    eprof:start(),
    %% The fun runs in a process of eprof's own, which the consumer
    %% has to report to.
    {ok, _} = eprof:profile(Pids, fun() ->
        Consumer = consumer(Load, Workers),
        feed(Load),
        await(Consumer)
    end),
    eprof:analyze(total, [{sort, time}]),
    eprof:stop(),
    stop(Sup).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec header() -> ok.
header() ->
    io:format(
        "~-9s ~-18s ~3s ~9s ~9s ~14s ~7s ~7s ~6s ~7s ~8s ~8s ~5s~n",
        ["shape", "params", "W", "steps", "run ms", "min..max ms", "us/step", "fed ms",
         "coord%", "mailbox", "wrk KB", "coord KB", "busy"]
    ).

-spec measure(load(), Workers :: pos_integer()) -> ok.
measure({Shape, Params} = Load, Workers) ->
    Results = lists:keysort(1, [timed(Load, Workers) || _ <- lists:seq(1, ?REPEATS)]),
    {Median, Stats} = lists:nth((?REPEATS + 1) div 2, Results),
    {Fastest, _} = hd(Results),
    {Slowest, _} = lists:last(Results),
    Steps = steps(Load, Workers),
    io:format(
        "~-9s ~-18s ~3b ~9b ~9.1f ~14s ~7.2f ~7.1f ~6.1f ~7b ~8b ~8b ~5.1f~n",
        [Shape, io_lib:format("~p", [Params]), Workers, Steps, Median / 1000,
         io_lib:format("~.1f..~.1f", [Fastest / 1000, Slowest / 1000]),
         Median / Steps, maps:get(fed, Stats) / 1000, 100 * maps:get(share, Stats),
         lists:max([maps:get(mailbox, S) || {_, S} <- Results]),
         lists:max([maps:get(worker_peak, S) || {_, S} <- Results]) div 1024,
         lists:max([maps:get(coordinator_peak, S) || {_, S} <- Results]) div 1024,
         maps:get(busy, Stats)]
    ).

%% Runs the load once in a branch of its own and watches the branch:
%% the time from the first push to the last item received, and the
%% stats of the run.
-spec timed(load(), Workers :: pos_integer()) -> {Micros :: non_neg_integer(), stats()}.
timed(Load, Workers) ->
    Sup = start(Load, Workers),
    Coordinator = coordinator(),
    WorkerPids = workers_of(),
    Consumer = consumer(Load, Workers),
    Watcher = watcher([Coordinator | WorkerPids]),
    Before = reductions([Coordinator | WorkerPids]),
    Sample0 = scheduler:sample(),
    Started = erlang:monotonic_time(microsecond),
    feed(Load),
    Fed = erlang:monotonic_time(microsecond),
    Finished = await(Consumer),
    Sample1 = scheduler:sample(),
    After = reductions([Coordinator | WorkerPids]),
    Peaks = unwatch(Watcher),
    stop(Sup),
    [CoordinatorReductions | WorkerReductions] = lists:zipwith(fun erlang:'-'/2, After, Before),
    {Finished - Started, #{
        fed => Fed - Started,
        share => CoordinatorReductions / lists:sum([CoordinatorReductions | WorkerReductions]),
        mailbox => maps:get({mailbox, Coordinator}, Peaks),
        worker_peak => lists:max([maps:get({heap, W}, Peaks) || W <- WorkerPids]),
        coordinator_peak => maps:get({heap, Coordinator}, Peaks),
        busy => busy(scheduler:utilization(Sample0, Sample1))
    }}.

%% The number of schedulers busy on average, out of the normal ones.
-spec busy([tuple()]) -> float().
busy(Utilization) ->
    lists:sum([F || {normal, _Id, F, _} <- Utilization]).

-spec reductions([pid()]) -> [non_neg_integer()].
reductions(Pids) ->
    [element(2, process_info(Pid, reductions)) || Pid <- Pids].

%%%-------------------------------------------------------------------
%%% The watcher: a process tracing the garbage collections of the
%%% processes of the branch, folding them into the largest heap of
%%% every one -- the blocks allocated, the largest seen at a
%%% collection or at the end -- and sampling their mailboxes every
%%% few milliseconds, keeping the longest.
%%%-------------------------------------------------------------------

-type peaks() :: #{{heap | mailbox, pid()} => non_neg_integer()}.

-spec watcher([pid()]) -> pid().
watcher(Pids) ->
    Watcher = spawn_link(fun() ->
        receive go -> ok end,
        Peaks = maps:from_list([{{heap, P}, 0} || P <- Pids] ++ [{{mailbox, P}, 0} || P <- Pids]),
        watch(Pids, Peaks)
    end),
    [1 = erlang:trace(Pid, true, [garbage_collection, {tracer, Watcher}]) || Pid <- Pids],
    Watcher ! go,
    Watcher.

-spec unwatch(pid()) -> peaks().
unwatch(Watcher) ->
    Watcher ! {stop, self()},
    receive {peaks, Peaks} -> Peaks end.

-spec watch([pid()], peaks()) -> {peaks, peaks()}.
watch(Pids, Peaks) ->
    receive
        {trace, Pid, _Event, Info} when is_list(Info) ->
            Heap = proplists:get_value(heap_block_size, Info, 0) +
                proplists:get_value(old_heap_block_size, Info, 0),
            watch(Pids, larger({heap, Pid}, Heap * erlang:system_info(wordsize), Peaks));
        {stop, From} ->
            [erlang:trace(Pid, false, [garbage_collection]) || Pid <- Pids],
            From ! {peaks, sample(Pids, sample_heaps(Pids, Peaks))}
    after ?SAMPLE_MS ->
        watch(Pids, sample(Pids, Peaks))
    end.

-spec sample([pid()], peaks()) -> peaks().
sample(Pids, Peaks) ->
    lists:foldl(
        fun(Pid, Acc) ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} -> larger({mailbox, Pid}, N, Acc);
                undefined -> Acc
            end
        end,
        Peaks,
        Pids
    ).

-spec sample_heaps([pid()], peaks()) -> peaks().
sample_heaps(Pids, Peaks) ->
    lists:foldl(
        fun(Pid, Acc) ->
            case process_info(Pid, total_heap_size) of
                {total_heap_size, Words} ->
                    larger({heap, Pid}, Words * erlang:system_info(wordsize), Acc);
                undefined ->
                    Acc
            end
        end,
        Peaks,
        Pids
    ).

-spec larger({heap | mailbox, pid()}, non_neg_integer(), peaks()) -> peaks().
larger(Key, Value, Peaks) ->
    maps:update_with(Key, fun(Old) -> max(Old, Value) end, Value, Peaks).

%%%-------------------------------------------------------------------
%%% The branch and the consumer
%%%-------------------------------------------------------------------

-spec start(load(), Workers :: pos_integer()) -> pid().
start(Load, Workers) ->
    {ok, Sup} = ari_concurrent_sup:start_link(?NAME, graph(Load), opts(Load, Workers)),
    Sup.

-spec stop(pid()) -> ok.
stop(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, process, Sup, shutdown} -> ok end.

-spec coordinator() -> pid().
coordinator() ->
    [Coordinator] = pg:get_local_members(?NAME, coordinator),
    Coordinator.

-spec workers_of() -> [pid()].
workers_of() ->
    pg:get_local_members(?NAME, workers).

%% A process subscribed to the output, counting the items of the
%% load down and reporting when it received the last one.
-spec consumer(load(), Workers :: pos_integer()) -> pid().
consumer(Load, Workers) ->
    Self = self(),
    Consumer = spawn_link(fun() ->
        ok = ari_concurrent_runtime:subscribe(?NAME, output),
        Self ! {subscribed, self()},
        consume(outputs(Load, Workers)),
        Self ! {consumed, self(), erlang:monotonic_time(microsecond)}
    end),
    receive {subscribed, Consumer} -> ok end,
    Consumer.

-spec consume(non_neg_integer()) -> ok.
consume(0) ->
    ok;
consume(N) ->
    receive {ariadne, ?NAME, output, _Message, _Time} -> consume(N - 1) end.

-spec await(pid()) -> Micros :: integer().
await(Consumer) ->
    receive {consumed, Consumer, Finished} -> Finished end.

%%%-------------------------------------------------------------------
%%% The loads
%%%-------------------------------------------------------------------

-spec grid() -> [load()].
grid() ->
    [
        {pipeline, {K, M}} || K <- [1, 4, 16], M <- [1000, 10000, 100000]
    ] ++ [
        {exchange, {K, M}} || K <- [1, 4, 16], M <- [1000, 10000, 100000]
    ] ++ [
        {epochs, {E, 100}} || E <- [10, 30, 100, 300, 1000]
    ] ++ [
        {stream, {E, 100, L}} || E <- [100, 1000], L <- [100, 1000]
    ] ++ [
        {loop, {L, 100}} || L <- [10, 100, 1000]
    ].

-spec opts(load(), Workers :: pos_integer()) -> ari_concurrent_runtime:opts().
opts({stream, {_E, _M, L}}, Workers) ->
    #{workers => Workers, max_in_flight => L};
opts(_Load, Workers) ->
    #{workers => Workers}.

-spec graph(load()) -> #graph{}.
graph({pipeline, {K, _M}}) ->
    chain(K, #{});
graph({exchange, {K, _M}}) ->
    chain(K, #{key => fun(N) -> N end});
graph({epochs, _}) ->
    counting();
graph({stream, _}) ->
    counting();
graph({loop, {L, _M}}) ->
    ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, L),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:out(output, {inc, done})
    ]).

%% A chain of `K' passing vertices, its edges with the options given.
-spec chain(pos_integer(), edge_opts()) -> #graph{}.
chain(K, Opts) ->
    Vertices = [list_to_atom("pass" ++ integer_to_list(I)) || I <- lists:seq(1, K)],
    Pairs = lists:zip(lists:droplast(Vertices), tl(Vertices)),
    ari_graph:graph(
        [ari_graph:in(input, {hd(Vertices), in})] ++
        [ari_graph:node(V, ari_test_pass, []) || V <- Vertices] ++
        [ari_graph:edge(list_to_atom("to_" ++ atom_to_list(B)), {A, out}, {B, in}, Opts) || {A, B} <- Pairs] ++
        [ari_graph:out(output, {lists:last(Vertices), out})]
    ).

-spec counting() -> #graph{}.
counting() ->
    ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]).

%% Pushes the input of the load and closes it.
-spec feed(load()) -> ok.
feed({Shape, {_K, M}}) when Shape =:= pipeline; Shape =:= exchange ->
    ok = ari_concurrent_runtime:push(?NAME, input, 0, lists:seq(1, M)),
    ok = ari_concurrent_runtime:close(?NAME, input, 0);
feed({epochs, {E, M}}) ->
    Messages = lists:seq(1, M),
    [ok = ari_concurrent_runtime:push(?NAME, input, Epoch, Messages) || Epoch <- lists:seq(0, E - 1)],
    ok = ari_concurrent_runtime:close(?NAME, input, E - 1);
feed({stream, {E, M, _L}}) ->
    Messages = lists:seq(1, M),
    lists:foreach(
        fun(Epoch) ->
            ok = ari_concurrent_runtime:push(?NAME, input, Epoch, Messages),
            ok = ari_concurrent_runtime:close(?NAME, input, Epoch)
        end,
        lists:seq(0, E - 1)
    );
feed({loop, {_L, M}}) ->
    ok = ari_concurrent_runtime:push(?NAME, input, 0, lists:duplicate(M, 0)),
    ok = ari_concurrent_runtime:close(?NAME, input, 0).

%% The number of items the output of the load delivers on `Workers'
%% workers. Every worker runs a copy of the counting vertex, and the
%% items of an epoch spread in turn reach as many workers as there
%% are items, at most.
-spec outputs(load(), Workers :: pos_integer()) -> non_neg_integer().
outputs({pipeline, {_K, M}}, _Workers) -> M;
outputs({exchange, {_K, M}}, _Workers) -> M;
outputs({epochs, {E, M}}, Workers) -> E * min(M, Workers);
outputs({stream, {E, M, _L}}, Workers) -> E * min(M, Workers);
outputs({loop, {_L, M}}, _Workers) -> M.

%% The number of events the workers deliver for the load: every
%% message once, every notification once per worker asking.
-spec steps(load(), Workers :: pos_integer()) -> pos_integer().
steps({pipeline, {K, M}}, _Workers) -> K * M;
steps({exchange, {K, M}}, _Workers) -> K * M;
steps({epochs, {E, M}}, Workers) -> E * M + E * min(M, Workers);
steps({stream, {E, M, _L}}, Workers) -> E * M + E * min(M, Workers);
steps({loop, {L, M}}, _Workers) -> M * (L + 1).
