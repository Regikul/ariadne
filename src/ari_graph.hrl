-ifndef(ARI_GRAPH_HRL).
-define(ARI_GRAPH_HRL, true).

%% An operator of the graph.
-record(vertex, {
    name :: atom(),
    callback :: module(),
    args :: term(),
    scope = undefined :: atom()
}).

%% A channel between two vertices of one and the same scope. An end
%% left `undefined' is the outside world.
-record(edge, {
    name :: atom(),
    from = undefined :: ari_graph:edge_end() | undefined,
    to  = undefined :: ari_graph:edge_end() | undefined
}).

%% A channel leading into the scope `scope'.
-record(ingress, {
    name :: atom(),
    from :: ari_graph:edge_end(),
    to   :: ari_graph:edge_end(),
    scope :: atom()
}).

%% A channel leading out of the scope `scope'.
-record(egress, {
    name :: atom(),
    from :: ari_graph:edge_end(),
    to   :: ari_graph:edge_end(),
    scope :: atom()
}).

%% The back edge of the loop of the scope `scope'.
-record(feedback, {
    name :: atom(),
    from :: ari_graph:edge_end(),
    to   :: ari_graph:edge_end(),
    scope :: atom()
}).

%% A loop scope: a list of items of its own, built by ari_graph:loop/2.
-record(scope, {
    name :: atom(),
    items :: [term()]
}).

%% A logical graph with every scope unfolded.
-record(graph, {
    nodes :: [#vertex{}],
    edges :: [#edge{} | #ingress{} | #egress{} | #feedback{}]
}).

-endif.
