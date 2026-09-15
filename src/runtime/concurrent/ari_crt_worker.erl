%%%-------------------------------------------------------------------
%%% @doc
%%% Worker of a runtime of a dataflow graph in several processes, see
%%% {@link ari_concurrent_runtime}.
%%%
%%% A worker runs a copy of the graph: an engine of its own (see
%%% {@link ari_engine}) with the states of every vertex, delivering
%%% the messages of its queue and the notifications the coordinator
%%% tells it are due, and reporting every delivery to the coordinator
%%% as a delta, see {@link ari_progress:delta/0}. The workers are
%%% numbered; a worker learns its number at start and the processes
%%% of the others once the coordinator wires the runtime, see {@link
%%% wire/3}.
%%%
%%% The worker works in rounds. A round is started by the items the
%%% coordinator feeds it (see {@link feed/4}) or a notification it
%%% tells it to deliver (see {@link notify/3}): the worker delivers
%%% the event and then the messages of its queue until the queue is
%%% empty or the round has run for as many steps as it is allowed
%%% to, reports the deltas of the round to the coordinator as one
%%% delta, and sends the items that left the graph in the round to
%%% the subscribers of the outputs, as `{ariadne, Name, Output,
%%% Message, Time}'. A round cut short is followed by another one,
%%% once whatever else the worker was told meanwhile is taken care
%%% of.
%%%
%%% The items fed by the coordinator are counted by the coordinator
%%% before they are sent, so the worker reports their delivery only,
%%% see {@link ari_crt_coordinator}.
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
    start_link/3,
    index/1,
    wire/3,
    feed/4,
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
    workers :: tuple() | undefined
}).

%%--------------------------------------------------------------------
%% @doc
%% Starts worker number `Index' of the runtime `Name' with a copy of
%% the graph of plan `Plan'. Every vertex of the copy is initialised
%% here, see {@link ari_engine:new/1}, whose errors the start fails
%% with. The worker joins the group `workers' of the scope of the
%% runtime.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name :: atom(), Index :: pos_integer(), ari_plan:t()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Index, Plan) ->
    gen_server:start_link(?MODULE, {Name, Index, Plan}, []).

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
init({Name, Index, Plan}) ->
    process_flag(trap_exit, true),
    ok = pg:join(Name, workers, self()),
    Worker = #worker{
        name = Name,
        index = Index,
        engine = ari_engine:new(Plan),
        outputs = ari_plan:outputs(Plan)
    },
    {ok, Worker}.

%% @private
handle_call(index, _From, #worker{index = Index} = Worker) ->
    {reply, Index, Worker}.

%% @private
handle_cast({wire, Coordinator, Workers}, Worker) ->
    {noreply, Worker#worker{coordinator = Coordinator, workers = Workers}};
handle_cast({feed, Input, Time, Messages}, #worker{engine = Engine} = Worker) ->
    {Engine2, _Counted} = ari_engine:push(Input, Messages, Time, Engine),
    {noreply, round(Worker#worker{engine = Engine2}, {[], []})};
handle_cast({notify, Vertex, Time}, #worker{engine = Engine} = Worker) ->
    {Engine2, Delta} = ari_engine:notify(Vertex, Time, Engine),
    {noreply, round(Worker#worker{engine = Engine2}, Delta)};
handle_cast(round, Worker) ->
    {noreply, round(Worker, {[], []})}.

%% @private
handle_info(_Message, Worker) ->
    {noreply, Worker}.

%% @private
terminate(_Reason, #worker{engine = Engine}) ->
    ari_engine:stop(Engine).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Runs a round started with the delta `Delta': delivers the messages
%% of the queue, reports the deltas of the round as one, and sends
%% the items that left the graph to the subscribers. If the round is
%% cut short, another one is asked for.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec round(#worker{}, ari_progress:delta()) -> #worker{}.
round(#worker{coordinator = Coordinator} = Worker, Delta) ->
    {Worker2, Delta2, Exhausted} = steps(?ROUND, Worker, Delta),
    case Delta2 of
        {[], []} -> ok;
        _ -> ari_crt_coordinator:report(Coordinator, self(), Delta2)
    end,
    Exhausted andalso gen_server:cast(self(), round),
    publish(Worker2).

%%--------------------------------------------------------------------
%% @doc
%% Delivers up to `Steps' messages of the queue, adding their deltas
%% to `Delta', until the queue is empty. Tells whether the steps ran
%% out before the queue did.
%%
%% The order of the pointstamps within a delta does not matter to
%% the progress, see {@link ari_progress:apply/2}, so the deltas
%% are put together without regard to it.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec steps(Steps :: non_neg_integer(), #worker{}, ari_progress:delta()) ->
    {#worker{}, ari_progress:delta(), Exhausted :: boolean()}.
steps(0, Worker, Delta) ->
    {Worker, Delta, true};
steps(Steps, #worker{engine = Engine} = Worker, {Released, Added}) ->
    case ari_engine:dequeue(Engine) of
        {Event, Engine2} ->
            {Engine3, {R, A}} = ari_engine:deliver(Event, Engine2),
            steps(Steps - 1, Worker#worker{engine = Engine3}, {R ++ Released, A ++ Added});
        empty ->
            {Worker, {Released, Added}, false}
    end.

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
