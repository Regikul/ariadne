%%%-------------------------------------------------------------------
%%% @doc
%%% Worker of a runtime of a dataflow graph in several processes, see
%%% {@link ari_concurrent_runtime}.
%%%
%%% A worker runs a copy of the graph: an engine of its own (see
%%% {@link ari_engine}) with the states of every vertex, delivering
%%% the messages of its queue and the notifications the coordinator
%%% tells it are due, and reporting the deliveries of a round to the
%%% coordinator as one sum of their deltas, see {@link
%%% ari_progress:sum/0}. The workers are
%%% numbered; a worker learns its number and how many there are at
%%% start, and the processes of the others once the coordinator
%%% wires the runtime, see {@link wire/3}.
%%%
%%% The worker works in rounds. A round is opened by the items the
%%% coordinator feeds it (see {@link feed/4}), the items another
%%% worker sends it (see {@link exchange/2}) or a notification the
%%% coordinator tells it to deliver (see {@link notify/3}): the
%%% worker takes the event and delivers the messages of its queue
%%% until the round has run for as many steps as it is allowed to.
%%% Whenever the queue runs empty before that, the worker goes back
%%% to its mailbox for whatever it was told meanwhile -- more items,
%%% more notifications -- and takes that into the same round; the
%%% round is closed once the mailbox is empty too. Closing a round
%%% is reporting the deltas of the round to the coordinator as one
%%% sum, sending the messages the engine put in the outbox (see
%%% {@link ari_engine:outbox/1}) to the workers of the copies they
%%% belong to, and sending the items that left the graph in the
%%% round to the subscribers of the outputs, as `{ariadne, Name,
%%% Output, Message, Time}'. A round that ran out of steps is closed
%%% and followed by another one, once whatever else the worker was
%%% told meanwhile is taken care of.
%%%
%%% The mailbox being empty is told by the timeout of the server
%%% loop: a timeout of zero fires only when there is no message
%%% waiting. Taking in what came meanwhile keeps the rounds long
%%% under load: were a round to close with the queue, every batch of
%%% items sent by another worker would make a round of its own, and
%%% the batches, each a slice of a round's outbox, would shrink from
%%% worker to worker, and the rounds and the reports with them.
%%%
%%% Whatever is put on the way to the worker is counted before it is
%%% sent -- the items of a push by the coordinator, the messages of
%%% the outbox by the delta of the round they were sent in, which is
%%% reported before they are sent -- so the worker reports their
%%% delivery only, see {@link ari_crt_coordinator}.
%%%
%%% The callbacks of every vertex of the copy are called from the
%%% process of the worker; the vertices are terminated when the
%%% worker stops.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_crt_worker).

-behaviour(gen_server).


-export([
    start_link/5,
    index/1,
    wire/3,
    feed/4,
    exchange/2,
    notify/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% The most steps a round makes before the worker looks at what
%% else it was told.
-define(ROUND, 1000).

-record(worker, {
    name :: atom(),
    index :: pos_integer(),
    engine :: ari_engine:t(),
    outputs :: [atom()],
    coordinator :: pid() | undefined,
    workers :: tuple() | undefined,
    %% The sum of the deltas of the round open, not reported yet.
    sum = #{} :: ari_progress:sum(),
    %% The steps the round open may still take.
    left = ?ROUND :: non_neg_integer()
}).

%%--------------------------------------------------------------------
%% @doc
%% Starts worker number `Index' of the `Count' workers of the runtime
%% `Name' with a copy of the graph of plan `Plan', spawned with the
%% options `Spawn' (see `erlang:spawn_opt/4'). Every vertex of the
%% copy is initialised here, see {@link ari_engine:new/3}, whose
%% errors the start fails with. The worker joins the group `workers'
%% of the scope of the runtime.
%% @end
%%--------------------------------------------------------------------
-spec start_link(
    Name :: atom(), Index :: pos_integer(), Count :: pos_integer(), ari_plan:t(), Spawn :: [term()]
) -> {ok, pid()} | {error, term()}.
start_link(Name, Index, Count, Plan, Spawn) ->
    gen_server:start_link(?MODULE, {Name, Index, Count, Plan}, [{spawn_opt, Spawn}]).

%%--------------------------------------------------------------------
%% @doc
%% The number of the worker `Worker'.
%% @end
%%--------------------------------------------------------------------
-spec index(Worker :: pid()) -> pos_integer().
index(Worker) ->
    gen_server:call(Worker, index).

%%--------------------------------------------------------------------
%% @doc
%% Tells the worker `Worker' the coordinator of the runtime and the
%% processes of all the workers, by number.
%% @end
%%--------------------------------------------------------------------
-spec wire(Worker :: pid(), Coordinator :: pid(), Workers :: tuple()) -> ok.
wire(Worker, Coordinator, Workers) ->
    gen_server:cast(Worker, {wire, Coordinator, Workers}).

%%--------------------------------------------------------------------
%% @doc
%% Puts the items `Messages' of time `Time' on the input `Input' of
%% the copy of the worker `Worker', counted already.
%% @end
%%--------------------------------------------------------------------
-spec feed(Worker :: pid(), Input :: atom(), ari_vtime:t(), Messages :: [term()]) -> ok.
feed(Worker, Input, Time, Messages) ->
    gen_server:cast(Worker, {feed, Input, Time, Messages}).

%%--------------------------------------------------------------------
%% @doc
%% Hands the worker `Worker' the events `Events' another worker put
%% in its outbox for it, counted already, see {@link
%% ari_engine:outbox/1}.
%% @end
%%--------------------------------------------------------------------
-spec exchange(Worker :: pid(), Events :: [ari_engine:event()]) -> ok.
exchange(Worker, Events) ->
    gen_server:cast(Worker, {exchange, Events}).

%%--------------------------------------------------------------------
%% @doc
%% Tells the worker `Worker' to deliver the notification of `Time'
%% to the vertex `Vertex' of its copy: the time is complete. The
%% notification is expected to have been asked for by the worker.
%% @end
%%--------------------------------------------------------------------
-spec notify(Worker :: pid(), Vertex :: atom(), ari_vtime:t()) -> ok.
notify(Worker, Vertex, Time) ->
    gen_server:cast(Worker, {notify, Vertex, Time}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Name, Index, Count, Plan}) ->
    process_flag(trap_exit, true),
    ok = pg:join(Name, workers, self()),
    Worker = #worker{
        name = Name,
        index = Index,
        engine = ari_engine:new(Plan, Index, Count),
        outputs = ari_plan:outputs(Plan)
    },
    {ok, Worker}.

%% @private
handle_call(index, _From, #worker{index = Index} = Worker) ->
    {reply, Index, Worker, 0}.

%% @private
handle_cast({wire, Coordinator, Workers}, Worker) ->
    {noreply, Worker#worker{coordinator = Coordinator, workers = Workers}, 0};
handle_cast(Told, Worker) ->
    go(take(Told, Worker)).

%% @private
%% The timeout fires once the mailbox is empty, see go/1.
handle_info(timeout, Worker) ->
    {noreply, close(Worker)};
handle_info(_Message, Worker) ->
    {noreply, Worker, 0}.

%% @private
terminate(_Reason, #worker{engine = Engine}) ->
    ari_engine:stop(Engine).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Takes what the worker was told into the round: queues the items
%% fed or sent, delivers the notification, adding its delta to the
%% sum of the round.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec take(Told :: term(), #worker{}) -> #worker{}.
take({feed, Input, Time, Messages}, #worker{engine = Engine} = Worker) ->
    Worker#worker{engine = ari_engine:accept([{Input, Message, Time} || Message <- Messages], Engine)};
take({exchange, Events}, #worker{engine = Engine} = Worker) ->
    Worker#worker{engine = ari_engine:accept(Events, Engine)};
take({notify, Vertex, Time}, #worker{engine = Engine, sum = Sum} = Worker) ->
    {Engine2, Delta} = ari_engine:notify(Vertex, Time, Engine),
    Worker#worker{engine = Engine2, sum = ari_progress:sum(Delta, Sum)};
take(round, Worker) ->
    Worker.

%%--------------------------------------------------------------------
%% @doc
%% Goes on with the round: delivers the messages of the queue for
%% the steps the round has left. If the steps run out, closes the
%% round and asks for another one; if the queue runs empty, returns
%% to the server loop with a timeout of zero, to take in whatever is
%% in the mailbox and close the round once nothing is.
%%
%% Every callback returns with the timeout, whether or not a round
%% is open: closing a round with nothing in it costs nothing.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec go(#worker{}) -> {noreply, #worker{}} | {noreply, #worker{}, 0}.
go(#worker{left = Left} = Worker) ->
    case steps(Left, Worker) of
        {Worker2, 0} ->
            Worker3 = close(Worker2),
            gen_server:cast(self(), round),
            {noreply, Worker3};
        {Worker2, Left2} ->
            {noreply, Worker2#worker{left = Left2}, 0}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Closes the round: reports its sum to the coordinator (see {@link
%% ari_progress:sum/2}), sends the messages of the outbox to the
%% workers they belong to and sends the items that left the graph to
%% the subscribers.
%%
%% The report goes out before the outbox does, so that the
%% coordinator counts a message before the worker it goes to can
%% report its delivery.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec close(#worker{}) -> #worker{}.
close(#worker{coordinator = Coordinator, sum = Sum} = Worker) ->
    map_size(Sum) =:= 0 orelse ari_crt_coordinator:report(Coordinator, self(), Sum),
    publish(exchange(Worker#worker{sum = #{}, left = ?ROUND})).

%%--------------------------------------------------------------------
%% @doc
%% Delivers up to `Steps' messages of the queue, adding their deltas
%% to the sum of the round, until the queue is empty. Returns the
%% steps left: none if they ran out before the queue did.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec steps(Steps :: non_neg_integer(), #worker{}) -> {#worker{}, Left :: non_neg_integer()}.
steps(0, Worker) ->
    {Worker, 0};
steps(Steps, #worker{engine = Engine, sum = Sum} = Worker) ->
    case ari_engine:dequeue(Engine) of
        {Event, Engine2} ->
            {Engine3, Delta} = ari_engine:deliver(Event, Engine2),
            steps(Steps - 1, Worker#worker{engine = Engine3, sum = ari_progress:sum(Delta, Sum)});
        empty ->
            {Worker, Steps}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Sends the messages the engine put in its outbox to the workers of
%% the copies they belong to, see {@link exchange/2}.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec exchange(#worker{}) -> #worker{}.
exchange(#worker{engine = Engine, workers = Workers} = Worker) ->
    {Outbox, Engine2} = ari_engine:outbox(Engine),
    maps:foreach(fun(Copy, Events) -> exchange(element(Copy, Workers), Events) end, Outbox),
    Worker#worker{engine = Engine2}.

%%--------------------------------------------------------------------
%% @doc
%% Sends the items that left the graph to the subscribers of their
%% outputs, see {@link ari_concurrent_runtime:subscribe/2}. The items
%% of an output nobody is subscribed to are dropped.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec publish(#worker{}) -> #worker{}.
publish(#worker{name = Name, outputs = Outputs} = Worker) ->
    lists:foldl(
        fun(Output, #worker{engine = Engine} = Acc) ->
            {Left, Engine2} = ari_engine:pull(Output, Engine),
            Subscribers = pg:get_members(Name, {output, Output}),
            lists:foreach(
                fun({Message, Time}) ->
                    lists:foreach(
                        fun(Pid) -> Pid ! {ariadne, Name, Output, Message, Time} end, Subscribers
                    )
                end,
                Left
            ),
            Acc#worker{engine = Engine2}
        end,
        Worker,
        Outputs
    ).
