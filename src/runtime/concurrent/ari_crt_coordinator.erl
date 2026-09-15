%%%-------------------------------------------------------------------
%%% @doc
%%% Coordinator of a runtime of a dataflow graph in several
%%% processes, see {@link ari_concurrent_runtime}.
%%%
%%% The coordinator keeps the progress of the graph as a whole (see
%%% {@link ari_progress}): it takes the items pushed into the inputs
%%% and hands them to the workers, keeps the epochs of the inputs,
%%% applies the deltas the workers report, and tells the workers when
%%% a notification is due. It runs no vertex itself.
%%%
%%% The coordinator is the last process of the branch to start. Once
%%% up, it finds the workers in the group `workers' of the scope of
%%% the runtime, asks every one of them its number and wires them
%%% together, see {@link ari_crt_worker:wire/3}. This is done before the
%%% first call is served, so a worker is wired before it is given any
%%% work.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_crt_coordinator).

-behaviour(gen_server).

-export([
    start_link/3,
    push/4,
    close/3
]).

-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2
]).

-record(coordinator, {
    name :: atom(),
    plan :: ari_plan:t(),
    progress :: ari_progress:t(),
    count :: pos_integer(),
    workers :: tuple() | undefined
}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the coordinator of the runtime `Name' of the graph of plan
%% `Plan' run by `Count' workers. The coordinator joins the group
%% `coordinator' of the scope of the runtime.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name :: atom(), ari_plan:t(), Count :: pos_integer()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Plan, Count) ->
    gen_server:start_link(?MODULE, {Name, Plan, Count}, []).

%%--------------------------------------------------------------------
%% @doc
%% Pushes the items `Messages' into the input `Input' at epoch
%% `Epoch', see {@link ari_concurrent_runtime:push/4}.
%% @end
%%--------------------------------------------------------------------
-spec push(
    Coordinator :: pid(), Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()]
) -> ok.
push(Coordinator, Input, Epoch, Messages) ->
    gen_server:call(Coordinator, {push, Input, Epoch, Messages}).

%%--------------------------------------------------------------------
%% @doc
%% Closes the epoch `Epoch' of the input `Input', see {@link
%% ari_concurrent_runtime:close/3}.
%% @end
%%--------------------------------------------------------------------
-spec close(Coordinator :: pid(), Input :: atom(), Epoch :: non_neg_integer()) -> ok.
close(Coordinator, Input, Epoch) ->
    gen_server:call(Coordinator, {close, Input, Epoch}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Name, Plan, Count}) ->
    ok = pg:join(Name, coordinator, self()),
    Coordinator = #coordinator{
        name = Name,
        plan = Plan,
        progress = ari_progress:new(ari_plan:inputs(Plan)),
        count = Count
    },
    {ok, Coordinator, {continue, wire}}.

%% @private
handle_continue(wire, #coordinator{name = Name, count = Count} = Coordinator) ->
    Pids = pg:get_local_members(Name, workers),
    Count = length(Pids),
    Numbered = lists:sort([{ari_crt_worker:index(Pid), Pid} || Pid <- Pids]),
    Workers = list_to_tuple([Pid || {_Index, Pid} <- Numbered]),
    lists:foreach(fun(Pid) -> ari_crt_worker:wire(Pid, self(), Workers) end, Pids),
    {noreply, Coordinator#coordinator{workers = Workers}}.

%% @private
%% Not done yet: the calls are taken and nothing is done about them.
handle_call({push, _Input, _Epoch, _Messages}, _From, Coordinator) ->
    {reply, ok, Coordinator};
handle_call({close, _Input, _Epoch}, _From, Coordinator) ->
    {reply, ok, Coordinator}.

%% @private
handle_cast(_Request, Coordinator) ->
    {noreply, Coordinator}.
