%%%-------------------------------------------------------------------
%%% @doc
%%% Supervisor of a runtime of a dataflow graph in several processes,
%%% see {@link ari_concurrent_runtime}.
%%%
%%% The branch is the `pg' scope named after the runtime, the workers
%%% and, last, the coordinator. The processes are wired to each other
%%% once the coordinator is up: it finds the workers in the scope and
%%% tells every one of them where the others are, see {@link
%%% ari_crt_coordinator}. The branch stands or falls as a whole: if any
%%% of its processes fails, the branch stops without restarting, and
%%% the supervisor above decides what to do about it.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_concurrent_sup).

-behaviour(supervisor).

-include("ari_graph.hrl").

-export([
    start_link/3
]).

-export([
    init/1
]).

%%--------------------------------------------------------------------
%% @doc
%% Starts the branch of the runtime of the graph `Graph' named
%% `Name' with the options `Opts', see {@link
%% ari_concurrent_runtime:child_spec/3}.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name :: atom(), Graph :: #graph{}, ari_concurrent_runtime:opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Graph, Opts) ->
    supervisor:start_link(?MODULE, {Name, Graph, Opts}).

%% @private
-spec init({Name :: atom(), #graph{}, ari_concurrent_runtime:opts()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, Graph, Opts}) ->
    {Count, Limit} = options(Opts),
    Plan = ari_plan:prepare(Graph),
    Scope = #{
        id => pg,
        start => {pg, start_link, [Name]}
    },
    Workers = [
        #{
            id => {worker, Index},
            start => {ari_crt_worker, start_link, [Name, Index, Count, Plan]}
        }
     || Index <- lists:seq(1, Count)
    ],
    Coordinator = #{
        id => coordinator,
        start => {ari_crt_coordinator, start_link, [Name, Plan, Count, Limit]}
    },
    Flags = #{strategy => one_for_all, intensity => 0, period => 1},
    {ok, {Flags, [Scope | Workers] ++ [Coordinator]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% The number of workers and the limit of the messages on their way
%% out of the options `Opts'. Fails with `{bad_option, Option}' on
%% an option that is not what {@link ari_concurrent_runtime:opts()}
%% says.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec options(ari_concurrent_runtime:opts()) ->
    {Count :: pos_integer(), Limit :: pos_integer() | infinity}.
options(Opts) ->
    Count = maps:get(workers, Opts, undefined),
    is_integer(Count) andalso Count >= 1 orelse error({bad_option, {workers, Count}}),
    Limit = maps:get(max_in_flight, Opts, infinity),
    Limit =:= infinity orelse (is_integer(Limit) andalso Limit >= 1) orelse
        error({bad_option, {max_in_flight, Limit}}),
    {Count, Limit}.
