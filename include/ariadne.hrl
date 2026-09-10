-ifndef(ARIADNE_HRL).
-define(ARIADNE_HRL, true).

-type slot() :: atom().

-record(node, {
    name,
    module,
    args
}).

-record(edge, {
    name,
    from = undefined,
    to = undefined
}).

-record(ingress, {
    name,
    loop,
    from,
    to
}).

-record(egress, {
    name,
    loop,
    from,
    to
}).

-record(feedback, {
    name,
    loop = undefined,
    from,
    to
}).

-record(loop, {
    name,
    items = []
}).

-record(graph, {
    nodes = [],
    edges = []
}).

-endif.
