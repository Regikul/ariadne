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
%%% Beyond its slots the vertex knows nothing of the shape of the
%%% graph: it does not see which edge a message came along, and it
%%% does not name the edge a message goes out along. Timestamps
%%% change only at the boundary edges of a loop scope, and the runtime
%%% applies the change on the edge, so a vertex inside of a loop never
%%% deals with the timestamps of the outside.
%%%
%%% A callback does no sending of its own: it receives the event and
%%% the state and returns the new state together with what to send
%%% and what to be notified of, and the sending is done by the
%%% runtime. The order of the messages returned by one call is kept
%%% on every edge they are sent along.
%%%
%%% A vertex is not allowed to send into the past. Every message it
%%% returns must carry a timestamp that is the time of the event being
%%% handled or one that follows it, see {@link ari_vtime:le/2}. This
%%% is what lets the runtime tell when a time is complete: once every
%%% message of a time has been handled, no new message of that time
%%% can appear anywhere in the graph. Returning a message of a
%%% preceding time is an error of the vertex.
%%%
%%% Notifications are the way a vertex learns that a time is complete.
%%% While handling a message the vertex may ask to be notified at a
%%% time; the runtime then calls {@link handle_notification/2} once
%%% every message of a time that precedes or equals the requested one
%%% has been delivered to the vertex. This is where an operator that
%%% accumulates its input -- a count, a sum, a sort -- emits the
%%% result of an epoch or of an iteration of a loop. A vertex that
%%% needs no such point, e.g. a filter or a map, never asks for a
%%% notification and works message by message.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(ariadne_vertex).

%%--------------------------------------------------------------------
%% @doc
%% The names of the input slots of the vertex. The names are expected
%% to be distinct, and none of them may name an output slot too: a
%% slot name tells the side of the vertex on its own.
%% @end
%%--------------------------------------------------------------------
-callback inputs() -> [Slot :: atom()].

%%--------------------------------------------------------------------
%% @doc
%% The names of the output slots of the vertex. The names are expected
%% to be distinct, and none of them may name an input slot too, see
%% {@link inputs/0}.
%% @end
%%--------------------------------------------------------------------
-callback outputs() -> [Slot :: atom()].

%%--------------------------------------------------------------------
%% @doc
%% Creates the state of the vertex. `Args' is the value the vertex was
%% declared with in the graph, see {@link ari_graph:node/3}. Called
%% once, before the first message is delivered.
%% @end
%%--------------------------------------------------------------------
-callback init(Args :: term()) -> State :: term().

%%--------------------------------------------------------------------
%% @doc
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
%% @end
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
%% @doc
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
%% @end
%%--------------------------------------------------------------------
-callback handle_notification(
    Time :: ari_vtime:t(), State :: term()
) ->
    {
        NewState :: term(),
        Messages :: [{Slot :: atom(), Message :: term(), ari_vtime:t()}]
    }.

%%--------------------------------------------------------------------
%% @doc
%% Releases the resources of the vertex. Called once, when the graph
%% is shut down; no callback of the vertex is called afterwards.
%% @end
%%--------------------------------------------------------------------
-callback terminate(State :: term()) -> ok.
