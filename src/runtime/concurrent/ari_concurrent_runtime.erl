%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime of a dataflow graph in several processes.
%%%
%%% The runtime is a branch in the application's supervision tree, see
%%% {@link child_spec/3}. Workers run copies of the graph, a coordinator
%%% tracks their combined progress, and a local `pg' scope connects the
%%% processes. The scope name identifies the runtime on its node and is
%%% the first argument of every operation.
%%%
%%% ```
%%% %% in the supervisor of the application:
%%% ari_concurrent_runtime:child_spec(counting, Graph, #{workers => 4}),
%%%
%%% %% in the process feeding the graph:
%%% {Coordinator, Monitor} = ari_concurrent_runtime:subscribe(counting, done),
%%% ok = ari_concurrent_runtime:push(counting, input, 0, [A, B]),
%%% ok = ari_concurrent_runtime:close(counting, input, 0),
%%% receive
%%%     {ariadne, counting, done, Message, Time} -> ...;
%%%     {'DOWN', Monitor, process, Coordinator, Reason} -> ...
%%% end.
%%% '''
%%%
%%% Inputs use the epochs described by {@link ari_single_runtime}.
%%% Items are distributed among workers. Each worker preserves the
%%% order of the items it receives. The
%%% outputs are delivered as messages to the processes subscribed to
%%% them, see {@link subscribe/2}. Each worker's output is ordered;
%%% output from different workers has no global order.
%%%
%%% Every worker runs a full copy of the graph, so vertex state belongs
%%% to that copy. A `key' option on an input or edge routes equal keys
%%% to the same worker, see {@link ari_graph:in/3} and {@link
%%% ari_graph:edge/4}. An
%%% unpartitioned input distributes items among workers in turn.
%%%
%%% The runtime queues pushed items and messages produced by vertices
%%% until delivery. `max_in_flight' applies backpressure to pushes: a
%%% push waits while the current number of outstanding messages is at
%%% or above the limit. The runtime admits a push as one batch, so a
%%% batch of `N' items may raise the count to `max_in_flight - 1 + N'.
%%% Notification requests do not count toward this limit. {@link
%%% close/3} returns without waiting for capacity.
%%%
%%% `max_in_flight' controls external input; it does not bound messages
%%% produced inside the graph, loop iterations, vertex state, or
%%% subscriber mailboxes. `max_heap_size' sets the process flag of the
%%% same name on every worker. A worker that exceeds this limit is
%%% killed, the runtime branch stops, and its parent supervisor applies
%%% its restart strategy. Calls waiting in {@link push/4} exit when the
%%% branch stops. Subscribers are responsible for consuming output
%%% quickly enough to control their mailbox growth.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_concurrent_runtime).

-include("ari_graph.hrl").

-export([
    child_spec/3,
    push/4,
    close/3,
    subscribe/2
]).

-export_type([
    opts/0
]).

%% Runtime options. `workers' is required. `max_in_flight' defaults to
%% `infinity'. `max_heap_size' is passed to the process flag of the
%% same name and is unset by default.
-type opts() :: #{
    workers := pos_integer(),
    max_in_flight => pos_integer() | infinity,
    max_heap_size => non_neg_integer() | map()
}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the child specification for a runtime named `Name' running
%% `Graph' with `Opts'. Add the specification to an application
%% supervisor. One name identifies one runtime on a node.
%%
%% The branch validates the graph and options when it starts. Startup
%% returns the validation error if either is invalid.
%% @end
%%--------------------------------------------------------------------
-spec child_spec(Name :: atom(), Graph :: #graph{}, opts()) -> supervisor:child_spec().
child_spec(Name, Graph, Opts) ->
    #{
        id => Name,
        start => {ari_concurrent_sup, start_link, [Name, Graph, Opts]},
        type => supervisor,
        shutdown => infinity
    }.

%%--------------------------------------------------------------------
%% @doc
%% Pushes the items `Messages' into the input `Input' of the runtime
%% `Name' at epoch `Epoch'. The items are spread over the workers and
%% delivered in the order given by every worker; the call returns
%% once they are handed over, which it waits for as long as the
%% messages on their way are at the limit, see `max_in_flight' in
%% {@link opts()}. The pushes waiting are taken in the order made.
%%
%% Returns `{error, {unknown_input, Input}}' if the graph has no such
%% input. Returns `{error, {closed, {Input, Epoch}}}' if the epoch is
%% closed. Exits with `{not_running, Name}' if the runtime is not
%% running.
%% @end
%%--------------------------------------------------------------------
-spec push(Name :: atom(), Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()]) ->
    ok | {error, ari_progress:refusal()}.
push(Name, Input, Epoch, Messages) ->
    case coordinator(Name) of
        {ok, Coordinator} ->
            ari_crt_coordinator:push(Coordinator, Input, Epoch, Messages);
        error ->
            exit({not_running, Name})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input' of the
%% runtime `Name': no more items of those epochs are to be pushed,
%% and the times they contribute to may complete. Closing an epoch
%% that is closed already changes nothing.
%%
%% Returns `{error, {unknown_input, Input}}' if the graph has no such
%% input. Exits with `{not_running, Name}' if the runtime is not
%% running.
%% @end
%%--------------------------------------------------------------------
-spec close(Name :: atom(), Input :: atom(), Epoch :: non_neg_integer()) ->
    ok | {error, ari_progress:refusal()}.
close(Name, Input, Epoch) ->
    case coordinator(Name) of
        {ok, Coordinator} ->
            ari_crt_coordinator:close(Coordinator, Input, Epoch);
        error ->
            exit({not_running, Name})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Subscribes the calling process to the output `Output' of the
%% runtime `Name': every item leaving the graph through the output
%% is sent to it as `{ariadne, Name, Output, Message, Time}'. Items
%% of an output nobody is subscribed to are dropped.
%%
%% Returns the coordinator of the current incarnation of the runtime
%% and a monitor reference for it. When the coordinator terminates,
%% the caller receives `{'DOWN', Monitor, process, Coordinator,
%% Reason}' and the subscription no longer applies. A restarted
%% runtime is a new incarnation and has to be subscribed to again.
%%
%% For a high-volume output, the subscriber can set the process flag
%% `message_queue_data' to `off_heap' to reduce garbage-collection
%% costs while its mailbox contains messages.
%%
%% The call exits with:
%% <ul>
%% <li>`{not_running, Name}' -- the runtime has no current scope or
%% coordinator;</li>
%% <li>`{runtime_changed, Name}' -- another scope becomes current
%% while the subscription is being made.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Name :: atom(), Output :: atom()) ->
    {Coordinator :: pid(), Monitor :: reference()}.
subscribe(Name, Output) ->
    case runtime(Name) of
        {ok, Scope, Coordinator} ->
            Monitor = monitor(process, Coordinator),
            subscribe(Name, Output, self(), Scope, Coordinator, Monitor);
        {error, Reason} ->
            exit({Reason, Name})
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% The `pg' scope and coordinator of one incarnation of the runtime
%% `Name'. Distinguishes a runtime with no current coordinator from
%% one whose scope changes while the coordinator is looked up.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec runtime(Name :: atom()) ->
    {ok, Scope :: pid(), Coordinator :: pid()} | {error, not_running | runtime_changed}.
runtime(Name) ->
    case whereis(Name) of
        undefined ->
            {error, not_running};
        Scope ->
            case coordinator(Name) of
                {ok, Coordinator} ->
                    case current(Name, Scope) of
                        current -> {ok, Scope, Coordinator};
                        Reason -> {error, Reason}
                    end;
                error ->
                    {error, unavailable(Name, Scope)}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% The coordinator of the runtime `Name', or `error' if there is
%% none.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec coordinator(Name :: atom()) -> {ok, Coordinator :: pid()} | error.
coordinator(Name) ->
    case pg:get_local_members(Name, coordinator) of
        [Coordinator] -> {ok, Coordinator};
        [] -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Joins `Subscriber' to the output group of the incarnation whose
%% scope is `Scope'. If another scope has become current by the time
%% the join is done, rolls the join and monitor back and exits with
%% the reason that describes the current runtime state.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec subscribe(atom(), atom(), pid(), pid(), pid(), reference()) -> {pid(), reference()}.
subscribe(Name, Output, Subscriber, Scope, Coordinator, Monitor) ->
    try
        ok = pg:join(Name, {output, Output}, Subscriber)
    catch
        exit:_Reason ->
            _ = demonitor(Monitor, [flush]),
            exit({unavailable(Name, Scope), Name});
        Class:Error:Stacktrace ->
            _ = demonitor(Monitor, [flush]),
            erlang:raise(Class, Error, Stacktrace)
    end,
    case current(Name, Scope) of
        current ->
            {Coordinator, Monitor};
        Reason ->
            subscription_failed(Name, Output, Subscriber, Monitor, Reason)
    end.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec subscription_failed(atom(), atom(), pid(), reference(), not_running | runtime_changed) ->
    no_return().
subscription_failed(Name, Output, Subscriber, Monitor, Reason) ->
    %% The old scope may be gone already. If the join reached a new
    %% scope, one leave compensates its one membership.
    _ = catch pg:leave(Name, {output, Output}, Subscriber),
    _ = demonitor(Monitor, [flush]),
    exit({Reason, Name}).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec current(atom(), pid()) -> current | not_running | runtime_changed.
current(Name, Scope) ->
    case whereis(Name) of
        Scope -> current;
        undefined -> not_running;
        _AnotherScope -> runtime_changed
    end.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec unavailable(atom(), pid()) -> not_running | runtime_changed.
unavailable(Name, Scope) ->
    case current(Name, Scope) of
        runtime_changed -> runtime_changed;
        _ -> not_running
    end.
