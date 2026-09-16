%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime of a dataflow graph in a single process.
%%%
%%% The runtime is an immutable value containing vertex states, queued
%%% events and graph progress. Every operation returns a new runtime.
%%% The caller feeds inputs, advances execution with {@link step/1} or
%%% {@link run/1}, and reads outputs with {@link pull/2}.
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
%%% notification whose time is complete. The runtime delivers queued
%%% messages before checking notifications. This order batches the
%%% more expensive completion checks after the queued work.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_single_runtime).

-include("ari_graph.hrl").

-export([
    new/1,
    push/4,
    close/3,
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
%% Creates a runtime for `Graph'. The call prepares and validates the
%% graph, initializes every vertex, and opens every input at epoch 0.
%% It raises graph-validation errors and callback errors from {@link
%% ariadne_vertex:init/1}.
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
%% `Input'. They are delivered in the order given by later steps.
%%
%% Raises `error({unknown_input, Input})' if the graph has no such
%% input. Raises `error({closed, {Input, Epoch}})' if the epoch is
%% closed.
%% @end
%%--------------------------------------------------------------------
-spec push(Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()], t()) -> t().
push(Input, Epoch, Messages, #runtime{engine = Engine, progress = Progress} = Runtime) ->
    case ari_progress:check_open(Input, Epoch, Progress) of
        ok -> track(ari_engine:push(Input, Messages, ari_vtime:new(Epoch), Engine), Runtime);
        {error, Reason} -> error(Reason)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input': no more items
%% of those epochs are to be pushed, and the times they contribute to
%% may complete. Closing an epoch that is closed already changes
%% nothing.
%%
%% Raises `error({unknown_input, Input})' if the graph has no such
%% input.
%% @end
%%--------------------------------------------------------------------
-spec close(Input :: atom(), Epoch :: non_neg_integer(), t()) -> t().
close(Input, Epoch, #runtime{progress = Progress} = Runtime) ->
    case ari_progress:close(Input, Epoch, Progress) of
        {ok, Closed} -> Runtime#runtime{progress = Closed};
        {error, Reason} -> error(Reason)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Delivers one event: a message waiting on an edge, or, if there is
%% none, a notification whose time is complete. Returns `idle' if
%% there is nothing to deliver.
%%
%% The call validates callback results and raises an error for an
%% invalid result.
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
%% Takes the items that left the graph along `Output' since the last
%% call, each with its timestamp and in output order.
%%
%% Raises `error({unknown_output, Output})' if the graph has no such
%% output.
%% @end
%%--------------------------------------------------------------------
-spec pull(Output :: atom(), t()) -> {[{Message :: term(), ari_vtime:t()}], t()}.
pull(Output, #runtime{engine = Engine} = Runtime) ->
    {Messages, Engine2} = ari_engine:pull(Output, Engine),
    {Messages, Runtime#runtime{engine = Engine2}}.

%%--------------------------------------------------------------------
%% @doc
%% Shuts the runtime down and terminates every vertex. Outstanding
%% work is dropped.
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
%% The notification is the earliest complete one, found the way
%% {@link ari_asked:first/2} does.
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
            Complete = fun(Vertex, Time) ->
                ari_progress:complete(Summaries, {Vertex, Time}, Progress)
            end,
            case ari_asked:first(Complete, ari_engine:asked(Engine)) of
                {value, {Vertex, Time, []}} -> {notification, Vertex, Time};
                none -> idle
            end
    end.
