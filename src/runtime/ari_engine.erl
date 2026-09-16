%%%-------------------------------------------------------------------
%%% @doc
%%% Core of a runtime: one copy of a dataflow graph at work.
%%%
%%% The engine holds the states of the vertices (see {@link
%%% ariadne_vertex}), the messages waiting on the edges, the
%%% notifications the vertices asked for and the items that left the
%%% graph. It is a value: every operation returns a new engine.
%%%
%%% The engine delivers the events it is told to and does not choose
%%% which one comes next. A message is taken off the queue with
%%% {@link dequeue/1} and delivered with {@link deliver/2}; a
%%% notification is delivered with {@link notify/3} once whoever
%%% tracks the progress of the graph finds its time complete, see
%%% {@link ari_progress}. Every delivery returns a delta (see {@link
%%% ari_progress:delta()}): the work it released and the work it
%%% created, as pointstamps. The engine keeps no count of them
%%% itself, so several engines running copies of one graph can
%%% report to a single progress.
%%%
%%% What a vertex returns is checked on the spot, see {@link
%%% deliver/2}.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_engine).

-include("ari_graph.hrl").

-export([
    new/1,
    new/3,
    push/4,
    accept/2,
    outbox/1,
    dequeue/1,
    deliver/2,
    notify/3,
    notifications/1,
    asked/1,
    pull/2,
    stop/1
]).

-export_type([
    t/0,
    event/0
]).

%% A message waiting on an edge, with the timestamp it was sent with:
%% the change the edge makes is applied on delivery.
-type event() :: {Edge :: atom(), Message :: term(), ari_vtime:t()}.

-record(engine, {
    plan :: ari_plan:t(),
    %% Which copy of the graph this engine is, out of how many.
    index :: pos_integer(),
    count :: pos_integer(),
    %% The state of every vertex.
    states :: #{atom() => term()},
    %% The messages waiting on the edges, in the order they were sent.
    queue :: queue:queue(event()),
    %% The messages sent to other copies and not carried over yet,
    %% by copy, the latest first.
    outbox :: #{pos_integer() => [event()]},
    %% The notifications asked for and not delivered yet.
    notifications :: ari_asked:t([]),
    %% The items that left the graph along every output, the latest
    %% first.
    outputs :: #{atom() => [{Message :: term(), ari_vtime:t()}]}
}).

-opaque t() :: #engine{}.

%%--------------------------------------------------------------------
%% @doc
%% Creates an engine of the plan `Plan' that is the only copy of the
%% graph, see {@link new/3}.
%% @end
%%--------------------------------------------------------------------
-spec new(ari_plan:t()) -> t().
new(Plan) ->
    new(Plan, 1, 1).

%%--------------------------------------------------------------------
%% @doc
%% Creates an engine of the plan `Plan' that is copy number `Index'
%% of the graph out of `Count' copies: initialises every vertex, see
%% {@link ariadne_vertex:init/1}.
%%
%% If the `init/1' of a vertex fails, the vertices initialised before
%% it are terminated (see {@link ariadne_vertex:terminate/1}) and the
%% call fails with the exception of `init/1'; an exception of
%% `terminate/1' raised meanwhile is dropped.
%% @end
%%--------------------------------------------------------------------
-spec new(ari_plan:t(), Index :: pos_integer(), Count :: pos_integer()) -> t().
new(Plan, Index, Count) when Index >= 1, Index =< Count ->
    #engine{
        plan = Plan,
        index = Index,
        count = Count,
        states = init(Plan, ari_plan:vertices(Plan), #{}),
        queue = queue:new(),
        outbox = #{},
        notifications = ari_asked:new(),
        outputs = #{Output => [] || Output <- ari_plan:outputs(Plan)}
    }.

%%--------------------------------------------------------------------
%% @doc
%% Puts the items `Messages' of time `Time' on the edge `Edge', in
%% the order given. The delta lists the work put on the edge; an edge
%% leading out of the graph is not waited on, so the items leave at
%% once (see {@link pull/2}) and the delta is empty.
%% @end
%%--------------------------------------------------------------------
-spec push(Edge :: atom(), Messages :: [term()], ari_vtime:t(), t()) -> {t(), ari_progress:delta()}.
push(Edge, Messages, Time, Engine) ->
    {Engine2, Added} = lists:foldl(
        fun(Message, {Acc, AddedAcc}) -> enqueue({Edge, Message, Time}, Acc, AddedAcc) end,
        {Engine, []},
        Messages
    ),
    {Engine2, {[], lists:reverse(Added)}}.

%%--------------------------------------------------------------------
%% @doc
%% Queues the events `Events', counted already by whoever sent them,
%% in the order given: the items another copy of the graph put in
%% its outbox for this one (see {@link outbox/1}), or the items of
%% an input counted before they were handed over. The events are
%% queued as they are, whatever copy their key names.
%% @end
%%--------------------------------------------------------------------
-spec accept(Events :: [event()], t()) -> t().
accept(Events, #engine{queue = Queue} = Engine) ->
    Engine#engine{queue = lists:foldl(fun queue:in/2, Queue, Events)}.

%%--------------------------------------------------------------------
%% @doc
%% Takes the messages sent to other copies of the graph since the
%% last call, by copy, each in the order sent, and empties the
%% outbox. The messages are counted already; the copy they go to
%% takes them with {@link accept/2}.
%% @end
%%--------------------------------------------------------------------
-spec outbox(t()) -> {#{pos_integer() => [event()]}, t()}.
outbox(#engine{outbox = Outbox} = Engine) ->
    {maps:map(fun(_Copy, Events) -> lists:reverse(Events) end, Outbox), Engine#engine{outbox = #{}}}.

%%--------------------------------------------------------------------
%% @doc
%% Takes the first message waiting off the queue, or returns `empty'.
%% The work of the message is released once it is delivered, see
%% {@link deliver/2}.
%% @end
%%--------------------------------------------------------------------
-spec dequeue(t()) -> {event(), t()} | empty.
dequeue(#engine{queue = Queue} = Engine) ->
    case queue:out(Queue) of
        {{value, Event}, Queue2} -> {Event, Engine#engine{queue = Queue2}};
        {empty, _Queue} -> empty
    end.

%%--------------------------------------------------------------------
%% @doc
%% Delivers the message of `Event' to the vertex at the end of its
%% edge, with the timestamp changed by the edge (see {@link
%% ari_plan:edge/2}), and takes care of what the vertex returns: the
%% messages are put on the edges leaving their slots, and the
%% notifications asked for are remembered, once each however many
%% times they are asked for. The delta releases the message and adds
%% every message sent and every notification newly asked for.
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
-spec deliver(event(), t()) -> {t(), ari_progress:delta()}.
deliver({Edge, Message, Time}, #engine{plan = Plan, states = States} = Engine) ->
    {Kind, _From, {Vertex, Slot}} = ari_plan:edge(Plan, Edge),
    Arrived = advance(Kind, Time),
    {Module, _Args} = ari_plan:vertex(Plan, Vertex),
    {State, Notifications, Messages} =
        Module:handle_message(Slot, Message, Arrived, maps:get(Vertex, States)),
    Engine2 = Engine#engine{states = States#{Vertex := State}},
    {Engine3, Requested} = request(Vertex, Arrived, Notifications, Engine2),
    {Engine4, Sent} = send(Vertex, Arrived, Messages, Engine3),
    {Engine4, {[{{edge, Edge}, Time}], Requested ++ Sent}}.

%%--------------------------------------------------------------------
%% @doc
%% Delivers the notification of `Time' to the vertex `Vertex' and
%% takes care of what the vertex returns, see {@link deliver/2}. The
%% delta releases the notification and adds every message sent.
%%
%% The notification is expected to have been asked for and not
%% delivered yet, see {@link notifications/1}; otherwise the call
%% fails with `{unknown_notification, {Vertex, Time}}'.
%% @end
%%--------------------------------------------------------------------
-spec notify(Vertex :: atom(), ari_vtime:t(), t()) -> {t(), ari_progress:delta()}.
notify(Vertex, Time, #engine{plan = Plan, states = States, notifications = Requested} = Engine) ->
    ari_asked:find(Vertex, Time, Requested) =/= none orelse
        error({unknown_notification, {Vertex, Time}}),
    {Module, _Args} = ari_plan:vertex(Plan, Vertex),
    {State, Messages} = Module:handle_notification(Time, maps:get(Vertex, States)),
    Engine2 = Engine#engine{
        states = States#{Vertex := State},
        notifications = ari_asked:remove(Vertex, Time, Requested)
    },
    {Engine3, Sent} = send(Vertex, Time, Messages, Engine2),
    {Engine3, {[{{vertex, Vertex}, Time}], Sent}}.

%%--------------------------------------------------------------------
%% @doc
%% The notifications asked for and not delivered yet, in no
%% particular order.
%% @end
%%--------------------------------------------------------------------
-spec notifications(t()) -> [{Vertex :: atom(), ari_vtime:t()}].
notifications(#engine{notifications = Requested}) ->
    [{Vertex, Time} || {Vertex, Time, []} <- ari_asked:to_list(Requested)].

%%--------------------------------------------------------------------
%% @doc
%% The notifications asked for and not delivered yet, as kept: by
%% the vertex in the order of their times, see {@link ari_asked}.
%% @end
%%--------------------------------------------------------------------
-spec asked(t()) -> ari_asked:t([]).
asked(#engine{notifications = Requested}) ->
    Requested.

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
pull(Output, #engine{outputs = Outputs} = Engine) ->
    case Outputs of
        #{Output := Messages} ->
            {lists:reverse(Messages), Engine#engine{outputs = Outputs#{Output := []}}};
        _ ->
            error({unknown_output, Output})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Shuts the engine down: terminates every vertex, see {@link
%% ariadne_vertex:terminate/1}. Whatever was outstanding is dropped.
%%
%% Every vertex is terminated even if the `terminate/1' of another
%% one fails; the call then fails with the first such exception once
%% every vertex has been tried.
%% @end
%%--------------------------------------------------------------------
-spec stop(t()) -> ok.
stop(#engine{plan = Plan, states = States}) ->
    Outcome = maps:fold(
        fun(Vertex, State, Acc) ->
            case terminate(Plan, Vertex, State) of
                ok -> Acc;
                Failure when Acc =:= ok -> Failure;
                _Failure -> Acc
            end
        end,
        ok,
        States
    ),
    case Outcome of
        ok -> ok;
        {Class, Reason, Stacktrace} -> erlang:raise(Class, Reason, Stacktrace)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Initialises the vertices `Vertices' one after another, given the
%% states `States' of the vertices initialised so far. If an `init/1'
%% fails, the vertices initialised so far are terminated and the
%% exception is raised again.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec init(ari_plan:t(), Vertices :: [atom()], States :: #{atom() => term()}) ->
    #{atom() => term()}.
init(_Plan, [], States) ->
    States;
init(Plan, [Vertex | Rest], States) ->
    {Module, Args} = ari_plan:vertex(Plan, Vertex),
    try Module:init(Args) of
        State -> init(Plan, Rest, States#{Vertex => State})
    catch
        Class:Reason:Stacktrace ->
            maps:foreach(fun(V, S) -> _ = terminate(Plan, V, S), ok end, States),
            erlang:raise(Class, Reason, Stacktrace)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Terminates the vertex `Vertex' of state `State', catching whatever
%% its `terminate/1' raises.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec terminate(ari_plan:t(), Vertex :: atom(), State :: term()) ->
    ok | {error | exit | throw, Reason :: term(), Stacktrace :: erlang:stacktrace()}.
terminate(Plan, Vertex, State) ->
    {Module, _Args} = ari_plan:vertex(Plan, Vertex),
    try Module:terminate(State) of
        _ -> ok
    catch
        Class:Reason:Stacktrace -> {Class, Reason, Stacktrace}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Remembers the notifications the vertex `Vertex' asked for while
%% handling an event of time `Event', and returns the pointstamps of
%% the ones not asked for before. Asking for a time again changes
%% nothing.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec request(Vertex :: atom(), Event :: ari_vtime:t(), [ari_vtime:t()], t()) ->
    {t(), [ari_progress:pointstamp()]}.
request(Vertex, Event, Times, Engine) ->
    {Engine2, Added} = lists:foldl(
        fun(Time, {#engine{notifications = Requested} = Acc, AddedAcc}) ->
            follows(Event, Time) orelse error({notification_in_the_past, {Vertex, Time}}),
            case ari_asked:find(Vertex, Time, Requested) of
                {value, []} ->
                    {Acc, AddedAcc};
                none ->
                    {Acc#engine{notifications = ari_asked:add(Vertex, Time, [], Requested)},
                     [{{vertex, Vertex}, Time} | AddedAcc]}
            end
        end,
        {Engine, []},
        Times
    ),
    {Engine2, lists:reverse(Added)}.

%%--------------------------------------------------------------------
%% @doc
%% Sends the messages the vertex `Vertex' returned while handling an
%% event of time `Event': every message goes along every edge leaving
%% its slot. Returns the pointstamps of the work put on the edges.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec send(
    Vertex :: atom(),
    Event :: ari_vtime:t(),
    [{Slot :: atom(), Message :: term(), ari_vtime:t()}],
    t()
) -> {t(), [ari_progress:pointstamp()]}.
send(Vertex, Event, Messages, #engine{plan = Plan} = Engine) ->
    {Module, _Args} = ari_plan:vertex(Plan, Vertex),
    Outputs = Module:outputs(),
    {Engine2, Added} = lists:foldl(
        fun({Slot, Message, Time}, {Acc, AddedAcc}) ->
            lists:member(Slot, Outputs) orelse error({unknown_slot, {Vertex, Slot}}),
            follows(Event, Time) orelse error({message_in_the_past, {Vertex, Time}}),
            lists:foldl(
                fun(Edge, {Acc2, AddedAcc2}) -> enqueue({Edge, Message, Time}, Acc2, AddedAcc2) end,
                {Acc, AddedAcc},
                ari_plan:outgoing(Plan, {Vertex, Slot})
            )
        end,
        {Engine, []},
        Messages
    ),
    {Engine2, lists:reverse(Added)}.

%%--------------------------------------------------------------------
%% @doc
%% Puts a message on an edge, adding its pointstamp in front of
%% `Added'. An edge leading out of the graph is not waited on: the
%% message leaves at once, with the timestamp changed by the edge,
%% and nothing is added. A message of an edge partitioned by a key
%% is queued here if its key names this copy of the graph, and put
%% in the outbox for the copy it names otherwise; it is counted
%% either way.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec enqueue(event(), t(), Added :: [ari_progress:pointstamp()]) -> {t(), [ari_progress:pointstamp()]}.
enqueue({Edge, Message, Time} = Event, #engine{plan = Plan} = Engine, Added) ->
    case ari_plan:edge(Plan, Edge) of
        {Kind, _From, undefined} ->
            #engine{outputs = Outputs} = Engine,
            Left = {Message, advance(Kind, Time)},
            {Engine#engine{outputs = maps:update_with(Edge, fun(Ms) -> [Left | Ms] end, Outputs)},
             Added};
        {_Kind, _From, _To} ->
            #engine{index = Index, count = Count, queue = Queue, outbox = Outbox} = Engine,
            Engine2 = case ari_plan:partition(Plan, Edge, Message, Count) of
                Copy when Copy =:= undefined; Copy =:= Index ->
                    Engine#engine{queue = queue:in(Event, Queue)};
                Copy ->
                    Engine#engine{
                        outbox = maps:update_with(Copy, fun(Es) -> [Event | Es] end, [Event], Outbox)
                    }
            end,
            {Engine2, [{{edge, Edge}, Time} | Added]}
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
