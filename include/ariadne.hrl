-ifndef(ARIADNE_HRL).
-define(ARIADNE_HRL, true).

-type name() :: atom().
-type slot() :: atom().

-record(node, {
    name,
    module,
    args,
    %% Охватывающие циклы, внутренний первым; заполняется при сборке графа.
    context = []
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
