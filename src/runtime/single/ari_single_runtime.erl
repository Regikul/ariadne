%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime of a dataflow graph in a single process.
%%%
%%% The runtime is a value. It holds the states of the vertices (see
%%% {@link ariadne_vertex}), the messages waiting on the edges, the
%%% notifications the vertices asked for and the items that left the
%%% graph, and every operation returns a new runtime. Nothing runs on
%%% its own: the caller feeds the inputs, asks for steps and reads the
%%% outputs.
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
%%% notification whose time is complete. A message is delivered with
%%% its timestamp changed by the edge it came along, see {@link
%%% ari_plan:edge/2}. A time is complete for a vertex when no message
%%% on any edge, no notification of any vertex and no open epoch of
%%% any input can result in a message of that time or of an earlier
%%% one arriving at the vertex, see {@link ari_summaries:reaches/5}.
%%% Messages are delivered before notifications: delivering a message
%%% costs one call, whereas telling whether a time is complete costs
%%% a walk over everything outstanding, and the fewer times it is
%%% done the better. The choice is made by `next/1' alone.
%%%
%%% What a vertex returns is checked on the spot, see {@link step/1}.
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

%% A message waiting on an edge, with the timestamp it was sent with:
%% the change the edge makes is applied on delivery.
-type event() :: {Edge :: atom(), Message :: term(), ari_vtime:t()}.

%% Work outstanding at a place of the graph: a message waiting on an
%% edge or a notification a vertex asked for.
-type pointstamp() :: {ari_summaries:location(), ari_vtime:t()}.

-record(runtime, {
    plan :: ari_plan:t(),
    %% The state of every vertex.
    states :: #{atom() => term()},
    %% The messages waiting on the edges, in the order they were sent.
    queue :: queue:queue(event()),
    %% How many items of work are outstanding at every pointstamp. A
    %% notification counts once however many times it was asked for.
    pending :: #{pointstamp() => pos_integer()},
    %% The first open epoch of every input, or `sealed' once no more
    %% items are to come.
    inputs :: #{atom() => non_neg_integer() | sealed},
    %% The items that left the graph along every output, the latest
    %% first.
    outputs :: #{atom() => [{Message :: term(), ari_vtime:t()}]}
}).

-opaque t() :: #runtime{}.

%%--------------------------------------------------------------------
%% @doc
%% Creates a runtime of the graph `Graph': prepares the plan of the
%% graph (see {@link ari_plan:prepare/1}, whose errors the call fails
%% with), initialises every vertex (see {@link
%% ariadne_vertex:init/1}) and opens every input at epoch 0.
%% @end
%%--------------------------------------------------------------------
-spec new(Graph :: #graph{}) -> t().
new(Graph) ->
    Plan = ari_plan:prepare(Graph),
    #runtime{
        plan = Plan,
        states = #{Vertex => init(Plan, Vertex) || Vertex <- ari_plan:vertices(Plan)},
        queue = queue:new(),
        pending = #{},
        inputs = #{Input => 0 || Input <- ari_plan:inputs(Plan)},
        outputs = #{Output => [] || Output <- ari_plan:outputs(Plan)}
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
push(Input, Epoch, Messages, #runtime{inputs = Inputs} = Runtime) ->
    case Inputs of
        #{Input := sealed} -> error({sealed, Input});
        #{Input := Open} when Epoch < Open -> error({closed, {Input, Epoch}});
        #{Input := _Open} -> ok;
        _ -> error({unknown_input, Input})
    end,
    Time = ari_vtime:new(Epoch),
    lists:foldl(
        fun(Message, Acc) -> enqueue({Input, Message, Time}, Acc) end,
        Runtime,
        Messages
    ).

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
close(Input, Epoch, #runtime{inputs = Inputs} = Runtime) ->
    case Inputs of
        #{Input := sealed} -> Runtime;
        #{Input := Open} -> Runtime#runtime{inputs = Inputs#{Input := max(Open, Epoch + 1)}};
        _ -> error({unknown_input, Input})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Seals the input `Input': no more items of any epoch are to be
%% pushed on it.
%%
%% Fails with `{unknown_input, Input}' if the plan has no such input.
%% @end
%%--------------------------------------------------------------------
-spec seal(Input :: atom(), t()) -> t().
seal(Input, #runtime{inputs = Inputs} = Runtime) ->
    is_map_key(Input, Inputs) orelse error({unknown_input, Input}),
    Runtime#runtime{inputs = Inputs#{Input := sealed}}.

%%--------------------------------------------------------------------
%% @doc
%% Delivers one event: a message waiting on an edge, or, if there is
%% none, a notification whose time is complete. Returns `idle' if
%% there is nothing to deliver.
%%
%% What the vertex returns is checked, and the call fails if the
%% vertex misbehaves:
%% <ul>
%% <li>`{message_in_the_past, {Vertex, Time}}' -- a message returned
%% with a time that does not follow the time of the event, see {@link
%% ari_vtime:le/2}; a time of another loop depth is one of those;</li>
%% <li>`{notification_in_the_past, {Vertex, Time}}' -- the same for a
%% notification asked for;</li>
%% <li>`{unknown_slot, {Vertex, Slot}}' -- a message returned for a
%% slot the vertex does not have among its outputs.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec step(t()) -> {ok, t()} | idle.
step(Runtime) ->
    case next(Runtime) of
        {message, Event, Runtime2} -> {ok, deliver(Event, Runtime2)};
        {notification, Vertex, Time} -> {ok, notify(Vertex, Time, Runtime)};
        idle -> idle
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
pull(Output, #runtime{outputs = Outputs} = Runtime) ->
    case Outputs of
        #{Output := Messages} ->
            {lists:reverse(Messages), Runtime#runtime{outputs = Outputs#{Output := []}}};
        _ ->
            error({unknown_output, Output})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Shuts the runtime down: terminates every vertex, see {@link
%% ariadne_vertex:terminate/1}. Whatever was outstanding is dropped.
%% @end
%%--------------------------------------------------------------------
-spec stop(t()) -> ok.
stop(#runtime{plan = Plan, states = States}) ->
    maps:foreach(
        fun(Vertex, State) ->
            {Callback, _Args} = ari_plan:vertex(Plan, Vertex),
            _ = Callback:terminate(State),
            ok
        end,
        States
    ).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% The initial state of the vertex `Vertex'.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec init(ari_plan:t(), Vertex :: atom()) -> term().
init(Plan, Vertex) ->
    {Callback, Args} = ari_plan:vertex(Plan, Vertex),
    Callback:init(Args).

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
    {message, event(), t()} | {notification, Vertex :: atom(), ari_vtime:t()} | idle.
next(#runtime{queue = Queue} = Runtime) ->
    case queue:out(Queue) of
        {{value, Event}, Queue2} ->
            {message, Event, Runtime#runtime{queue = Queue2}};
        {empty, _Queue} ->
            Requested = lists:sort(
                [{Time, Vertex} || {{vertex, Vertex}, Time} := _Count <- Runtime#runtime.pending]
            ),
            case lists:search(fun({Time, Vertex}) -> complete({Vertex, Time}, Runtime) end, Requested) of
                {value, {Time, Vertex}} -> {notification, Vertex, Time};
                false -> idle
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% Tells whether the time `Time' is complete for the vertex `Vertex':
%% whether nothing outstanding, the notification itself aside, can
%% result in a message of `Time' or of an earlier time arriving at
%% the vertex. An open input is outstanding at its first open epoch;
%% the later ones reach no further.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec complete({Vertex :: atom(), ari_vtime:t()}, t()) -> boolean().
complete({Vertex, Time}, #runtime{plan = Plan, pending = Pending, inputs = Inputs}) ->
    Summaries = ari_plan:summaries(Plan),
    Self = {{vertex, Vertex}, Time},
    Outstanding =
        [Pointstamp || Pointstamp := _Count <- Pending, Pointstamp =/= Self] ++
        [{{edge, Input}, ari_vtime:new(Open)} || Input := Open <- Inputs, is_integer(Open)],
    not lists:any(
        fun({Location, From}) ->
            ari_summaries:reaches(Summaries, Location, From, {vertex, Vertex}, Time)
        end,
        Outstanding
    ).

%%--------------------------------------------------------------------
%% @doc
%% Delivers the message of `Event' to the vertex at the end of its
%% edge, with the timestamp changed by the edge, and takes care of
%% what the vertex returns.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec deliver(event(), t()) -> t().
deliver({Edge, Message, Time}, #runtime{plan = Plan, states = States, pending = Pending} = Runtime) ->
    {Kind, _From, {Vertex, Slot}} = ari_plan:edge(Plan, Edge),
    Arrived = advance(Kind, Time),
    {Callback, _Args} = ari_plan:vertex(Plan, Vertex),
    {State, Notifications, Messages} =
        Callback:handle_message(Slot, Message, Arrived, maps:get(Vertex, States)),
    Runtime2 = Runtime#runtime{
        states = States#{Vertex := State},
        pending = release({{edge, Edge}, Time}, Pending)
    },
    send(Vertex, Arrived, Messages, request(Vertex, Arrived, Notifications, Runtime2)).

%%--------------------------------------------------------------------
%% @doc
%% Delivers the notification of `Time' to the vertex `Vertex' and
%% takes care of what the vertex returns.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec notify(Vertex :: atom(), ari_vtime:t(), t()) -> t().
notify(Vertex, Time, #runtime{plan = Plan, states = States, pending = Pending} = Runtime) ->
    {Callback, _Args} = ari_plan:vertex(Plan, Vertex),
    {State, Messages} = Callback:handle_notification(Time, maps:get(Vertex, States)),
    Runtime2 = Runtime#runtime{
        states = States#{Vertex := State},
        pending = maps:remove({{vertex, Vertex}, Time}, Pending)
    },
    send(Vertex, Time, Messages, Runtime2).

%%--------------------------------------------------------------------
%% @doc
%% Registers the notifications the vertex `Vertex' asked for while
%% handling an event of time `Event'. Asking for a time again changes
%% nothing.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec request(Vertex :: atom(), Event :: ari_vtime:t(), [ari_vtime:t()], t()) -> t().
request(Vertex, Event, Times, Runtime) ->
    lists:foldl(
        fun(Time, #runtime{pending = Pending} = Acc) ->
            follows(Event, Time) orelse error({notification_in_the_past, {Vertex, Time}}),
            Acc#runtime{pending = Pending#{{{vertex, Vertex}, Time} => 1}}
        end,
        Runtime,
        Times
    ).

%%--------------------------------------------------------------------
%% @doc
%% Sends the messages the vertex `Vertex' returned while handling an
%% event of time `Event': every message goes along every edge leaving
%% its slot.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec send(
    Vertex :: atom(),
    Event :: ari_vtime:t(),
    [{Slot :: atom(), Message :: term(), ari_vtime:t()}],
    t()
) -> t().
send(Vertex, Event, Messages, #runtime{plan = Plan} = Runtime) ->
    {Callback, _Args} = ari_plan:vertex(Plan, Vertex),
    Outputs = Callback:outputs(),
    lists:foldl(
        fun({Slot, Message, Time}, Acc) ->
            lists:member(Slot, Outputs) orelse error({unknown_slot, {Vertex, Slot}}),
            follows(Event, Time) orelse error({message_in_the_past, {Vertex, Time}}),
            lists:foldl(
                fun(Edge, Acc2) -> enqueue({Edge, Message, Time}, Acc2) end,
                Acc,
                ari_plan:outgoing(Plan, {Vertex, Slot})
            )
        end,
        Runtime,
        Messages
    ).

%%--------------------------------------------------------------------
%% @doc
%% Puts a message on an edge. An edge leading out of the graph is not
%% waited on: the message leaves at once, with the timestamp changed
%% by the edge.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec enqueue(event(), t()) -> t().
enqueue({Edge, Message, Time} = Event, #runtime{plan = Plan} = Runtime) ->
    case ari_plan:edge(Plan, Edge) of
        {Kind, _From, undefined} ->
            #runtime{outputs = Outputs} = Runtime,
            Left = {Message, advance(Kind, Time)},
            Runtime#runtime{outputs = maps:update_with(Edge, fun(Ms) -> [Left | Ms] end, Outputs)};
        {_Kind, _From, _To} ->
            #runtime{queue = Queue, pending = Pending} = Runtime,
            Runtime#runtime{
                queue = queue:in(Event, Queue),
                pending = maps:update_with({{edge, Edge}, Time}, fun(N) -> N + 1 end, 1, Pending)
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% Takes one item of work off a pointstamp.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec release(pointstamp(), #{pointstamp() => pos_integer()}) -> #{pointstamp() => pos_integer()}.
release(Pointstamp, Pending) ->
    case Pending of
        #{Pointstamp := 1} -> maps:remove(Pointstamp, Pending);
        #{Pointstamp := N} -> Pending#{Pointstamp := N - 1}
    end.

%%--------------------------------------------------------------------
%% @doc
%% The timestamp an item carries after the edge of kind `Kind'.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec advance(ari_plan:kind(), ari_vtime:t()) -> ari_vtime:t().
advance(message, Time) -> Time;
advance(ingress, Time) -> ari_vtime:ingress(Time);
advance(egress, Time) -> ari_vtime:egress(Time);
advance(feedback, Time) -> ari_vtime:feedback(Time).

%%--------------------------------------------------------------------
%% @doc
%% Tells whether `Time' is `Event' or a time following it. A value
%% that is not a timestamp of the same loop depth follows nothing.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec follows(Event :: ari_vtime:t(), Time :: term()) -> boolean().
follows(Event, Time) ->
    try
        ari_vtime:le(Event, Time)
    catch
        error:function_clause -> false
    end.
