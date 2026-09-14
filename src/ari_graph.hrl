-ifndef(ARI_GRAPH_HRL).
-define(ARI_GRAPH_HRL, true).

%% An operator of the graph.
-record(vertex, {
    name :: atom(),
    callback :: module(),
    args :: term(),
    scope = undefined :: atom()
}).

%% An endpoint of a channel: a slot of a vertex.
-type endpoint() :: {Vertex :: atom(), Slot :: atom()}.

%% A channel between two vertices of one and the same scope. An
%% endpoint left `undefined' is the outside world.
-record(edge, {
    name :: atom(),
    from = undefined :: endpoint() | undefined,
    to  = undefined :: endpoint() | undefined
}).

%% A channel leading into the scope `scope'.
-record(ingress, {
    name :: atom(),
    from :: endpoint(),
    to   :: endpoint(),
    scope :: atom()
}).

%% A channel leading out of the scope `scope'.
-record(egress, {
    name :: atom(),
    from :: endpoint(),
    to   :: endpoint(),
    scope :: atom()
}).

%% The back edge of the loop of the scope `scope'.
-record(feedback, {
    name :: atom(),
    from :: endpoint(),
    to   :: endpoint(),
    scope :: atom()
}).

%% A loop scope: a list of items of its own, built by ari_graph:loop/2.
-record(scope, {
    name :: atom(),
    items :: [term()]
}).

%% A channel of any kind.
-type edge() :: #edge{} | #ingress{} | #egress{} | #feedback{}.

%% A logical graph with every scope unfolded.
-record(graph, {
    nodes :: [#vertex{}],
    edges :: [edge()]
}).

-endif.
