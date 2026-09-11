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
        {invalid_graph, {cycle_without_feedback, graph}},
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
            nodes = OuterNodes ++ [Node#node{context = [iteration]} || Node <- InnerNodes],
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

loop_reentry_without_outer_feedback_test() ->
    ?assertError(
        {invalid_graph, {cycle_without_feedback, graph}},
        ari_graph:graph(reentry_items())
    ).

nested_loop_reentry_without_outer_feedback_test() ->
    ?assertError(
        {invalid_graph, {cycle_without_feedback, {loop, outer}}},
        ari_graph:graph([ari_graph:loop(outer, reentry_items())])
    ).

%% Feedback внутреннего цикла не разрешает обход на уровне его родителя.
reentry_items() ->
    [
        ari_graph:node(d, ari_test_node, #{}),
        ari_graph:in(leave, {d, input}),
        ari_graph:out(enter, {d, output}),
        ari_graph:loop(inner, [
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:node(b, ari_test_node, #{}),
            ari_graph:in(enter, {a, input}),
            ari_graph:feedback(next, {a, output}, {b, input}),
            ari_graph:out(leave, {b, output})
        ])
    ].

cycle_between_sibling_loops_test() ->
    ?assertError(
        {invalid_graph, {cycle_without_feedback, graph}},
        ari_graph:graph([
            ari_graph:node(c, ari_test_node, #{}),
            ari_graph:node(d, ari_test_node, #{}),
            ari_graph:out(enter_left, {c, output}),
            ari_graph:in(leave_left, {d, input}),
            ari_graph:out(enter_right, {d, output}),
            ari_graph:in(leave_right, {c, input}),
            ari_graph:loop(left, [
                ari_graph:node(a, ari_test_node, #{}),
                ari_graph:node(b, ari_test_node, #{}),
                ari_graph:in(enter_left, {a, input}),
                ari_graph:feedback(next_left, {a, output}, {b, input}),
                ari_graph:out(leave_left, {b, output})
            ]),
            ari_graph:loop(right, [
                ari_graph:node(e, ari_test_node, #{}),
                ari_graph:in(enter_right, {e, input}),
                ari_graph:out(leave_right, {e, output})
            ])
        ])
    ).

nested_loop_with_outer_feedback_test() ->
    Graph = ari_graph:graph([
        ari_graph:loop(outer, [
            ari_graph:node(entry, ari_test_node, #{}),
            ari_graph:node(exit, ari_test_node, #{}),
            ari_graph:out(enter, {entry, output}),
            ari_graph:in(leave, {exit, input}),
            ari_graph:feedback(outer_next, {exit, output}, {entry, input}),
            ari_graph:loop(inner, [
                ari_graph:node(a, ari_test_node, #{}),
                ari_graph:node(b, ari_test_node, #{}),
                ari_graph:in(enter, {a, input}),
                ari_graph:edge(forward, {a, output}, {b, input}),
                ari_graph:feedback(inner_next, {b, output}, {a, input}),
                ari_graph:out(leave, {b, output})
            ])
        ])
    ]),
    ?assertEqual(
        [{inner_next, inner}, {outer_next, outer}],
        lists:sort([{Name, Loop} || #feedback{name = Name, loop = Loop} <- Graph#graph.edges])
    ),
    ?assertEqual(
        [{a, [inner, outer]}, {b, [inner, outer]}, {entry, [outer]}, {exit, [outer]}],
        lists:sort([{Name, Context} || #node{name = Name, context = Context} <- Graph#graph.nodes])
    ).

multiple_loop_ports_and_feedbacks_test() ->
    %% Имя узла может совпадать с именем цикла: это разные вершины.
    Graph = ari_graph:graph([
        ari_graph:node(inner, ari_test_node, #{}),
        ari_graph:node(sink, ari_test_node, #{}),
        ari_graph:out(enter_a, {inner, output}),
        ari_graph:out(enter_b, {inner, output}),
        ari_graph:in(leave_a, {sink, input}),
        ari_graph:in(leave_b, {sink, input}),
        ari_graph:loop(inner, [
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:node(b, ari_test_node, #{}),
            ari_graph:in(enter_a, {a, input}),
            ari_graph:in(enter_b, {b, input}),
            ari_graph:edge(forward, {a, output}, {b, input}),
            ari_graph:feedback(next_a, {b, output}, {a, input}),
            ari_graph:feedback(next_b, {b, output}, {a, input}),
            ari_graph:out(leave_a, {a, output}),
            ari_graph:out(leave_b, {b, output})
        ])
    ]),
    ?assertEqual(2, length([E || E = #ingress{} <- Graph#graph.edges])),
    ?assertEqual(2, length([E || E = #egress{} <- Graph#graph.edges])),
    ?assertEqual(2, length([E || E = #feedback{} <- Graph#graph.edges])).
