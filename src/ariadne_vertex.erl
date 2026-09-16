%%%-------------------------------------------------------------------
%%% @doc
%%% Behaviour of an operator of a dataflow graph.
%%%
%%% Every vertex of a graph (see {@link ari_graph}) is run by a
%%% callback module implementing this behaviour. The module holds the
%%% state of the operator and reacts to two kinds of event: a message
%%% arriving along an incoming edge, and a notification that no more
%%% messages of a given time are to arrive. Every message is stamped
%%% with a timestamp (see {@link ari_vtime}).
%%%
%%% A vertex talks to the graph through its slots: the input slots
%%% messages arrive at and the output slots messages leave through.
%%% The callback module declares them by name with {@link inputs/0}
%%% and {@link outputs/0}, and an edge of the graph is attached to a
%%% slot, see {@link ari_graph:edge/3}. Several edges may be attached
%%% to one slot: a message sent to an output slot goes along every
%%% edge attached to it, and an input slot with several edges sees
%%% their messages as a single stream. A slot with no edge attached
%%% is allowed: an input like that stays silent, and whatever is sent
%%% to an output like that is dropped.
%%%
%%% The runtime presents a vertex with slot names and routes the
%%% messages it returns. It also applies timestamp changes at loop
%%% boundaries. The callback therefore handles the timestamps of its
%%% own loop depth.
%%%
%%% A callback receives an event and its state, then returns the new
%%% state, notification requests and outgoing messages. The runtime
%%% performs those effects. It preserves the order of the messages
%%% returned by one call on every edge.
%%%
%%% Every outgoing message must carry the time of the event being
%%% handled or a later time, see {@link ari_vtime:le/2}. This rule lets
%%% the runtime determine completion: after it handles all messages of
%%% a time, no vertex can create another message at that time.
%%%
%%% A notification tells a vertex that a time is complete.
%%% While handling a message the vertex may ask to be notified at a
%%% time; the runtime then calls {@link handle_notification/2} once
%%% every message of a time that precedes or equals the requested one
%%% has been delivered to the vertex. This is where an operator that
%%% accumulates its input -- a count, a sum, a sort -- emits the
%%% result of an epoch or of an iteration of a loop. A vertex that
%%% needs no such point, e.g. a filter or a map, never asks for a
%%% notification and works message by message.
%%%
%%% <h2>Callbacks</h2>
%%% <dl>
%%% <dt>{@link inputs/0}</dt>
%%% <dd>Declares the input slots.</dd>
%%% <dt>{@link outputs/0}</dt>
%%% <dd>Declares the output slots.</dd>
%%% <dt>{@link init/1}</dt>
%%% <dd>Creates the vertex state from the argument stored in the
%%% graph.</dd>
%%% <dt>{@link handle_message/4}</dt>
%%% <dd>Handles one item and returns state, notification requests and
%%% outgoing messages.</dd>
%%% <dt>{@link handle_notification/2}</dt>
%%% <dd>Handles completion of a requested time and returns state and
%%% outgoing messages.</dd>
%%% <dt>{@link terminate/1}</dt>
%%% <dd>Releases resources held by the vertex.</dd>
%%% </dl>
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(ariadne_vertex).

%%--------------------------------------------------------------------
%% The names of the input slots of the vertex. The names are expected
%% to be distinct, and none of them may name an output slot too: a
%% slot name tells the side of the vertex on its own.
%%--------------------------------------------------------------------
-callback inputs() -> [Slot :: atom()].

%%--------------------------------------------------------------------
%% The names of the output slots of the vertex. The names are expected
%% to be distinct, and none of them may name an input slot too, see
%% {@link inputs/0}.
%%--------------------------------------------------------------------
-callback outputs() -> [Slot :: atom()].

%%--------------------------------------------------------------------
%% Creates the state of the vertex. `Args' is the value the vertex was
%% declared with in the graph, see {@link ari_graph:node/3}. Called
%% once, before the first message is delivered.
%%--------------------------------------------------------------------
-callback init(Args :: term()) -> State :: term().

%%--------------------------------------------------------------------
%% Handles a message that arrived at the input slot `Slot' of the
%% vertex. `Time' is the timestamp of the message.
%%
%% Returns the new state, the times the vertex wants to be notified at
%% and the messages to send, each with the output slot to send it
%% through and a timestamp of its own.
%%
%% A notification may be requested at `Time' or at a time that follows
%% it; a time that precedes `Time' may already be complete and cannot
%% be waited for. Requesting a notification at one and the same time
%% more than once yields a single notification. Nothing has to be
%% requested: a vertex that does not care about the completion of
%% times returns an empty list.
%%
%% Every message returned must carry `Time' or a time that follows it.
%%--------------------------------------------------------------------
-callback handle_message(
    Slot :: atom(), Message :: term(), Time :: ari_vtime:t(), State :: term()
) ->
    {
        NewState :: term(),
        Notifications :: [ari_vtime:t()],
        Messages :: [{Slot :: atom(), Message :: term(), ari_vtime:t()}]
    }.

%%--------------------------------------------------------------------
%% Handles a notification requested earlier by {@link
%% handle_message/4}. When called, every message of a time that
%% precedes or equals `Time' has been delivered to the vertex, and no
%% more of them are to come: the vertex may treat the time as
%% complete and release whatever it kept for it.
%%
%% Returns the new state and the messages to send, each with the
%% output slot to send it through and a timestamp of its own. Every
%% message returned must carry `Time' or
%% a time that follows it. No notification can be requested from
%% here; a vertex that needs to be notified again asks for it when
%% handling a message.
%%--------------------------------------------------------------------
-callback handle_notification(
    Time :: ari_vtime:t(), State :: term()
) ->
    {
        NewState :: term(),
        Messages :: [{Slot :: atom(), Message :: term(), ari_vtime:t()}]
    }.

%%--------------------------------------------------------------------
%% Releases the resources of the vertex. Called once, when the graph
%% is shut down; no callback of the vertex is called afterwards.
%%--------------------------------------------------------------------
-callback terminate(State :: term()) -> ok.
