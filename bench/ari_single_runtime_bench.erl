%%%-------------------------------------------------------------------
%%% @doc
%%% Characterization of {@link ari_single_runtime}: how the time and
%%% the space it takes grow with the load. Nothing is asserted; the
%%% numbers are printed for a person to read.
%%%
%%% Three shapes of load, each scaled by its parameters:
%%% <ul>
%%% <li>`pipeline' -- a chain of `K' passing vertices fed `M' messages
%%% of one epoch: the cost of delivering a message;</li>
%%% <li>`epochs' -- a counting vertex fed `E' epochs of `M' messages,
%%% every epoch closed: the cost of notifications;</li>
%%% <li>`loop' -- a vertex iterating every one of `M' messages `L'
%%% times through a feedback edge: the work inside of a loop;</li>
%%% <li>`loop' with a third parameter `E' -- the vertex fed `E'
%%% epochs of `M' messages, every one pushed before any is closed:
%%% the frontier of a loop with several epochs open.</li>
%%% </ul>
%%%
%%% ```
%%% rebar3 as bench shell
%%% > ari_single_runtime_bench:run().
%%% > ari_single_runtime_bench:profile({epochs, {100, 100}}).
%%% '''
%%% @end
%%%-------------------------------------------------------------------

-module(ari_single_runtime_bench).

-export([
    run/0,
    run/1,
    profile/1
]).

-type shape() :: pipeline | epochs | loop.
-type load() :: {shape(), Params :: {pos_integer(), pos_integer()} | {pos_integer(), pos_integer(), pos_integer()}}.

-define(REPEATS, 5).

%%--------------------------------------------------------------------
%% @doc
%% Measures the default grid of loads and prints a table.
%% @end
%%--------------------------------------------------------------------
-spec run() -> ok.
run() ->
    run([
        {pipeline, {K, M}} || K <- [1, 4, 16], M <- [1000, 10000, 100000]
    ] ++ [
        {epochs, {E, 100}} || E <- [10, 30, 100, 300, 1000]
    ] ++ [
        {loop, {L, 100}} || L <- [10, 100, 1000]
    ] ++ [
        {loop, {10, 100, E}} || E <- [10, 100, 1000]
    ]).

%%--------------------------------------------------------------------
%% @doc
%% Measures the loads given and prints a table: the number of steps,
%% the median time of `run/1' with its spread over the repetitions,
%% the time of one step, the size of the runtime after the input was
%% pushed and after it was run, and the peak heap of the process
%% running it.
%% @end
%%--------------------------------------------------------------------
-spec run([load()]) -> ok.
run(Loads) ->
    io:format(
        "~-10s ~-14s ~10s ~12s ~14s ~8s ~10s ~10s ~10s~n",
        ["shape", "params", "steps", "run ms", "min..max ms", "us/step",
         "pushed KB", "ran KB", "peak KB"]
    ),
    lists:foreach(fun measure/1, Loads).

%%--------------------------------------------------------------------
%% @doc
%% Profiles `run/1' of the load given with `eprof' and prints the
%% functions by the time spent in them.
%% @end
%%--------------------------------------------------------------------
-spec profile(load()) -> ok.
profile(Load) ->
    Loaded = loaded(Load),
    eprof:start(),
    {ok, _} = eprof:profile(fun() -> ari_single_runtime:run(Loaded) end),
    eprof:analyze(total, [{sort, time}]),
    eprof:stop(),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec measure(load()) -> ok.
measure({Shape, Params} = Load) ->
    Loaded = loaded(Load),
    Results = [timed(Loaded) || _ <- lists:seq(1, ?REPEATS)],
    Times = lists:sort([T || {T, _Peak, _Ran} <- Results]),
    Median = lists:nth((?REPEATS + 1) div 2, Times),
    Peak = lists:max([P || {_T, P, _Ran} <- Results]),
    [{_, _, Ran} | _] = Results,
    Steps = steps(Load),
    io:format(
        "~-10s ~-14s ~10b ~12.1f ~14s ~8.2f ~10b ~10b ~10b~n",
        [Shape, io_lib:format("~p", [Params]), Steps, Median / 1000,
         io_lib:format("~.1f..~.1f", [hd(Times) / 1000, lists:last(Times) / 1000]),
         Median / Steps, kb(Loaded), kb(Ran), Peak div 1024]
    ).

%% Runs the runtime in a process of its own and watches its garbage
%% collections: the time taken, the peak of the heap in bytes -- the
%% blocks allocated, the largest seen at a collection or at the end
%% -- and the result.
-spec timed(ari_single_runtime:t()) ->
    {Micros :: non_neg_integer(), Peak :: non_neg_integer(), ari_single_runtime:t()}.
timed(Loaded) ->
    Self = self(),
    Pid = spawn_link(fun() ->
        receive go -> ok end,
        {Micros, Ran} = timer:tc(ari_single_runtime, run, [Loaded]),
        {total_heap_size, Words} = process_info(self(), total_heap_size),
        Self ! {done, Micros, Words, Ran}
    end),
    1 = erlang:trace(Pid, true, [garbage_collection]),
    Pid ! go,
    receive {done, Micros, Last, Ran} -> ok end,
    Peak = collect(Pid, Last),
    {Micros, Peak * erlang:system_info(wordsize), Ran}.

%% Folds the garbage collection trace of `Pid' into the largest heap seen.
-spec collect(pid(), non_neg_integer()) -> non_neg_integer().
collect(Pid, Peak) ->
    receive
        {trace, Pid, _Event, Info} when is_list(Info) ->
            Heap = proplists:get_value(heap_block_size, Info, 0) +
                proplists:get_value(old_heap_block_size, Info, 0),
            collect(Pid, max(Peak, Heap))
    after 0 ->
        Peak
    end.

-spec kb(term()) -> non_neg_integer().
kb(Term) ->
    erts_debug:size(Term) * erlang:system_info(wordsize) div 1024.

%% The runtime of the load with its input pushed and closed.
-spec loaded(load()) -> ari_single_runtime:t().
loaded({pipeline, {K, M}}) ->
    Vertices = [list_to_atom("pass" ++ integer_to_list(I)) || I <- lists:seq(1, K)],
    Pairs = lists:zip(lists:droplast(Vertices), tl(Vertices)),
    R0 = ari_single_runtime:new(ari_graph:graph(
        [ari_graph:in(input, {hd(Vertices), in})] ++
        [ari_graph:node(V, ari_test_pass, []) || V <- Vertices] ++
        [ari_graph:edge(list_to_atom("to_" ++ atom_to_list(B)), {A, out}, {B, in}) || {A, B} <- Pairs] ++
        [ari_graph:out(output, {lists:last(Vertices), out})]
    )),
    ari_single_runtime:close(input, 0, ari_single_runtime:push(input, 0, lists:seq(1, M), R0));
loaded({epochs, {E, M}}) ->
    R0 = ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ])),
    Messages = lists:seq(1, M),
    R1 = lists:foldl(
        fun(Epoch, Acc) -> ari_single_runtime:push(input, Epoch, Messages, Acc) end,
        R0,
        lists:seq(0, E - 1)
    ),
    ari_single_runtime:close(input, E - 1, R1);
loaded({loop, {L, M}}) ->
    ari_single_runtime:close(input, 0, ari_single_runtime:push(input, 0, lists:duplicate(M, 0), looping(L)));
loaded({loop, {L, M, E}}) ->
    Messages = lists:duplicate(M, 0),
    R1 = lists:foldl(
        fun(Epoch, Acc) -> ari_single_runtime:push(input, Epoch, Messages, Acc) end,
        looping(L),
        lists:seq(0, E - 1)
    ),
    ari_single_runtime:close(input, E - 1, R1).

%% The runtime of a vertex iterating every message `L' times.
-spec looping(pos_integer()) -> ari_single_runtime:t().
looping(L) ->
    ari_single_runtime:new(ari_graph:graph([
        ari_graph:in(input, {inc, in}),
        ari_graph:loop(spin, [
            ari_graph:node(inc, ari_test_until, L),
            ari_graph:feedback(again, {inc, continue}, {inc, in})
        ]),
        ari_graph:out(output, {inc, done})
    ])).

%% The number of steps `run/1' takes for the load.
-spec steps(load()) -> pos_integer().
steps({pipeline, {K, M}}) -> K * M;
steps({epochs, {E, M}}) -> E * M + E;
steps({loop, {L, M}}) -> M * (L + 1);
steps({loop, {L, M, E}}) -> E * M * (L + 1).
