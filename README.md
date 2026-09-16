# Ariadne

Ariadne is an Erlang library for running stateful dataflow graphs. A graph connects callback modules called *vertices* with directed edges. Items enter through named inputs, move between vertex slots, and leave through named outputs.

Ariadne provides two runtimes:

- `ari_single_runtime` is an immutable value advanced explicitly by the caller. It is useful for deterministic execution, tests, and embedding in another process.
- `ari_concurrent_runtime` runs several copies of a graph in supervised worker processes. It is useful when independent items or keys can be processed in parallel.

The runtime assigns every item a virtual timestamp. Timestamps let a stateful vertex request a notification when an epoch or loop iteration is complete.

## Requirements

- Erlang/OTP 23 or later
- Rebar3

Add Ariadne to the consuming project's `rebar.config`, pinned to a release tag:

```erlang
{deps, [
    {ariadne, {git, "https://github.com/regikul/ariadne.git", {tag, "v0.1.0"}}}
]}.
```

Build and test the library with:

```console
$ rebar3 compile
$ rebar3 eunit
```

## Quick start

### 1. Implement a vertex

A vertex declares named input and output slots and implements the `ariadne_vertex` behaviour. This vertex applies a function to every item:

```erlang
-module(ariadne_example_map).
-behaviour(ariadne_vertex).

-export([
    inputs/0,
    outputs/0,
    init/1,
    handle_message/4,
    handle_notification/2,
    terminate/1
]).

inputs() -> [in].
outputs() -> [out].

init(Fun) when is_function(Fun, 1) -> Fun.

handle_message(in, Item, Time, Fun) ->
    {Fun, [], [{out, Fun(Item), Time}]}.

handle_notification(_Time, Fun) ->
    {Fun, []}.

terminate(_Fun) -> ok.
```

The repository contains this callback as [`ariadne_example_map`](examples/ariadne_example_map.erl).

### 2. Build a graph

```erlang
Graph = ari_graph:graph([
    ari_graph:in(input, {double, in}),
    ari_graph:node(double, ariadne_example_map, fun(N) -> N * 2 end),
    ari_graph:out(mapped, {double, out}),
    ari_graph:edge(to_sum, {double, out}, {sum, in}),
    ari_graph:node(sum, ariadne_example_sum, []),
    ari_graph:out(total, {sum, out})
]).
```

In this graph, `input` names the external point through which items enter. The `double` vertex sends each result both to the external point `mapped` and along `to_sum` to the `sum` vertex. The sum leaves through the external point `total`. Tuples such as `{double, in}` and `{sum, out}` identify vertex slots.

The [`ariadne_example_sum`](examples/ariadne_example_sum.erl) vertex stores a running total for each timestamp and requests a completion notification. It emits the total from `handle_notification/2`, after the corresponding input epoch closes.

`ari_graph:graph/1` builds the graph description. A runtime validates vertex names, slots, scopes, options, and cycles when it prepares the graph.

### 3. Run it in one process

```erlang
R0 = ari_single_runtime:new(Graph),
R1 = ari_single_runtime:push(input, 0, [1, 2, 3], R0),
R2 = ari_single_runtime:run(R1),
{[{2, _}, {4, _}, {6, _}], R3} = ari_single_runtime:pull(mapped, R2),
{[], R4} = ari_single_runtime:pull(total, R3),

R5 = ari_single_runtime:close(input, 0, R4),
R6 = ari_single_runtime:run(R5),
{[{12, _}], R7} = ari_single_runtime:pull(total, R6),
ok = ari_single_runtime:stop(R7).
```

Every operation returns a new runtime. `push/4` queues items, `close/3` declares that the input will receive no more items through the given epoch, and `run/1` delivers queued messages and complete notifications until the runtime becomes idle. `pull/2` removes the accumulated items from an output.

The `mapped` output is available before the epoch closes because the map handles one item at a time. The `total` output remains empty until `close/3` lets the runtime deliver the sum vertex's completion notification.

## Graphs and vertices

A graph description contains these items:

| Function | Meaning |
| --- | --- |
| `ari_graph:node/3` | Adds a named vertex and its initialization argument. |
| `ari_graph:in/2,3` | Connects a named graph input to an input slot. |
| `ari_graph:edge/3,4` | Connects an output slot to an input slot. |
| `ari_graph:out/2` | Connects an output slot to a named graph output. |
| `ari_graph:loop/2` | Places graph items inside a loop scope. |
| `ari_graph:feedback/3,4` | Connects one iteration of a loop to the next. |

Vertex names, edge names, and loop-scope names must be unique within their respective namespaces. A start endpoint is always an output slot; an end endpoint is always an input slot.

Several edges may leave one output slot. The runtime copies each returned message onto every attached edge. Several edges may enter one input slot; the vertex receives their items as one stream.

An unattached output slot drops its messages. An unattached input slot remains silent.

### Callback contract

`handle_message/4` returns:

```erlang
{NewState,
 Notifications,
 [{OutputSlot, Item, Timestamp}]}
```

`Notifications` lists timestamps at which the vertex wants `handle_notification/2` to run. A map or filter normally returns an empty list. An aggregation normally stores partial state, requests the current timestamp, and emits its result from `handle_notification/2`.

`handle_notification/2` returns:

```erlang
{NewState,
 [{OutputSlot, Item, Timestamp}]}
```

A vertex may emit only the timestamp currently being handled or a later timestamp at the same loop depth. The runtime rejects messages and notification requests in the past. It also rejects messages sent through undeclared output slots.

The runtime preserves the order of messages returned by one callback on each edge.

## Epochs and completion

The `Epoch` argument of `push` is a non-negative batch number. Each graph input initially accepts epoch `0` and every later epoch.

```erlang
R1 = ari_single_runtime:push(input, 0, FirstBatch, R0),
R2 = ari_single_runtime:push(input, 1, SecondBatch, R1),
R3 = ari_single_runtime:close(input, 0, R2).
```

`close(input, 0, ...)` closes epoch `0` of that input and leaves epoch `1` open. Closing epoch `N` closes every epoch through `N`. A later push to a closed epoch fails.

A notification becomes eligible when all work that could still reach its vertex at that timestamp or an earlier one has completed. Open inputs count as possible future work. A graph with several inputs may therefore require the corresponding epoch to be closed on every contributing input.

## Loops

`ari_graph:loop/2` creates a timestamp scope. Items enter at iteration `0`; a `feedback` edge increments the loop counter; leaving the scope removes that counter.

```erlang
ari_graph:loop(retry, [
    ari_graph:node(attempt, attempt_callback, Args),
    ari_graph:feedback(again, {attempt, retry}, {attempt, in})
])
```

Every cycle must advance virtual time. In practice, a loop cycle must contain the appropriate feedback edge. Runtime preparation rejects a non-advancing cycle with `{non_advancing_cycle, Location}`.

## Choosing a runtime

| Property | `ari_single_runtime` | `ari_concurrent_runtime` |
| --- | --- | --- |
| Ownership | An immutable value held by the caller | A branch in an OTP supervision tree |
| Execution | Caller invokes `step/1` or `run/1` | Workers execute automatically |
| Results | Caller invokes `pull/2` | Subscribers receive Erlang messages |
| Parallelism | One graph copy | Configurable worker count |
| Ordering | One queue preserves delivery order | Each worker preserves its order; workers have no global order |
| Shutdown | Caller invokes `stop/1` | Parent supervisor stops the runtime branch |

Use the single runtime when explicit scheduling or reproducible execution is valuable. Use the concurrent runtime when the graph can benefit from parallel workers and its supervision lifecycle belongs to an OTP application.

## Concurrent runtime

Add a runtime to a supervisor with its child specification:

```erlang
Children = [
    ari_concurrent_runtime:child_spec(
        orders,
        Graph,
        #{workers => 4, max_in_flight => 10_000}
    )
].
```

Subscribe before pushing items so the subscriber observes every output:

```erlang
ok = ari_concurrent_runtime:subscribe(orders, output),
ok = ari_concurrent_runtime:push(orders, input, 0, [1, 2, 3]),
ok = ari_concurrent_runtime:close(orders, input, 0),

receive
    {ariadne, orders, output, Item, Time} ->
        handle(Item, Time)
end.
```

The name `orders` identifies one runtime on the local node.

### Options

| Option | Required | Default | Meaning |
| --- | --- | --- | --- |
| `workers` | yes | — | Positive number of worker processes and graph copies. |
| `max_in_flight` | no | `infinity` | Positive threshold at which later pushes wait for outstanding messages to drain. |
| `max_heap_size` | no | not set | Integer or map passed to the workers' `max_heap_size` process flag. |

A push is admitted as one batch when the current in-flight count is below `max_in_flight`. The runtime does not split the batch, so accepting `Messages` may raise the count to at most `max_in_flight - 1 + length(Messages)`. `close/3` does not wait for capacity.

`max_in_flight` limits work entering through pushes. It does not bound messages produced inside the graph, loop iterations, vertex state, or subscriber mailboxes. Use `max_heap_size` as a worker fuse for graphs that may grow without bound.

For a high-volume subscriber, consider setting `message_queue_data` to `off_heap` and process output messages promptly.

### Partitioning by key

Without a key, an input distributes items among workers in turn. Each worker preserves the order of the items it receives; output from different workers has no global order.

Attach a key function to an input or internal edge when all items for one key must reach the same graph copy:

```erlang
ari_graph:in(
    input,
    {aggregate, in},
    #{key => fun(Order) -> maps:get(customer_id, Order) end}
)
```

The runtime evaluates the function for each item and assigns equal keys to the same worker. Changing the worker count may change the assignment.

## Errors and lifecycle

The two runtimes report input errors differently:

| Condition | Single runtime | Concurrent runtime |
| --- | --- | --- |
| Unknown input | raises `error({unknown_input, Input})` | returns `{error, {unknown_input, Input}}` |
| Push to a closed epoch | raises `error({closed, {Input, Epoch}})` | returns `{error, {closed, {Input, Epoch}}}` |
| Unknown output | `pull/2` raises `error({unknown_output, Output})` | Subscribers to an unused name receive no items |
| Runtime is not running | not applicable | the call exits with `{not_running, Name}` |

Graph validation and vertex initialization happen in `ari_single_runtime:new/1` or when the concurrent supervision branch starts. The single runtime raises validation errors such as `duplicate_vertex`, `unknown_slot`, or `non_advancing_cycle`. An invalid concurrent child fails to start and reports the validation error to its parent supervisor.

`ari_single_runtime:stop/1` invokes `terminate/1` on every vertex. In the concurrent runtime, stopping the supervision branch terminates every worker and its vertex copies. If one process in the branch fails, the whole branch stops and the parent supervisor applies its restart strategy.

## Public API

- `ari_graph` builds graph descriptions.
- `ariadne_vertex` defines the vertex callback contract.
- `ari_single_runtime` executes a graph as a value.
- `ari_concurrent_runtime` executes graph copies under a supervisor.
- `ari_vtime` defines virtual timestamps and their order.

Other `ari_*` modules implement planning, progress tracking, and concurrent coordination. They are internal and may change without preserving their API.

Generate the API reference with:

```console
$ rebar3 edoc
```

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
