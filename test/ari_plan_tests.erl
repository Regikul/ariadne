-module(ari_plan_tests).

-include_lib("eunit/include/eunit.hrl").

-on_load(define_callbacks/0).

%%%===================================================================
%%% What the plan tells
%%%===================================================================

vertices_carry_their_callback_and_arguments_test() ->
    Plan = example(),
    ?assertEqual(
        [filter, finalize, is_done, prepare],
        lists:sort(ari_plan:vertices(Plan))
    ),
    ?assertEqual({prepare_callback, #{foo => bar}}, ari_plan:vertex(Plan, prepare)).

edges_carry_their_kind_and_ends_test() ->
    Plan = example(),
    ?assertEqual({message, undefined, {filter, in}}, ari_plan:edge(Plan, input)),
    ?assertEqual({ingress, {filter, out}, {prepare, in}}, ari_plan:edge(Plan, into_processing)),
    ?assertEqual({message, {prepare, out}, {is_done, in}}, ari_plan:edge(Plan, into_done)),
    ?assertEqual({feedback, {is_done, continue}, {prepare, in}}, ari_plan:edge(Plan, again)),
    ?assertEqual({egress, {is_done, done}, {finalize, in}}, ari_plan:edge(Plan, ready)),
    ?assertEqual({message, {finalize, out}, undefined}, ari_plan:edge(Plan, done)).

the_ends_of_the_graph_are_its_inputs_and_outputs_test() ->
    Plan = example(),
    ?assertEqual([input], ari_plan:inputs(Plan)),
    ?assertEqual([done], ari_plan:outputs(Plan)).

outgoing_lists_the_edges_of_an_output_slot_test() ->
    Plan = example(),
    ?assertEqual([into_processing], ari_plan:outgoing(Plan, {filter, out})),
    ?assertEqual([again], ari_plan:outgoing(Plan, {is_done, continue})),
    ?assertEqual([ready], ari_plan:outgoing(Plan, {is_done, done})),
    ?assertEqual([], ari_plan:outgoing(Plan, {is_done, nowhere})).

outgoing_keeps_the_order_of_a_fan_out_test() ->
    Plan = ari_plan:prepare(ari_graph:graph([
        ari_graph:node(source, filter_callback, []),
        ari_graph:node(left, filter_callback, []),
        ari_graph:node(right, filter_callback, []),
        ari_graph:edge(to_left, {source, out}, {left, in}),
        ari_graph:edge(to_right, {source, out}, {right, in})
    ])),
    ?assertEqual([to_left, to_right], ari_plan:outgoing(Plan, {source, out})).

the_plan_carries_the_summaries_of_the_graph_test() ->
    Plan = example(),
    T = ari_vtime:ingress(ari_vtime:new(1)),
    ?assert(ari_summaries:reaches(
        ari_plan:summaries(Plan), {edge, again}, T, {vertex, prepare}, ari_vtime:feedback(T)
    )).

%%%===================================================================
%%% Names
%%%===================================================================

a_vertex_name_is_used_once_test() ->
    ?assertError({duplicate_vertex, filter}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:node(filter, filter_callback, [])
    ]))).

an_edge_name_is_used_once_test() ->
    ?assertError({duplicate_edge, input}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:in(input, {filter, in}),
        ari_graph:in(input, {filter, in})
    ]))).

%%%===================================================================
%%% Slots
%%%===================================================================

a_slot_name_is_used_once_on_a_side_test() ->
    ?assertError({duplicate_slot, {twice, in}}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(twice, twice_callback, [])
    ]))).

a_slot_name_is_used_on_one_side_only_test() ->
    ?assertError({duplicate_slot, {both, port}}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(both, both_sides_callback, [])
    ]))).

an_edge_starts_at_a_vertex_of_the_graph_test() ->
    ?assertError({unknown_vertex, {stray, nowhere}}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:edge(stray, {nowhere, out}, {filter, in})
    ]))).

an_edge_starts_at_an_output_slot_test() ->
    ?assertError({unknown_slot, {stray, {filter, in}}}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:out(stray, {filter, in})
    ]))).

an_edge_ends_at_an_input_slot_test() ->
    ?assertError({unknown_slot, {stray, {filter, out}}}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:in(stray, {filter, out})
    ]))).

%%%===================================================================
%%% Scopes
%%%===================================================================

a_plain_edge_stays_within_a_scope_test() ->
    ?assertError({edge_across_scopes, straight_in}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(source, filter_callback, []),
        ari_graph:edge(straight_in, {source, out}, {inner, in}),
        ari_graph:loop(outer_loop, [
            ari_graph:loop(inner_loop, [
                ari_graph:node(inner, filter_callback, [])
            ])
        ])
    ]))).

a_plain_edge_does_not_join_neighbouring_scopes_test() ->
    ?assertError({edge_across_scopes, sideways}, ari_plan:prepare(ari_graph:graph([
        ari_graph:loop(left_loop, [
            ari_graph:node(left, filter_callback, [])
        ]),
        ari_graph:loop(right_loop, [
            ari_graph:node(right, filter_callback, []),
            ari_graph:edge(sideways, {left, out}, {right, in})
        ])
    ]))).

a_back_edge_is_inside_of_a_loop_test() ->
    ?assertError({feedback_outside_of_a_loop, back}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(a, filter_callback, []),
        ari_graph:node(b, filter_callback, []),
        ari_graph:edge(forth, {a, out}, {b, in}),
        ari_graph:feedback(back, {b, out}, {a, in})
    ]))).

a_border_written_by_hand_has_to_match_the_vertex_test() ->
    Graph = ari_graph:graph([
        ari_graph:node(filter, filter_callback, []),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, filter_callback, [])
        ])
    ]),
    Border = {ingress, into_processing, {filter, out}, {prepare, in}, elsewhere},
    Broken = setelement(3, Graph, [Border | element(3, Graph)]),
    ?assertError({scope_mismatch, into_processing}, ari_plan:prepare(Broken)).

%%%===================================================================
%%% Cycles
%%%===================================================================

a_cycle_has_to_advance_the_time_test() ->
    ?assertError({non_advancing_cycle, _}, ari_plan:prepare(ari_graph:graph([
        ari_graph:node(a, filter_callback, []),
        ari_graph:node(b, filter_callback, []),
        ari_graph:edge(forth, {a, out}, {b, in}),
        ari_graph:edge(back, {b, out}, {a, in})
    ]))).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% The plan of the example of the documentation of ari_graph. The
%% callback modules are defined on the fly, with the slots the example
%% needs.
example() ->
    ari_plan:prepare(ari_graph:graph([
        ari_graph:in(input, {filter, in}),
        ari_graph:node(filter, filter_callback, []),
        ari_graph:loop(processing, [
            ari_graph:node(prepare, prepare_callback, #{foo => bar}),
            ari_graph:node(is_done, is_done_callback, []),
            ari_graph:edge(into_processing, {filter, out}, {prepare, in}),
            ari_graph:edge(into_done, {prepare, out}, {is_done, in}),
            ari_graph:feedback(again, {is_done, continue}, {prepare, in})
        ]),
        ari_graph:edge(ready, {is_done, done}, {finalize, in}),
        ari_graph:node(finalize, finalize_callback, []),
        ari_graph:out(done, {finalize, out})
    ])).

%% Defines and loads the callback modules the tests refer to. Runs
%% once, when this module is loaded.
define_callbacks() ->
    lists:foreach(
        fun({Name, Inputs, Outputs}) -> define(Name, Inputs, Outputs) end,
        [
            {filter_callback, [in], [out]},
            {prepare_callback, [in], [out]},
            {is_done_callback, [in], [continue, done]},
            {finalize_callback, [in], [out]},
            {twice_callback, [in, in], [out]},
            {both_sides_callback, [port], [port]}
        ]
    ).

%% Defines a module of the ariadne_vertex behaviour with the given
%% slots and nothing else.
define(Name, Inputs, Outputs) ->
    Forms = [
        {attribute, 1, module, Name},
        {attribute, 1, export, [{inputs, 0}, {outputs, 0}]},
        {function, 1, inputs, 0, [{clause, 1, [], [], [erl_parse:abstract(Inputs)]}]},
        {function, 1, outputs, 0, [{clause, 1, [], [], [erl_parse:abstract(Outputs)]}]}
    ],
    {ok, Name, Binary} = compile:forms(Forms),
    {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Binary),
    ok.
