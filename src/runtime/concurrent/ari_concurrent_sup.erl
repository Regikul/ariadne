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
%% `Name' and run by `Workers' workers, see {@link ari_concurrent_runtime:child_spec/3}.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name :: atom(), Graph :: #graph{}, Workers :: pos_integer()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Graph, Workers) ->
    supervisor:start_link(?MODULE, {Name, Graph, Workers}).

%% @private
-spec init({Name :: atom(), #graph{}, Workers :: pos_integer()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, Graph, Count}) ->
    Plan = ari_plan:prepare(Graph),
    Scope = #{
        id => pg,
        start => {pg, start_link, [Name]}
    },
    Workers = [
        #{
            id => {worker, Index},
            start => {ari_crt_worker, start_link, [Name, Index, Plan]}
        }
     || Index <- lists:seq(1, Count)
    ],
    Coordinator = #{
        id => coordinator,
        start => {ari_crt_coordinator, start_link, [Name, Plan, Count]}
    },
    Flags = #{strategy => one_for_all, intensity => 0, period => 1},
    {ok, {Flags, [Scope | Workers] ++ [Coordinator]}}.
