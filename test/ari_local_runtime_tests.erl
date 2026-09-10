%% @doc Проверяет сборку программы локальным runtime.
-module(ari_local_runtime_tests).

-include("ariadne.hrl").
-include_lib("eunit/include/eunit.hrl").

linear_graph_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:node(b, ari_test_node, #{}),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:out(output, {b, output})
    ]),
    {ok, Program} = ari_local_runtime:compile(Graph),
    ?assertEqual(
        #{
            nodes => #{
                a => #{
                    module => ari_test_node,
                    args => #{},
                    inputs => #{input => [input]},
                    outputs => #{output => [a_to_b]}
                },
                b => #{
                    module => ari_test_node,
                    args => #{},
                    inputs => #{input => [a_to_b]},
                    outputs => #{output => [output]}
                }
            },
            edges => #{
                input => #{kind => message, loop => undefined, from => undefined, to => {a, input}},
                a_to_b => #{kind => message, loop => undefined, from => {a, output}, to => {b, input}},
                output => #{kind => message, loop => undefined, from => {b, output}, to => undefined}
            },
            edge_order => [a_to_b, input, output],
            node_order => [a, b],
            inputs => [input],
            outputs => [output],
            summaries => #{{a, b} => [ari_vtime:summary(0, 0, [])]}
        },
        ari_local_runtime:inspect(Program)
    ).

loop_graph_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(source, ari_test_node, #{}),
        ari_graph:node(sink, ari_test_node, #{}),
        ari_graph:out(input, {source, output}),
        ari_graph:loop(iteration, [
            ari_graph:node(a, ari_test_node, #{}),
            ari_graph:node(b, ari_test_node, #{}),
            ari_graph:in(input, {a, input}),
            ari_graph:edge(a_to_b, {a, output}, {b, input}),
            ari_graph:feedback(next, {b, output}, {a, input}),
            ari_graph:out(output, {b, output})
        ]),
        ari_graph:in(output, {sink, input})
    ]),
    {ok, Program} = ari_local_runtime:compile(Graph),
    #{nodes := Nodes, edges := Edges, inputs := Inputs, outputs := Outputs, summaries := Summaries} =
        ari_local_runtime:inspect(Program),
    ?assertEqual(
        #{
            input => #{kind => ingress, loop => iteration, from => {source, output}, to => {a, input}},
            a_to_b => #{kind => message, loop => undefined, from => {a, output}, to => {b, input}},
            next => #{kind => feedback, loop => iteration, from => {b, output}, to => {a, input}},
            output => #{kind => egress, loop => iteration, from => {b, output}, to => {sink, input}}
        },
        Edges
    ),
    ?assertEqual(#{input => [input, next]}, maps:get(inputs, maps:get(a, Nodes))),
    ?assertEqual(#{output => [next, output]}, maps:get(outputs, maps:get(b, Nodes))),
    ?assertEqual([], Inputs),
    ?assertEqual([], Outputs),
    Summary = fun(Pop, Bump, Push) -> [ari_vtime:summary(Pop, Bump, Push)] end,
    ?assertEqual(
        #{
            {source, a} => Summary(0, 0, [0]),
            {source, b} => Summary(0, 0, [0]),
            {source, sink} => Summary(0, 0, []),
            {a, a} => Summary(0, 1, []),
            {a, b} => Summary(0, 0, []),
            {a, sink} => Summary(1, 0, []),
            {b, a} => Summary(0, 1, []),
            {b, b} => Summary(0, 1, []),
            {b, sink} => Summary(1, 0, [])
        },
        Summaries
    ).

%% Внутренний цикл `inner` из `a` и `b` вложен во внешний `outer` с узлом
%% `c` перед ним и `d` после. Обратный путь `a -> a` через внешний feedback
%% снимает внутреннюю координату, увеличивает внешнюю и входит заново.
nested_loop_summaries_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(source, ari_test_node, #{}),
        ari_graph:node(sink, ari_test_node, #{}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(outer, [
            ari_graph:node(c, ari_test_node, #{}),
            ari_graph:node(d, ari_test_node, #{}),
            ari_graph:in(enter, {c, input}),
            ari_graph:out(descend, {c, output}),
            ari_graph:loop(inner, [
                ari_graph:node(a, ari_test_node, #{}),
                ari_graph:node(b, ari_test_node, #{}),
                ari_graph:in(descend, {a, input}),
                ari_graph:edge(a_to_b, {a, output}, {b, input}),
                ari_graph:feedback(again, {b, output}, {a, input}),
                ari_graph:out(ascend, {b, output})
            ]),
            ari_graph:in(ascend, {d, input}),
            ari_graph:feedback(repeat, {d, output}, {c, input}),
            ari_graph:out(leave, {d, output})
        ]),
        ari_graph:in(leave, {sink, input})
    ]),
    {ok, Program} = ari_local_runtime:compile(Graph),
    #{summaries := Summaries} = ari_local_runtime:inspect(Program),
    Summary = fun(Pop, Bump, Push) -> ari_vtime:summary(Pop, Bump, Push) end,
    ?assertEqual([Summary(0, 1, []), Summary(1, 1, [0])], maps:get({a, a}, Summaries)),
    ?assertEqual([Summary(0, 0, [0])], maps:get({c, a}, Summaries)),
    ?assertEqual([Summary(0, 0, [0, 0])], maps:get({source, a}, Summaries)),
    ?assertEqual([Summary(2, 0, [])], maps:get({a, sink}, Summaries)),
    ?assertEqual([Summary(0, 0, [])], maps:get({source, sink}, Summaries)),
    ?assertEqual([Summary(0, 1, [])], maps:get({c, c}, Summaries)),
    ?assertEqual(
        {5, [0, 1]},
        ari_vtime:transfer(Summary(1, 1, [0]), {5, [3, 0]})
    ),
    ?assertNot(maps:is_key({sink, sink}, Summaries)),
    ?assertNot(maps:is_key({source, source}, Summaries)).

unconnected_output_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:in(input, {a, input})
    ]),
    {ok, Program} = ari_local_runtime:compile(Graph),
    #{nodes := #{a := #{outputs := Outputs}}} = ari_local_runtime:inspect(Program),
    ?assertEqual(#{output => []}, Outputs).

fan_out_order_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(c, ari_test_node, #{}),
        ari_graph:node(b, ari_test_node, #{}),
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:edge(to_c, {a, output}, {c, input}),
        ari_graph:edge(to_b, {a, output}, {b, input}),
        ari_graph:in(input, {a, input})
    ]),
    {ok, Program} = ari_local_runtime:compile(Graph),
    #{nodes := Nodes, edge_order := EdgeOrder, node_order := NodeOrder} =
        ari_local_runtime:inspect(Program),
    ?assertEqual([input, to_b, to_c], EdgeOrder),
    ?assertEqual([a, b, c], NodeOrder),
    ?assertEqual(#{output => [to_b, to_c]}, maps:get(outputs, maps:get(a, Nodes))).

unknown_module_test() ->
    Graph = ari_graph:graph([ari_graph:node(a, ari_no_such_node, #{})]),
    ?assertEqual(
        {error, {unknown_module, a, ari_no_such_node}},
        ari_local_runtime:compile(Graph)
    ).

missing_callback_test() ->
    Graph = ari_graph:graph([ari_graph:node(a, ari_partial_node, #{})]),
    ?assertEqual(
        {error, {missing_callback, a, ari_partial_node, {init, 1}}},
        ari_local_runtime:compile(Graph)
    ).

unknown_input_slot_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:in(input, {a, missing})
    ]),
    ?assertEqual(
        {error, {unknown_input_slot, input, a, missing}},
        ari_local_runtime:compile(Graph)
    ).

unknown_output_slot_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(a, ari_test_node, #{}),
        ari_graph:out(output, {a, missing})
    ]),
    ?assertEqual(
        {error, {unknown_output_slot, output, a, missing}},
        ari_local_runtime:compile(Graph)
    ).
