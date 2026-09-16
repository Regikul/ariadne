-module(ari_documentation_tests).

-include_lib("eunit/include/eunit.hrl").

readme_quick_start_test() ->
    Graph = ari_graph:graph([
        ari_graph:in(input, {double, in}),
        ari_graph:node(double, ariadne_example_map, fun(N) -> N * 2 end),
        ari_graph:out(mapped, {double, out}),
        ari_graph:edge(to_sum, {double, out}, {sum, in}),
        ari_graph:node(sum, ariadne_example_sum, []),
        ari_graph:out(total, {sum, out})
    ]),
    R0 = ari_single_runtime:new(Graph),
    R1 = ari_single_runtime:push(input, 0, [1, 2, 3], R0),
    R2 = ari_single_runtime:run(R1),
    {Items, R3} = ari_single_runtime:pull(mapped, R2),
    T = ari_vtime:new(0),
    ?assertEqual([{2, T}, {4, T}, {6, T}], Items),
    {TotalsBeforeClose, R4} = ari_single_runtime:pull(total, R3),
    ?assertEqual([], TotalsBeforeClose),
    R5 = ari_single_runtime:close(input, 0, R4),
    R6 = ari_single_runtime:run(R5),
    {TotalsAfterClose, R7} = ari_single_runtime:pull(total, R6),
    ?assertEqual([{12, T}], TotalsAfterClose),
    ?assertEqual(ok, ari_single_runtime:stop(R7)).
