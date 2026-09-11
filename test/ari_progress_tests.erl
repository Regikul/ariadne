%% @doc Проверяет условия допустимости уведомлений на готовых счётчиках,
%% запросах и таблицах сводок, без сборки прогона.
-module(ari_progress_tests).

-include_lib("eunit/include/eunit.hrl").

summary(Pop, Bump, Push) ->
    ari_vtime:summary(Pop, Bump, Push).

%% Цикл из `a` и `b` с одним feedback-ребром `b -> a`.
simple_cycle() ->
    Turn = [summary(0, 1, [])],
    #{{a, a} => Turn, {b, b} => Turn, {b, a} => Turn, {a, b} => [summary(0, 0, [])]}.

%% `a` внутри цикла, `k` за egress.
egress_graph() ->
    #{{a, k} => [summary(1, 0, [])]}.

%% Внутренний цикл вложен во внешний: у `a -> a` есть внутренний оборот и
%% возврат через внешний feedback.
nested_cycles() ->
    #{{a, a} => [summary(0, 1, []), summary(1, 1, [0])]}.

%% Строки таблицы «Проверочные примеры» спецификации.
specification_examples_test_() ->
    [
        {Title, ?_assertEqual(Expected, ari_progress:admissible(Node, Time, Counts, Requests, Summaries))}
     || {Title, Counts, Requests, Summaries, {Node, Time}, Expected} <- [
        {"ациклический узел, сообщение того же времени",
            #{{a, {5, []}} => 1}, #{a => [{5, []}]}, #{}, {a, {5, []}}, false},
        {"ациклический узел, запрос меньшего времени",
            #{}, #{a => [{5, []}, {6, []}]}, #{}, {a, {6, []}}, true},
        {"простой цикл, запрос предыдущей итерации",
            #{}, #{a => [{5, [0]}, {5, [1]}]}, simple_cycle(), {a, {5, [1]}}, false},
        {"простой цикл, только собственный запрос",
            #{}, #{a => [{5, [0]}]}, simple_cycle(), {a, {5, [0]}}, true},
        {"простой цикл, сообщение более поздней итерации",
            #{{a, {5, [3]}} => 1}, #{a => [{5, [2]}]}, simple_cycle(), {a, {5, [2]}}, true},
        {"egress, сообщение внутри цикла",
            #{{a, {5, [3]}} => 1}, #{k => [{5, []}]}, egress_graph(), {k, {5, []}}, false},
        {"вложенные циклы, запрос предыдущей внешней итерации",
            #{}, #{a => [{5, [3, 0]}, {5, [0, 1]}]}, nested_cycles(), {a, {5, [0, 1]}}, false},
        {"вложенные циклы, только собственный запрос",
            #{}, #{a => [{5, [0, 1]}]}, nested_cycles(), {a, {5, [0, 1]}}, true}
    ]
    ].

message_in_other_node_blocks_through_path_test() ->
    Counts = #{{b, {5, [0]}} => 1},
    ?assertNot(ari_progress:admissible(a, {5, [1]}, Counts, #{}, simple_cycle())),
    ?assert(ari_progress:admissible(a, {5, [0]}, Counts, #{}, simple_cycle())).

request_in_other_node_blocks_through_path_test() ->
    Requests = #{b => [{5, [0]}]},
    ?assertNot(ari_progress:admissible(a, {5, [1]}, #{}, Requests, simple_cycle())),
    ?assert(ari_progress:admissible(a, {5, [0]}, #{}, Requests, simple_cycle())).

direct_message_blocks_without_summaries_test() ->
    ?assertNot(ari_progress:admissible(a, {6, []}, #{{a, {5, []}} => 1}, #{}, #{})),
    ?assert(ari_progress:admissible(a, {5, []}, #{{a, {6, []}} => 1}, #{}, #{})).

incomparable_time_does_not_block_test() ->
    ?assert(ari_progress:admissible(a, {5, [1]}, #{{a, {6, [0]}} => 1}, #{}, #{})).

request_in_same_node_needs_path_test() ->
    ?assert(ari_progress:admissible(a, {6, []}, #{}, #{a => [{5, []}, {6, []}]}, #{})).

blocking_predicates_test() ->
    ?assert(ari_progress:message_blocks(a, {5, []}, a, {5, []}, #{})),
    ?assertNot(ari_progress:request_blocks(a, {5, []}, a, {5, []}, #{})),
    ?assert(ari_progress:request_blocks(b, {5, [0]}, a, {5, [1]}, simple_cycle())),
    ?assertNot(ari_progress:request_blocks(b, {5, [1]}, a, {5, [1]}, simple_cycle())).
