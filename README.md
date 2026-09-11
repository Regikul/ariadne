# Ariadne

Ariadne is an Erlang implementation of timely dataflow, following the model
formalized by Martín Abadi and Michael Isard in
[*Timely Dataflow: A Model*](okf/references/papers/timely-dataflow-a-model.md)
(the paper is also kept as a [PDF](okf/references/papers/timely-dataflow-a-model.pdf)).

## What it is

Picture a streaming computation as a graph: boxes that keep some state,
arrows that carry messages between them. Data flows in, gets transformed
box by box, and flows out. Plain dataflow, nothing new.

Now add the question every stateful stream processor eventually has to
answer: *"I have been summing up the events of the last hour — is the hour
over yet?"* Batch systems know because the input ends. Streaming systems
usually guess: wait a bit longer, hope nothing is late, or bolt on
watermarks by hand.

Timely dataflow answers the question exactly. Every message carries a
logical time — the epoch it belongs to, plus one extra coordinate for each
loop it is travelling around. A node can say to the runtime: *"tell me when
time 5 is done."* The runtime tracks what is still in flight and where it
can go, and delivers that notification the moment nothing in the graph could
ever produce another message for time 5 at that node. No timeouts, no
guessing, and it works inside loops too: a node in a loop learns when an
iteration is complete, so iterative algorithms run on streams without
leaving the graph.

Ariadne turns this model into an Erlang library. You describe the graph in
a small DSL, write the nodes as callback modules, feed the input and run it.
The current runtime, `ari_local_runtime`, executes the whole graph inside
one Erlang process, one message or one notification per atomic step, until
the graph goes quiet or a step budget runs out. It is meant as the
reference: distributing nodes across processes is the next step and must
not change what the graph observes — the order on an edge, the results of
the nodes and the moment a notification becomes admissible.

## Example

A node that counts words per epoch and emits the totals of an epoch once no
more words of that epoch can arrive:

```erlang
-module(tally).
-behaviour(ariadne_node).
-export([input/0, output/0, init/1, handle_message/4, handle_notification/2]).

input() -> [words].
output() -> [totals].

init(_Args) ->
    {#{}, []}.

%% Count the word and ask to be notified when its epoch is complete.
handle_message(words, Word, Time, Counts) ->
    Tally = maps:get(Time, Counts, #{}),
    Counts1 = Counts#{Time => maps:update_with(Word, fun(N) -> N + 1 end, 1, Tally)},
    {Counts1, [Time], []}.

%% No message with this time can arrive any more: emit the totals.
handle_notification(Time, Counts) ->
    {Tally, Counts1} = maps:take(Time, Counts),
    {Counts1, [], [{totals, Tally, Time}]}.
```

A graph with this node, an input half-edge feeding it and an output
half-edge collecting the totals:

```erlang
Graph = ari_graph:graph([
    ari_graph:node(tally, tally, #{}),
    ari_graph:in(words, {tally, words}),
    ari_graph:out(totals, {tally, totals})
]),

{ok, Program} = ari_local_runtime:compile(Graph),
T1 = ari_vtime:new(1),
T2 = ari_vtime:new(2),
{ok, Execution} = ari_local_runtime:new(Program, [
    {words, [{cat, T1}, {dog, T1}, {cat, T1}, {dog, T2}]}
]),
{done, Done} = ari_local_runtime:advance(Execution, infinity),
ari_local_runtime:outputs(Done).
%% #{totals => [{#{cat => 2, dog => 1}, {1, []}}, {#{dog => 1}, {2, []}}]}
```

The epoch 1 totals appear only after all three epoch 1 words have been
counted, and the epoch 2 total after the last word.

## Documentation

Design decisions live in the [OKF knowledge base](okf/index.md):
the [graph DSL](okf/design/graph-dsl.md), the [node contract](okf/design/node.md),
[logical time](okf/design/time.md), the [local runtime](okf/design/local-runtime.md)
and its [performance measurements](okf/design/local-runtime-performance.md).

## Build

```console
./silent_rebar3 compile
./silent_rebar3 test        # eunit and coverage
./silent_rebar3 dialyzer
```
