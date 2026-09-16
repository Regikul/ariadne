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
%%% The items of a push are spread over the workers: by their key if
%%% the input is partitioned (see {@link ari_plan:partition/4}), one
%%% by one in turn otherwise. Whoever puts an item on the way to
%%% another process counts it as work outstanding before sending
%%% it, and the receiver releases it once delivered: the coordinator
%%% counts the items of a push before handing them to the workers, a
%%% worker reports the messages it sends to another worker before
%%% sending them, and a worker reports the delivery of every event
%%% of its engine, see {@link report/3}. Since every worker reports
%%% in the order it delivers in, and a message sent on one node is
%%% in the mailbox of the receiver before the sender goes on, the
%%% coordinator never sees work released before it was counted. The
%%% latter holds on one node only: the runtime is not to be spread
%%% over several without another way to order the reports.
%%%
%%% A push is taken as long as fewer messages than the limit of the
%%% runtime are on their way, see {@link ari_progress:in_flight/1};
%%% otherwise it is put in line and answered once a report brings
%%% the messages on their way below the limit, the pushes in line
%%% taken in the order they came in, as many as there is room for.
%%% Whether the epoch is open is checked when the push is taken, so
%%% a push in line into an epoch closed meanwhile is refused. Closing
%%% never waits.
%%%
%%% A notification a worker asks for is remembered along with the
%%% worker, see {@link ari_asked}. Whenever the progress changes -- a
%%% delta is applied or an epoch is closed -- the coordinator tells
%%% the workers to deliver the notifications whose time is complete,
%%% the earliest times first. A notification of a vertex pending
%%% does not hold a later one of the vertex back (see {@link
%%% ari_progress:complete/3}): the two go out together, and the
%%% worker delivers them in the order told. Were the later one to
%%% wait for the report of the earlier, a vertex would get one
%%% notification per round.
%%%
%%% The coordinator is the last process of the branch to start. Once
%%% up, it finds the workers in the group `workers' of the scope of
%%% the runtime, asks every one of them its number and wires them
%%% together, see {@link ari_crt_worker:wire/3}. This is done before the
%%% first call is served, so a worker is wired before it is given any
%%% work.
%%%
%%% @private
%%% @end
%%%-------------------------------------------------------------------

-module(ari_crt_coordinator).

-behaviour(gen_server).

-export([
    start_link/4,
    push/4,
    close/3,
    report/3
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
    workers :: tuple() | undefined,
    %% The number of the worker the next item pushed goes to.
    next :: pos_integer(),
    %% How many messages may be on their way before a push waits.
    limit :: pos_integer() | infinity,
    %% The pushes waiting for room, the earliest first.
    waiting :: queue:queue(push()),
    %% The workers that asked for every notification not told to be
    %% delivered yet.
    asked :: ari_asked:t([pid()])
}).

%% A push waiting for room, with whom to answer.
-type push() ::
    {gen_server:from(), Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()]}.

%%--------------------------------------------------------------------
%% @doc
%% Starts the coordinator of the runtime `Name' of the graph of plan
%% `Plan' run by `Count' workers, with `Limit' messages allowed on
%% their way before a push waits. The coordinator joins the group
%% `coordinator' of the scope of the runtime.
%% @end
%%--------------------------------------------------------------------
-spec start_link(
    Name :: atom(), ari_plan:t(), Count :: pos_integer(), Limit :: pos_integer() | infinity
) -> {ok, pid()} | {error, term()}.
start_link(Name, Plan, Count, Limit) ->
    gen_server:start_link(?MODULE, {Name, Plan, Count, Limit}, []).

%%--------------------------------------------------------------------
%% @doc
%% Pushes the items `Messages' into the input `Input' at epoch
%% `Epoch', see {@link ari_concurrent_runtime:push/4}. Returns once
%% the items are counted and handed to the workers, which it waits
%% for as long as there is no room for them.
%%
%% Refuses with `{unknown_input, Input}' if the graph has no such
%% input and with `{closed, {Input, Epoch}}' if the epoch was closed;
%% the coordinator goes on.
%% @end
%%--------------------------------------------------------------------
-spec push(
    Coordinator :: pid(), Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()]
) -> ok | {error, ari_progress:refusal()}.
push(Coordinator, Input, Epoch, Messages) ->
    gen_server:call(Coordinator, {push, Input, Epoch, Messages}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input', see {@link
%% ari_concurrent_runtime:close/3}.
%%
%% Refuses with `{unknown_input, Input}' if the graph has no such
%% input; the coordinator goes on.
%% @end
%%--------------------------------------------------------------------
-spec close(Coordinator :: pid(), Input :: atom(), Epoch :: non_neg_integer()) ->
    ok | {error, ari_progress:refusal()}.
close(Coordinator, Input, Epoch) ->
    gen_server:call(Coordinator, {close, Input, Epoch}).

%%--------------------------------------------------------------------
%% @doc
%% Reports the sum `Sum' of the deltas of the deliveries the worker
%% `Worker' made, see {@link ari_progress:sum()}. The reports of a
%% worker are applied in the order they are made in.
%% @end
%%--------------------------------------------------------------------
-spec report(Coordinator :: pid(), Worker :: pid(), ari_progress:sum()) -> ok.
report(Coordinator, Worker, Sum) ->
    gen_server:cast(Coordinator, {delta, Worker, Sum}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Name, Plan, Count, Limit}) ->
    ok = pg:join(Name, coordinator, self()),
    Coordinator = #coordinator{
        name = Name,
        plan = Plan,
        progress = ari_progress:new(ari_plan:inputs(Plan)),
        count = Count,
        next = 1,
        limit = Limit,
        waiting = queue:new(),
        asked = ari_asked:new()
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
handle_call({push, Input, Epoch, Messages}, From, #coordinator{waiting = Waiting} = Coordinator) ->
    Push = {From, Input, Epoch, Messages},
    case queue:is_empty(Waiting) andalso room(Coordinator) of
        true ->
            {Reply, Coordinator2} = take(Push, Coordinator),
            {reply, Reply, Coordinator2};
        false ->
            {noreply, Coordinator#coordinator{waiting = queue:in(Push, Waiting)}}
    end;
handle_call({close, Input, Epoch}, _From, #coordinator{progress = Progress} = Coordinator) ->
    case ari_progress:close(Input, Epoch, Progress) of
        {ok, Closed} ->
            {reply, ok, dispatch(Coordinator#coordinator{progress = Closed})};
        {error, _Reason} = Error ->
            {reply, Error, Coordinator}
    end.

%% @private
handle_cast({delta, Worker, Sum}, Coordinator) ->
    #coordinator{progress = Progress, asked = Asked} = Coordinator,
    Applied = ari_progress:apply(Sum, Progress),
    Asked2 = maps:fold(
        fun
            ({{vertex, Vertex}, Time}, N, Acc) when N > 0 ->
                Workers =
                    case ari_asked:find(Vertex, Time, Acc) of
                        {value, Ws} -> Ws;
                        none -> []
                    end,
                ari_asked:add(Vertex, Time, [Worker | Workers], Acc);
            (_Pointstamp, _N, Acc) ->
                Acc
        end,
        Asked,
        Sum
    ),
    {noreply, dispatch(admit(Coordinator#coordinator{progress = Applied, asked = Asked2}))}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Whether there is room for a push: fewer messages than the limit
%% are on their way. A number is less than the atom `infinity'.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec room(#coordinator{}) -> boolean().
room(#coordinator{progress = Progress, limit = Limit}) ->
    ari_progress:in_flight(Progress) < Limit.

%%--------------------------------------------------------------------
%% @doc
%% Takes the push `Push': counts its items and hands them to the
%% workers, or refuses it, see {@link push/4}. Returns the reply due
%% to the pusher.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec take(push(), #coordinator{}) -> {ok | {error, ari_progress:refusal()}, #coordinator{}}.
take({_From, Input, Epoch, Messages}, #coordinator{progress = Progress} = Coordinator) ->
    case ari_progress:check_open(Input, Epoch, Progress) of
        ok ->
            Time = ari_vtime:new(Epoch),
            Counted =
                case length(Messages) of
                    0 -> Progress;
                    N -> ari_progress:apply(#{{{edge, Input}, Time} => N}, Progress)
                end,
            Next = feed(Input, Time, Messages, Coordinator),
            {ok, Coordinator#coordinator{progress = Counted, next = Next}};
        {error, _Reason} = Error ->
            {Error, Coordinator}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Takes the pushes waiting in line and answers them, the earliest
%% first, as long as there is room.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec admit(#coordinator{}) -> #coordinator{}.
admit(#coordinator{waiting = Waiting} = Coordinator) ->
    case queue:out(Waiting) of
        {{value, {From, _Input, _Epoch, _Messages} = Push}, Waiting2} ->
            case room(Coordinator) of
                true ->
                    {Reply, Coordinator2} = take(Push, Coordinator#coordinator{waiting = Waiting2}),
                    gen_server:reply(From, Reply),
                    admit(Coordinator2);
                false ->
                    Coordinator
            end;
        {empty, Waiting} ->
            Coordinator
    end.

%%--------------------------------------------------------------------
%% @doc
%% Hands the items `Messages' of time `Time' of the input `Input' to
%% the workers: each to the worker of its key if the input is
%% partitioned, one by one in turn otherwise, starting with the
%% worker next in turn. Every worker is given its items in the order
%% they were pushed in. Returns the number of the worker next in
%% turn.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec feed(Input :: atom(), ari_vtime:t(), Messages :: [term()], #coordinator{}) -> pos_integer().
feed(Input, Time, Messages, #coordinator{plan = Plan, workers = Workers, count = Count, next = Next}) ->
    {Batches, Next2} =
        case ari_plan:key(Plan, Input) of
            undefined -> in_turn(Messages, Next, Count, erlang:make_tuple(Count, []));
            _Key -> {by_key(Messages, Plan, Input, Count, #{}), Next}
        end,
    maps:foreach(
        fun
            (_N, []) -> ok;
            (N, Reversed) -> ari_crt_worker:feed(element(N, Workers), Input, Time, lists:reverse(Reversed))
        end,
        Batches
    ),
    Next2.

%%--------------------------------------------------------------------
%% @doc
%% Deals the items `Messages' to the `Count' workers one by one in
%% turn, starting with worker `Next', each worker's items the latest
%% first. Returns the items by the worker and the worker next in
%% turn.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec in_turn(Messages :: [term()], Next :: pos_integer(), Count :: pos_integer(), tuple()) ->
    {#{pos_integer() => [term()]}, pos_integer()}.
in_turn([], Next, _Count, Dealt) ->
    {maps:from_list(lists:zip(lists:seq(1, tuple_size(Dealt)), tuple_to_list(Dealt))), Next};
in_turn([Message | Messages], Next, Count, Dealt) ->
    Dealt2 = setelement(Next, Dealt, [Message | element(Next, Dealt)]),
    in_turn(Messages, Next rem Count + 1, Count, Dealt2).

%%--------------------------------------------------------------------
%% @doc
%% Deals the items `Messages' to the `Count' workers by their key,
%% see {@link ari_plan:partition/4}, each worker's items the latest
%% first.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec by_key(Messages :: [term()], ari_plan:t(), Input :: atom(), Count :: pos_integer(), Acc) ->
    Acc when Acc :: #{pos_integer() => [term()]}.
by_key([], _Plan, _Input, _Count, Dealt) ->
    Dealt;
by_key([Message | Messages], Plan, Input, Count, Dealt) ->
    Worker = ari_plan:partition(Plan, Input, Message, Count),
    by_key(Messages, Plan, Input, Count, Dealt#{Worker => [Message | maps:get(Worker, Dealt, [])]}).

%%--------------------------------------------------------------------
%% @doc
%% Tells the workers to deliver every notification asked for whose
%% time is complete, the earliest times first, and forgets those
%% notifications. A worker never asks for a notification again once
%% it was told to deliver it: a time complete for a vertex stays so.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec dispatch(#coordinator{}) -> #coordinator{}.
dispatch(#coordinator{plan = Plan, progress = Progress, asked = Asked} = Coordinator) ->
    Summaries = ari_plan:summaries(Plan),
    Complete = fun(Vertex, Time) -> ari_progress:complete(Summaries, {Vertex, Time}, Progress) end,
    {Due, Remaining} = ari_asked:due(Complete, Asked),
    lists:foreach(
        fun({Vertex, Time, Workers}) ->
            lists:foreach(fun(W) -> ari_crt_worker:notify(W, Vertex, Time) end, Workers)
        end,
        Due
    ),
    Coordinator#coordinator{asked = Remaining}.
