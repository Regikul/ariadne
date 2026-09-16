-module(ari_soak_tests).

-include_lib("eunit/include/eunit.hrl").

short_soak_matches_the_single_runtime_and_drains_test_() ->
    {timeout, 20, fun short_soak/0}.

short_soak() ->
    rand:seed(exsss, {17, 23, 42}),
    {Actions, Elements} = actions(2000, 8, 4),
    Expected = single(Actions),
    {ok, Sup} = ari_concurrent_sup:start_link(ari_short_soak, counting(),
                                              #{workers => 4, max_in_flight => 1000}),
    unlink(Sup),
    Collector = collector(self(), Elements),
    try
        lists:foreach(fun concurrent_action/1, Actions),
        receive
            {collected, Collector, Actual} -> ?assertEqual(Expected, Actual)
        after 15000 ->
            error(soak_timed_out)
        end,
        [Coordinator] = pg:get_local_members(ari_short_soak, coordinator),
        ?assert(empty(Coordinator))
    after
        is_process_alive(Collector) andalso exit(Collector, kill),
        stop(Sup)
    end.

actions(Pushes, Window, Batch) ->
    State = actions(Pushes, Window, Batch, #{
        earliest => 0, pushes => 0, elements => 0, actions => []
    }),
    Last = maps:get(earliest, State) + Window - 1,
    {lists:reverse([{close, Last} | maps:get(actions, State)]), maps:get(elements, State)}.

actions(Pushes, _Window, _Batch, #{pushes := Pushes} = State) ->
    State;
actions(Pushes, Window, Batch, #{earliest := Earliest, actions := Actions} = State) ->
    State2 = case rand:uniform(5) of
        1 ->
            State#{earliest := Earliest + 1, actions := [{close, Earliest} | Actions]};
        _ ->
            N = rand:uniform(Batch),
            Epoch = Earliest + rand:uniform(Window) - 1,
            Count = maps:get(elements, State),
            Messages = lists:seq(Count + 1, Count + N),
            State#{pushes := maps:get(pushes, State) + 1, elements := Count + N,
                   actions := [{push, Epoch, Messages} | Actions]}
    end,
    actions(Pushes, Window, Batch, State2).

single(Actions) ->
    R0 = ari_single_runtime:new(counting()),
    R1 = lists:foldl(fun single_action/2, R0, Actions),
    {Output, R2} = ari_single_runtime:pull(output, ari_single_runtime:run(R1)),
    ok = ari_single_runtime:stop(R2),
    sum(Output, #{}).

single_action({push, Epoch, Messages}, Runtime) ->
    ari_single_runtime:push(input, Epoch, Messages, Runtime);
single_action({close, Epoch}, Runtime) ->
    ari_single_runtime:close(input, Epoch, Runtime).

concurrent_action({push, Epoch, Messages}) ->
    ok = ari_concurrent_runtime:push(ari_short_soak, input, Epoch, Messages);
concurrent_action({close, Epoch}) ->
    ok = ari_concurrent_runtime:close(ari_short_soak, input, Epoch).

collector(Parent, Target) ->
    Collector = spawn_link(fun() ->
        _ = process_flag(message_queue_data, off_heap),
        {_, _} = ari_concurrent_runtime:subscribe(ari_short_soak, output),
        Parent ! {subscribed, self()},
        collect(Parent, Target, 0, #{})
    end),
    receive {subscribed, Collector} -> Collector end.

collect(Parent, Target, Count, Output) when Count >= Target ->
    settle(),
    Parent ! {collected, self(), drain(Output)};
collect(Parent, Target, Count, Output) ->
    receive
        {ariadne, ari_short_soak, output, N, Time} ->
            collect(Parent, Target, Count + N, add(Time, N, Output))
    end.

drain(Output) ->
    receive
        {ariadne, ari_short_soak, output, N, Time} -> drain(add(Time, N, Output))
    after 0 ->
        Output
    end.

sum([], Output) -> Output;
sum([{N, Time} | Rest], Output) -> sum(Rest, add(Time, N, Output)).

add(Time, N, Output) ->
    maps:update_with(Time, fun(Old) -> Old + N end, N, Output).

settle() ->
    Workers = pg:get_local_members(ari_short_soak, workers),
    [Coordinator] = pg:get_local_members(ari_short_soak, coordinator),
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

counting() ->
    ari_graph:graph([
        ari_graph:in(input, {count, in}),
        ari_graph:node(count, ari_test_count, []),
        ari_graph:out(output, {count, done})
    ]).

stop(Sup) ->
    case is_process_alive(Sup) of
        false -> ok;
        true ->
            Ref = monitor(process, Sup),
            exit(Sup, shutdown),
            receive {'DOWN', Ref, process, Sup, _Reason} -> ok end
    end.
