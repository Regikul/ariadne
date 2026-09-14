%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime of a dataflow graph in a single process.
%%%
%%% The runtime is a value: an engine running the graph (see {@link
%%% ari_engine}) and the progress of the graph (see {@link
%%% ari_progress}), and every operation returns a new runtime.
%%% Nothing runs on its own: the caller feeds the inputs, asks for
%%% steps and reads the outputs.
%%%
%%% ```
%%% R0 = ari_single_runtime:new(Graph),
%%% R1 = ari_single_runtime:push(input, 0, [A, B], R0),
%%% R2 = ari_single_runtime:close(input, 0, R1),
%%% R3 = ari_single_runtime:run(R2),
%%% {Out, R4} = ari_single_runtime:pull(done, R3),
%%% ok = ari_single_runtime:stop(R4).
%%% '''
%%%
%%% Items enter the graph in epochs, see {@link ari_vtime:new/1}. An
%%% epoch of an input stays open -- more items of it may be pushed --
%%% until the caller closes it with {@link close/3}, and an open epoch
%%% is work outstanding: no time it may still contribute to is
%%% complete, and no notification of such a time is delivered. A graph
%%% whose inputs are never closed delivers its messages and never
%%% notifies.
%%%
%%% A step of the runtime is one event: the delivery of a message to
%%% the vertex at the end of its edge, or the delivery of a
%%% notification whose time is complete, see {@link
%%% ari_progress:complete/3}. Messages are delivered before
%%% notifications: delivering a message costs one call, whereas
%%% telling whether a time is complete costs a walk over everything
%%% outstanding, and the fewer times it is done the better. The
%%% choice is made by `next/1' alone.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_single_runtime).

-include("ari_graph.hrl").

-export([
    new/1,
    push/4,
    close/3,
    seal/2,
    step/1,
    run/1,
    pull/2,
    stop/1
]).

-export_type([
    t/0
]).

-record(runtime, {
    plan :: ari_plan:t(),
    engine :: ari_engine:t(),
    progress :: ari_progress:t()
}).

-opaque t() :: #runtime{}.

%%--------------------------------------------------------------------
%% @doc
%% Creates a runtime of the graph `Graph': prepares the plan of the
%% graph (see {@link ari_plan:prepare/1}, whose errors the call fails
%% with), initialises every vertex (see {@link ari_engine:new/1},
%% whose errors the call fails with too) and opens every input at
%% epoch 0.
%% @end
%%--------------------------------------------------------------------
-spec new(Graph :: #graph{}) -> t().
new(Graph) ->
    Plan = ari_plan:prepare(Graph),
    #runtime{
        plan = Plan,
        engine = ari_engine:new(Plan),
        progress = ari_progress:new(ari_plan:inputs(Plan))
    }.

%%--------------------------------------------------------------------
%% @doc
%% Puts the items `Messages' of epoch `Epoch' on the input `Input',
%% see {@link ari_plan:inputs/1}. They are delivered in the order
%% given, by the steps to come.
%%
%% Fails with `{unknown_input, Input}' if the plan has no such input,
%% with `{closed, {Input, Epoch}}' if the epoch was closed and with
%% `{sealed, Input}' if the input was sealed.
%% @end
%%--------------------------------------------------------------------
-spec push(Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()], t()) -> t().
push(Input, Epoch, Messages, #runtime{engine = Engine, progress = Progress} = Runtime) ->
    ok = ari_progress:check_open(Input, Epoch, Progress),
    track(ari_engine:push(Input, Messages, ari_vtime:new(Epoch), Engine), Runtime).

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input': no more items
%% of those epochs are to be pushed, and the times they contribute to
%% may complete. Closing an epoch that is closed already changes
%% nothing.
%%
%% Fails with `{unknown_input, Input}' if the plan has no such input.
%% @end
%%--------------------------------------------------------------------
-spec close(Input :: atom(), Epoch :: non_neg_integer(), t()) -> t().
close(Input, Epoch, #runtime{progress = Progress} = Runtime) ->
    Runtime#runtime{progress = ari_progress:close(Input, Epoch, Progress)}.

%%--------------------------------------------------------------------
%% @doc
%% Seals the input `Input': no more items of any epoch are to be
%% pushed on it.
%%
%% Fails with `{unknown_input, Input}' if the plan has no such input.
%% @end
%%--------------------------------------------------------------------
-spec seal(Input :: atom(), t()) -> t().
seal(Input, #runtime{progress = Progress} = Runtime) ->
    Runtime#runtime{progress = ari_progress:seal(Input, Progress)}.

%%--------------------------------------------------------------------
%% @doc
%% Delivers one event: a message waiting on an edge, or, if there is
%% none, a notification whose time is complete. Returns `idle' if
%% there is nothing to deliver.
%%
%% What the vertex returns is checked, and the call fails if the
%% vertex misbehaves, see {@link ari_engine:deliver/2}.
%% @end
%%--------------------------------------------------------------------
-spec step(t()) -> {ok, t()} | idle.
step(#runtime{engine = Engine} = Runtime) ->
    case next(Runtime) of
        {message, Event, Runtime2} ->
            {ok, track(ari_engine:deliver(Event, Runtime2#runtime.engine), Runtime2)};
        {notification, Vertex, Time} ->
            {ok, track(ari_engine:notify(Vertex, Time, Engine), Runtime)};
        idle ->
            idle
    end.

%%--------------------------------------------------------------------
%% @doc
%% Steps until there is nothing to deliver, see {@link step/1}.
%% @end
%%--------------------------------------------------------------------
-spec run(t()) -> t().
run(Runtime) ->
    case step(Runtime) of
        {ok, Runtime2} -> run(Runtime2);
        idle -> Runtime
    end.

%%--------------------------------------------------------------------
%% @doc
%% Takes the items that left the graph along the output `Output' (see
%% {@link ari_plan:outputs/1}) since the last call, each with the
%% timestamp it left with, in the order they left in.
%%
%% Fails with `{unknown_output, Output}' if the plan has no such
%% output.
%% @end
%%--------------------------------------------------------------------
-spec pull(Output :: atom(), t()) -> {[{Message :: term(), ari_vtime:t()}], t()}.
pull(Output, #runtime{engine = Engine} = Runtime) ->
    {Messages, Engine2} = ari_engine:pull(Output, Engine),
    {Messages, Runtime#runtime{engine = Engine2}}.

%%--------------------------------------------------------------------
%% @doc
%% Shuts the runtime down: terminates every vertex, see {@link
%% ari_engine:stop/1}. Whatever was outstanding is dropped.
%% @end
%%--------------------------------------------------------------------
-spec stop(t()) -> ok.
stop(#runtime{engine = Engine}) ->
    ari_engine:stop(Engine).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Keeps the engine an operation returned and counts its delta in
%% the progress.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec track({ari_engine:t(), ari_progress:delta()}, t()) -> t().
track({Engine, Delta}, #runtime{progress = Progress} = Runtime) ->
    Runtime#runtime{engine = Engine, progress = ari_progress:apply(Delta, Progress)}.

%%--------------------------------------------------------------------
%% @doc
%% Chooses the event to deliver next: the first message waiting, or a
%% notification whose time is complete. A message is taken off the
%% queue; a notification is left where it is until it is delivered.
%%
%% The notifications are tried in the order of their times: a time
%% precedes every time following it in the order of terms, so a
%% notification is not blocked by any of those tried after it, and
%% the earliest one is usually complete. Telling whether a time is
%% complete is the expensive part, and the order keeps the number of
%% times it is told close to the number of notifications delivered.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec next(t()) ->
    {message, ari_engine:event(), t()} | {notification, Vertex :: atom(), ari_vtime:t()} | idle.
next(#runtime{plan = Plan, engine = Engine, progress = Progress} = Runtime) ->
    case ari_engine:dequeue(Engine) of
        {Event, Engine2} ->
            {message, Event, Runtime#runtime{engine = Engine2}};
        empty ->
            Summaries = ari_plan:summaries(Plan),
            Requested = lists:sort(
                [{Time, Vertex} || {Vertex, Time} <- ari_engine:notifications(Engine)]
            ),
            Complete = fun({Time, Vertex}) ->
                ari_progress:complete(Summaries, {Vertex, Time}, Progress)
            end,
            case lists:search(Complete, Requested) of
                {value, {Time, Vertex}} -> {notification, Vertex, Time};
                false -> idle
            end
    end.
