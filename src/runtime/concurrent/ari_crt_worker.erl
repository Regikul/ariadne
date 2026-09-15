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
    wire/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(worker, {
    name :: atom(),
    index :: pos_integer(),
    engine :: ari_engine:t(),
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

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Name, Index, Plan}) ->
    process_flag(trap_exit, true),
    ok = pg:join(Name, workers, self()),
    {ok, #worker{name = Name, index = Index, engine = ari_engine:new(Plan)}}.

%% @private
handle_call(index, _From, #worker{index = Index} = Worker) ->
    {reply, Index, Worker}.

%% @private
handle_cast({wire, Coordinator, Workers}, Worker) ->
    {noreply, Worker#worker{coordinator = Coordinator, workers = Workers}}.

%% @private
handle_info(_Message, Worker) ->
    {noreply, Worker}.

%% @private
terminate(_Reason, #worker{engine = Engine}) ->
    ari_engine:stop(Engine).
