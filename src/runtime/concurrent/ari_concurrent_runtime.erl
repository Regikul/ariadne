%%%-------------------------------------------------------------------
%%% @doc
%%% Runtime of a dataflow graph in several processes.
%%%
%%% The runtime is a branch of a supervision tree (see {@link
%%% ari_concurrent_sup}): a number of workers, each running a copy of
%%% the graph (see {@link ari_crt_worker}), a coordinator keeping the
%%% progress of the graph as a whole (see {@link ari_crt_coordinator}),
%%% and a `pg' scope of its own the processes find each other in.
%%% The branch is embedded into the supervision tree of the
%%% application using it, see {@link child_spec/3}, and is known by
%%% the name of its scope: every call of this module takes the name.
%%%
%%% ```
%%% %% in the supervisor of the application:
%%% ari_concurrent_runtime:child_spec(counting, Graph, 4),
%%%
%%% %% in the process feeding the graph:
%%% ok = ari_concurrent_runtime:subscribe(counting, done),
%%% ok = ari_concurrent_runtime:push(counting, input, 0, [A, B]),
%%% ok = ari_concurrent_runtime:close(counting, input, 0),
%%% receive {ariadne, counting, done, Message, Time} -> ... end.
%%% '''
%%%
%%% The inputs are fed as in {@link ari_single_runtime}: items enter
%%% in epochs, and an epoch is closed once no more items of it are to
%%% come. The items of an input are spread over the workers, so the
%%% order they were pushed in is kept by every worker on its own. The
%%% outputs are delivered as messages to the processes subscribed to
%%% them, see {@link subscribe/2}; the items of every worker come in
%%% the order they left in, and the workers are not ordered.
%%%
%%% Every worker runs the whole graph, so a vertex keeping state sees
%%% the items of its own worker only, unless the edge leading to it
%%% is partitioned by a key (see `edge_opts()' in `ari_graph.hrl'):
%%% the items of one key are then handed to one and the same worker,
%%% whichever worker they came up on. An input partitioned by a key
%%% is spread by the key rather than in turn. The order kept is that
%%% of the items one worker hands to another.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_concurrent_runtime).

-include("ari_graph.hrl").

-export([
    child_spec/3,
    push/4,
    close/3,
    subscribe/2
]).

%%--------------------------------------------------------------------
%% @doc
%% The child specification of a runtime of the graph `Graph' named
%% `Name' and run by `Workers' workers, to be put under a supervisor
%% of the application. The name is the name of the `pg' scope of the
%% runtime, so one name serves one runtime on a node. The graph is
%% prepared when the branch starts, see {@link ari_plan:prepare/1},
%% whose errors the start fails with.
%% @end
%%--------------------------------------------------------------------
-spec child_spec(Name :: atom(), Graph :: #graph{}, Workers :: pos_integer()) ->
    supervisor:child_spec().
child_spec(Name, Graph, Workers) ->
    #{
        id => Name,
        start => {ari_concurrent_sup, start_link, [Name, Graph, Workers]},
        type => supervisor,
        shutdown => infinity
    }.

%%--------------------------------------------------------------------
%% @doc
%% Pushes the items `Messages' into the input `Input' of the runtime
%% `Name' at epoch `Epoch'. The items are spread over the workers and
%% delivered in the order given by every worker; the call returns
%% once they are handed over.
%%
%% Refuses with `{unknown_input, Input}' if the graph has no such
%% input and with `{closed, {Input, Epoch}}' if the epoch was closed.
%% @end
%%--------------------------------------------------------------------
-spec push(Name :: atom(), Input :: atom(), Epoch :: non_neg_integer(), Messages :: [term()]) ->
    ok | {error, ari_progress:refusal()}.
push(Name, Input, Epoch, Messages) ->
    ari_crt_coordinator:push(coordinator(Name), Input, Epoch, Messages).

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input' of the
%% runtime `Name': no more items of those epochs are to be pushed,
%% and the times they contribute to may complete. Closing an epoch
%% that is closed already changes nothing.
%%
%% Refuses with `{unknown_input, Input}' if the graph has no such
%% input.
%% @end
%%--------------------------------------------------------------------
-spec close(Name :: atom(), Input :: atom(), Epoch :: non_neg_integer()) ->
    ok | {error, ari_progress:refusal()}.
close(Name, Input, Epoch) ->
    ari_crt_coordinator:close(coordinator(Name), Input, Epoch).

%%--------------------------------------------------------------------
%% @doc
%% Subscribes the calling process to the output `Output' of the
%% runtime `Name': every item leaving the graph through the output
%% is sent to it as `{ariadne, Name, Output, Message, Time}'. Items
%% of an output nobody is subscribed to are dropped.
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Name :: atom(), Output :: atom()) -> ok.
subscribe(Name, Output) ->
    pg:join(Name, {output, Output}, self()).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% The coordinator of the runtime `Name'. Exits with `{not_running,
%% Name}' if there is none.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec coordinator(Name :: atom()) -> pid().
coordinator(Name) ->
    case pg:get_local_members(Name, coordinator) of
        [Coordinator] -> Coordinator;
        [] -> exit({not_running, Name})
    end.
