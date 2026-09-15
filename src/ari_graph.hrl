-ifndef(ARI_GRAPH_HRL).
-define(ARI_GRAPH_HRL, true).

%% An operator of the graph.
-record(vertex, {
    name :: atom(),
    module :: module(),
    args :: term(),
    scope = undefined :: atom()
}).

%% An endpoint of a channel: a slot of a vertex.
-type endpoint() :: {Vertex :: atom(), Slot :: atom()}.

%% The options of a channel. `key' partitions the items of the
%% channel: items of one and the same key are delivered to one and
%% the same copy of the vertex the channel leads to, however many
%% copies of the graph the runtime runs.
-type edge_opts() :: #{key => fun((Message :: term()) -> Key :: term())}.

%% A channel between two vertices of one and the same scope. An
%% endpoint left `undefined' is the outside world.
-record(edge, {
    name :: atom(),
    from = undefined :: endpoint() | undefined,
    to  = undefined :: endpoint() | undefined,
    opts = #{} :: edge_opts()
}).

%% A channel leading into the scope `scope'. A start left `undefined'
%% is the outside world.
-record(ingress, {
    name :: atom(),
    from :: endpoint() | undefined,
    to   :: endpoint(),
    scope :: atom(),
    opts = #{} :: edge_opts()
}).

%% A channel leading out of the scope `scope'. An end left `undefined'
%% is the outside world.
-record(egress, {
    name :: atom(),
    from :: endpoint(),
    to   :: endpoint() | undefined,
    scope :: atom(),
    opts = #{} :: edge_opts()
}).

%% The back edge of the loop of the scope `scope'.
-record(feedback, {
    name :: atom(),
    from :: endpoint(),
    to   :: endpoint(),
    scope :: atom(),
    opts = #{} :: edge_opts()
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
