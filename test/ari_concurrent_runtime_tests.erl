-module(ari_concurrent_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

%%%===================================================================
%%% The branch
%%%===================================================================

the_branch_starts_a_scope_with_the_workers_and_the_coordinator_test() ->
    Sup = start(scoped, chain(), 2),
    ?assertEqual(2, length(pg:get_local_members(scoped, workers))),
    ?assertMatch([_], pg:get_local_members(scoped, coordinator)),
    stop(Sup).

the_workers_are_numbered_test() ->
    Sup = start(numbered, chain(), 3),
    Workers = pg:get_local_members(numbered, workers),
    ?assertEqual([1, 2, 3], lists:sort([ari_crt_worker:index(W) || W <- Workers])),
    stop(Sup).

stopping_the_branch_terminates_every_vertex_of_every_worker_test() ->
    Sup = start(terminating, reporting(self()), 2),
    stop(Sup),
    ?assertEqual([reporter, reporter], receive_all(terminated)).

the_branch_is_embedded_by_its_child_spec_test() ->
    {ok, Sup} = supervisor:start_link(?MODULE, chain()),
    ?assertMatch([_], pg:get_local_members(embedded, workers)),
    ?assertMatch([_], pg:get_local_members(embedded, coordinator)),
    stop(Sup).

the_branch_refuses_a_broken_graph_test() ->
    process_flag(trap_exit, true),
    Broken = ari_graph:graph([
        ari_graph:in(input, {nowhere, in})
    ]),
    ?assertMatch({error, {{unknown_vertex, {input, nowhere}}, _}}, ari_concurrent_sup:start_link(broken, Broken, 1)).

%%%===================================================================
%%% The calls
%%%===================================================================

a_call_to_a_runtime_not_running_fails_test() ->
    ?assertError({not_running, nobody}, ari_concurrent_runtime:push(nobody, input, 0, [a])).

the_calls_reach_the_coordinator_test() ->
    Sup = start(called, chain(), 1),
    ?assertEqual(ok, ari_concurrent_runtime:push(called, input, 0, [a])),
    ?assertEqual(ok, ari_concurrent_runtime:close(called, input, 0)),
    stop(Sup).

subscribing_joins_the_group_of_the_output_test() ->
    Sup = start(subscribed, chain(), 1),
    ok = ari_concurrent_runtime:subscribe(subscribed, output),
    ?assertEqual([self()], pg:get_local_members(subscribed, {output, output})),
    stop(Sup).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% The supervisor the branch is embedded into by
%% the_branch_is_embedded_by_its_child_spec_test.
init(Graph) ->
    Flags = #{strategy => one_for_one, intensity => 0, period => 1},
    {ok, {Flags, [ari_concurrent_runtime:child_spec(embedded, Graph, 1)]}}.

start(Name, Graph, Workers) ->
    {ok, Sup} = ari_concurrent_sup:start_link(Name, Graph, Workers),
    Sup.

%% Shuts the branch down the way a supervisor above would.
stop(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, shutdown} -> ok
    end.

%% Everything received under the tag `Tag' so far.
receive_all(Tag) ->
    receive
        {Tag, Value} -> [Value | receive_all(Tag)]
    after 0 ->
        []
    end.

%% Two passing vertices one after the other.
chain() ->
    ari_graph:graph([
        ari_graph:in(input, {first, in}),
        ari_graph:node(first, ari_test_pass, []),
        ari_graph:edge(link, {first, out}, {second, in}),
        ari_graph:node(second, ari_test_pass, []),
        ari_graph:out(output, {second, out})
    ]).

%% A vertex reporting its termination to `Pid'.
reporting(Pid) ->
    ari_graph:graph([
        ari_graph:in(input, {reporter, in}),
        ari_graph:node(reporter, ari_test_reporter, {reporter, Pid}),
        ari_graph:out(output, {reporter, out})
    ]).
