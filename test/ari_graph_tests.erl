%% @doc Проверяет конструкторы и структурные инварианты графового DSL.
-module(ari_graph_tests).

-include("ariadne.hrl").
-include_lib("eunit/include/eunit.hrl").

constructors_test() ->
    ?assertEqual(
        #node{name = a, module = ari_test_node, args = #{}},
        ari_graph:node(a, ari_test_node, #{})
    ),
    ?assertEqual(
        #edge{name = input, to = {a, input}},
        ari_graph:in(input, {a, input})
    ),
    ?assertEqual(
        #edge{name = a_to_b, from = {a, output}, to = {b, input}},
        ari_graph:edge(a_to_b, {a, output}, {b, input})
    ),
    ?assertEqual(
        #edge{name = output, from = {b, output}},
        ari_graph:out(output, {b, output})
    ),
    ?assertEqual(
        #feedback{name = next, from = {b, output}, to = {a, input}},
        ari_graph:feedback(next, {b, output}, {a, input})
    ),
    Items = [ari_graph:node(a, ari_test_node, #{})],
    ?assertEqual(
        #loop{name = iteration, items = Items},
        ari_graph:loop(iteration, Items)
    ).

graph_test() ->
    Nodes = [
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:node(b, ari_test_node, #{})
    ],
    Edges = [
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:out(output, {b, output})
    ],
    ?assertEqual(#graph{nodes = Nodes, edges = Edges}, ari_graph:graph(Nodes ++ Edges)).

unknown_node_test() ->
    ?assertError(
        {invalid_graph, {unknown_node, input, missing}},
        ari_graph:graph([
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:in(input, {missing, input})
        ])
    ).

duplicate_edge_test() ->
    ?assertError(
        {invalid_graph, {duplicate, edge, same}},
        ari_graph:graph([
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:in(same, {a, input}),
            ari_graph:out(same, {a, output})
        ])
    ).

cycle_test() ->
    ?assertError(
        {invalid_graph, cycle},
        ari_graph:graph([
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:node(b, ari_test_node, #{}),
            ari_graph:edge(a_to_b, {a, output}, {b, input}),
            ari_graph:edge(b_to_a, {b, output}, {a, input})
        ])
    ).

loop_test() ->
    InnerNodes = [
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:node(b, ari_test_node, #{})
    ],
    Loop = ari_graph:loop(iteration, InnerNodes ++ [
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:feedback(next, {b, output}, {a, input}),
        ari_graph:out(output, {b, output})
    ]),
    OuterNodes = [
        ari_graph:node(source, ari_test_node, #{}),
        ari_graph:node(sink, ari_test_node, #{})
    ],
    Graph = ari_graph:graph(OuterNodes ++ [
        ari_graph:out(input, {source, output}),
        Loop,
        ari_graph:in(output, {sink, input})
    ]),
    ?assertEqual(
        #graph{
            nodes = OuterNodes ++ InnerNodes,
            edges = [
                #ingress{
                    name = input,
                    loop = iteration,
                    from = {source, output},
                    to = {a, input}
                },
                #edge{name = a_to_b, from = {a, output}, to = {b, input}},
                #feedback{
                    name = next,
                    loop = iteration,
                    from = {b, output},
                    to = {a, input}
                },
                #egress{
                    name = output,
                    loop = iteration,
                    from = {b, output},
                    to = {sink, input}
                }
            ]
        },
        Graph
    ).

unmatched_loop_edge_test() ->
    ?assertError(
        {invalid_graph, {unmatched_loop_edge, iteration, input, input}},
        ari_graph:graph([
            ari_graph:loop(iteration, [
                ari_graph:node(a, ari_test_node, #{}),
                ari_graph:in(input, {a, input})
            ])
        ])
    ).

feedback_outside_loop_test() ->
    ?assertError(
        {invalid_graph, {feedback_outside_loop, next}},
        ari_graph:graph([
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:node(b, ari_test_node, #{}),
            ari_graph:feedback(next, {b, output}, {a, input})
        ])
    ).
