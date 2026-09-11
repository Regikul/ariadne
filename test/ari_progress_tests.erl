%% @doc Проверяет условия допустимости уведомлений на готовых счётчиках,
%% запросах и таблицах сводок, без сборки прогона.
-module(ari_progress_tests).

-include_lib("eunit/include/eunit.hrl").

summary(Pop, Bump, Push) ->
    ari_vtime:summary(Pop, Bump, Push).

%% Проверка на счётчиках и запросах в форме состояния прогона.
admissible(Node, Time, Counts, Requests, Summaries) ->
    ari_progress:admissible(
        Node,
        Time,
        ari_progress:message_frontier(Counts),
        ari_progress:request_frontier(Requests),
        Summaries
    ).

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
        {Title, ?_assertEqual(Expected, admissible(Node, Time, Counts, Requests, Summaries))}
     || {Title, Counts, Requests, Summaries, {Node, Time}, Expected} <- [
        {"ациклический узел, сообщение того же времени",
            #{a => #{{5, []} => 1}}, #{a => [{5, []}]}, #{}, {a, {5, []}}, false},
        {"ациклический узел, запрос меньшего времени",
            #{}, #{a => [{5, []}, {6, []}]}, #{}, {a, {6, []}}, true},
        {"простой цикл, запрос предыдущей итерации",
            #{}, #{a => [{5, [0]}, {5, [1]}]}, simple_cycle(), {a, {5, [1]}}, false},
        {"простой цикл, только собственный запрос",
            #{}, #{a => [{5, [0]}]}, simple_cycle(), {a, {5, [0]}}, true},
        {"простой цикл, сообщение более поздней итерации",
            #{a => #{{5, [3]} => 1}}, #{a => [{5, [2]}]}, simple_cycle(), {a, {5, [2]}}, true},
        {"egress, сообщение внутри цикла",
            #{a => #{{5, [3]} => 1}}, #{k => [{5, []}]}, egress_graph(), {k, {5, []}}, false},
        {"вложенные циклы, запрос предыдущей внешней итерации",
            #{}, #{a => [{5, [3, 0]}, {5, [0, 1]}]}, nested_cycles(), {a, {5, [0, 1]}}, false},
        {"вложенные циклы, только собственный запрос",
            #{}, #{a => [{5, [0, 1]}]}, nested_cycles(), {a, {5, [0, 1]}}, true}
    ]
    ].

message_in_other_node_blocks_through_path_test() ->
    Counts = #{b => #{{5, [0]} => 1}},
    ?assertNot(admissible(a, {5, [1]}, Counts, #{}, simple_cycle())),
    ?assert(admissible(a, {5, [0]}, Counts, #{}, simple_cycle())).

request_in_other_node_blocks_through_path_test() ->
    Requests = #{b => [{5, [0]}]},
    ?assertNot(admissible(a, {5, [1]}, #{}, Requests, simple_cycle())),
    ?assert(admissible(a, {5, [0]}, #{}, Requests, simple_cycle())).

direct_message_blocks_without_summaries_test() ->
    ?assertNot(admissible(a, {6, []}, #{a => #{{5, []} => 1}}, #{}, #{})),
    ?assert(admissible(a, {5, []}, #{a => #{{6, []} => 1}}, #{}, #{})).

incomparable_time_does_not_block_test() ->
    ?assert(admissible(a, {5, [1]}, #{a => #{{6, [0]} => 1}}, #{}, #{})).

request_in_same_node_needs_path_test() ->
    ?assert(admissible(a, {6, []}, #{}, #{a => [{5, []}, {6, []}]}, #{})).

blocking_predicates_test() ->
    ?assert(ari_progress:message_blocks(a, {5, []}, a, {5, []}, #{})),
    ?assertNot(ari_progress:request_blocks(a, {5, []}, a, {5, []}, #{})),
    ?assert(ari_progress:request_blocks(b, {5, [0]}, a, {5, [1]}, simple_cycle())),
    ?assertNot(ari_progress:request_blocks(b, {5, [1]}, a, {5, [1]}, simple_cycle())).

%% Фронтир хранит только минимальные времена узла; несравнимые остаются.
frontier_test() ->
    Counts = #{a => #{{5, [0]} => 2, {5, [1]} => 1, {6, [0]} => 1}, b => #{{6, [0]} => 1, {5, [1]} => 1}},
    #{a := A, b := B} = ari_progress:message_frontier(Counts),
    ?assertEqual([{5, [0]}], A),
    ?assertEqual([{5, [1]}, {6, [0]}], lists:sort(B)),
    ?assertEqual(#{}, ari_progress:message_frontier(#{})),
    ?assertEqual(
        #{a => [{5, [0]}], b => [{7, []}]},
        ari_progress:request_frontier(#{a => [{5, [0]}, {5, [3]}, {6, [0]}], b => [{7, []}]})
    ).

%% Фронтир блокирует так же, как полный набор: большее время источника
%% ничего не добавляет.
frontier_matches_full_check_test() ->
    Summaries = simple_cycle(),
    Counts = #{b => #{{5, [0]} => 1, {5, [2]} => 1}, a => #{{5, [4]} => 1}},
    Requests = #{b => [{5, [1]}, {5, [3]}]},
    lists:foreach(
        fun(Time) ->
            Full =
                not lists:any(
                    fun({Source, Stamp}) -> ari_progress:message_blocks(Source, Stamp, a, Time, Summaries) end,
                    [{Source, Stamp} || {Source, Times} <- maps:to_list(Counts), Stamp <- maps:keys(Times)]
                ) andalso
                    not lists:any(
                        fun(Stamp) -> ari_progress:request_blocks(b, Stamp, a, Time, Summaries) end,
                        maps:get(b, Requests)
                    ),
            ?assertEqual({Time, Full}, {Time, admissible(a, Time, Counts, Requests, Summaries)})
        end,
        [{5, [I]} || I <- lists:seq(0, 5)]
    ).

%% Фронтир по сортировке совпадает с минимальными элементами по определению
%% на всех подмножествах сетки времён глубины один и два.
frontier_matches_definition_test() ->
    Grids = [
        [{Epoch, [I]} || Epoch <- [0, 1, 2], I <- [0, 1, 2]],
        [{Epoch, [Inner, Outer]} || Epoch <- [0, 1], Outer <- [0, 1], Inner <- [0, 1]]
    ],
    lists:foreach(
        fun(Grid) ->
            lists:foreach(
                fun(Subset) ->
                    Expected = [
                        Time
                     || Time <- Subset,
                        not lists:any(fun(Other) -> Other =/= Time andalso ari_vtime:le(Other, Time) end, Subset)
                    ],
                    #{node := Actual} = ari_progress:request_frontier(#{node => ordsets:from_list(Subset)}),
                    ?assertEqual({Subset, lists:sort(Expected)}, {Subset, lists:sort(Actual)})
                end,
                subsets(Grid)
            )
        end,
        Grids
    ).

%% Широкие антицепи достраиваются сортировкой; результат совпадает с
%% определением на случайных подмножествах полосы вокруг антидиагонали
%% сетки 20 x 20 с фиксированным зерном, где ширина фронтира превышает
%% порог переключения.
wide_frontier_matches_definition_test() ->
    Grid = [
        {Epoch, [I]}
     || Epoch <- lists:seq(0, 19), I <- lists:seq(max(0, 17 - Epoch), 21 - Epoch)
    ],
    rand:seed(exsss, {7, 11, 13}),
    Widths = lists:map(
        fun(_) ->
            Subset = [Time || Time <- Grid, rand:uniform() < 0.6],
            Expected = [
                Time
             || Time <- Subset,
                not lists:any(fun(Other) -> Other =/= Time andalso ari_vtime:le(Other, Time) end, Subset)
            ],
            Counts = #{node => maps:from_list([{Time, 1} || Time <- Subset])},
            #{node := FromCounts} = ari_progress:message_frontier(Counts),
            #{node := FromRequests} = ari_progress:request_frontier(#{node => ordsets:from_list(Subset)}),
            ?assertEqual(lists:sort(Expected), lists:sort(FromCounts)),
            ?assertEqual(lists:sort(Expected), lists:sort(FromRequests)),
            length(Expected)
        end,
        lists:seq(1, 50)
    ),
    ?assert(lists:max(Widths) > 8),
    Antichain = [{I, [20 - I]} || I <- lists:seq(1, 20)],
    #{node := Wide} = ari_progress:request_frontier(#{node => ordsets:from_list(Antichain)}),
    ?assertEqual(Antichain, lists:sort(Wide)).

subsets([]) ->
    [[]];
subsets([Item | Rest]) ->
    Subsets = subsets(Rest),
    [[Item | Subset] || Subset <- Subsets] ++ Subsets.
