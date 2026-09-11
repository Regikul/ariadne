%% @doc Сквозные сценарии локального runtime с проверкой инвариантов
%% состояния после каждого перехода.
%%
%% Каждый сценарий прогоняется дважды: по одному шагу с проверкой инвариантов
%% раздела «Состояние» спецификации и одним вызовом с бюджетом `infinity`.
%% Оба прогона обязаны прийти в одно состояние.
-module(ari_local_runtime_e2e_tests).

-include_lib("eunit/include/eunit.hrl").

relay(Name) ->
    relay(Name, #{}).

relay(Name, Args) ->
    ari_graph:node(Name, ari_relay_node, Args).

notify(Name) ->
    ari_graph:node(Name, ari_notify_node, #{}).

start(Items, Inputs) ->
    {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
    {ok, Execution} = ari_local_runtime:new(Program, Inputs),
    Execution.

%% Прогоняет сценарий до покоя по одному шагу, проверяя инварианты после
%% инициализации и после каждого перехода, и сверяет итог с прогоном без
%% остановок. Возвращает состояние покоя.
run(Items, Inputs) ->
    Execution = start(Items, Inputs),
    check(Execution),
    Stepped = step_all(Execution),
    {done, Whole} = ari_local_runtime:advance(Execution, infinity),
    ?assertEqual(comparable(Whole), comparable(Stepped)),
    #{ready := [], notify := #{}, scheduled := #{}, counts := #{}} = ari_local_runtime:inspect(Stepped),
    Stepped.

%% Состояние без стеков исключений: стек хранит кадры вызывающего,
%% и у прогонов с разным бюджетом они различаются.
comparable(Execution) ->
    Inspected = ari_local_runtime:inspect(Execution),
    Violations = [
        case Violation of
            {Kind, Node, Event, Time, {Class, Reason, _Stack}} -> {Kind, Node, Event, Time, {Class, Reason}};
            Other -> Other
        end
     || Violation <- maps:get(violations, Inspected)
    ],
    Inspected#{violations := Violations}.

step_all(Execution) ->
    case ari_local_runtime:advance(Execution, 1) of
        {done, Next} ->
            check(Next),
            Next;
        {more, Next} ->
            check(Next),
            step_all(Next)
    end.

%% Инварианты между шагами.
check(Execution) ->
    #{
        program := #{edges := Edges, nodes := Nodes},
        queues := Queues,
        counts := Counts,
        notify := Notify,
        ready := Ready,
        scheduled := Scheduled,
        messages := Messages,
        requests := Requests,
        stale := Stale,
        blockers := Blockers,
        candidates := Candidates
    } = ari_local_runtime:inspect(Execution),
    %% элементы `ready` уникальны
    ?assertEqual(length(Ready), length(lists:usort(Ready))),
    %% непустое ребро с получателем стоит в `ready` ровно один раз,
    %% пустое ребро и выходное полуребро — ни разу
    maps:foreach(
        fun(Name, #{to := To}) ->
            Expected =
                case {To, maps:get(Name, Queues)} of
                    {undefined, _} -> 0;
                    {_, []} -> 0;
                    {_, _} -> 1
                end,
            ?assertEqual({Name, Expected}, {Name, length([E || {edge, E} <- Ready, E =:= Name])})
        end,
        Edges
    ),
    %% `counts` совпадает с пересчётом по очередям рёбер с получателем
    Recounted = maps:fold(
        fun(Name, #{to := To}, Acc) ->
            case To of
                undefined ->
                    Acc;
                {Node, _Slot} ->
                    lists:foldl(
                        fun({_Message, Time}, Inner) ->
                            Times = maps:get(Node, Inner, #{}),
                            Inner#{Node => maps:update_with(Time, fun(N) -> N + 1 end, 1, Times)}
                        end,
                        Acc,
                        maps:get(Name, Queues)
                    )
            end
        end,
        #{},
        Edges
    ),
    ?assertEqual(Recounted, Counts),
    %% время каждого сообщения в очереди имеет глубину узла на конце ребра
    maps:foreach(
        fun(Name, #{from := From, to := To}) ->
            {Node, _Slot} =
                case To of
                    undefined -> From;
                    _ -> To
                end,
            #{depth := Depth} = maps:get(Node, Nodes),
            lists:foreach(
                fun({_Message, Time}) -> ?assert(ari_vtime:valid(Time, Depth)) end,
                maps:get(Name, Queues)
            )
        end,
        Edges
    ),
    %% каждая отметка `scheduled` соответствует одному уведомлению в `ready`
    %% и запросу в `notify`; каждое уведомление в `ready` отмечено
    Notified = [{Node, Time} || {notify, Node, Time} <- Ready],
    ?assertEqual(lists:sort(maps:keys(Scheduled)), lists:sort(Notified)),
    lists:foreach(
        fun({Node, Time}) ->
            ?assert(ordsets:is_element(Time, maps:get(Node, Notify, [])))
        end,
        Notified
    ),
    %% узлы без запросов ключа в `notify` не имеют
    maps:foreach(fun(_Node, Times) -> ?assertNotEqual([], Times) end, Notify),
    %% до первого запроса фронтиры не поддерживаются; иначе фронтир узла
    %% без отметки `stale` совпадает с построенным заново
    case Stale of
        all ->
            ?assertEqual(#{}, Notify),
            ?assertEqual(#{}, Blockers),
            ?assertEqual([], Candidates);
        _ ->
            Exact = #{
                message => ari_progress:message_frontier(Counts),
                request => ari_progress:request_frontier(Notify)
            },
            Cached = #{message => Messages, request => Requests},
            lists:foreach(
                fun(Kind) ->
                    maps:foreach(
                        fun(Node, Times) ->
                            case maps:is_key({Kind, Node}, Stale) of
                                true ->
                                    ok;
                                false ->
                                    ?assertEqual(
                                        {Kind, Node, lists:sort(Times)},
                                        {Kind, Node, lists:sort(maps:get(Node, maps:get(Kind, Exact), []))}
                                    )
                            end
                        end,
                        maps:get(Kind, Cached)
                    ),
                    maps:foreach(
                        fun(Node, _Times) ->
                            maps:is_key({Kind, Node}, Stale) orelse ?assert(maps:is_key(Node, maps:get(Kind, Cached)))
                        end,
                        maps:get(Kind, Exact)
                    )
                end,
                [message, request]
            )
    end,
    %% свидетель — живое время: ключ `counts` или запрос из `notify`
    maps:foreach(
        fun({Kind, Node, Time}, Witnessed) ->
            ?assertNotEqual([], Witnessed),
            case Kind of
                message -> ?assert(maps:is_key(Time, maps:get(Node, Counts, #{})));
                request -> ?assert(ordsets:is_element(Time, maps:get(Node, Notify, [])))
            end
        end,
        Blockers
    ),
    %% каждый непоставленный запрос ждёт ровно в одном месте: в кандидатах
    %% или у одного свидетеля; поставленные не ждут нигде
    Waiting = lists:sort(Candidates ++ lists:append(maps:values(Blockers))),
    Unscheduled = lists:sort([
        {Node, Time}
     || {Node, Times} <- maps:to_list(Notify), Time <- Times, not maps:is_key({Node, Time}, Scheduled)
    ]),
    ?assertEqual(Unscheduled, Waiting).

%% Сценарии.

linear_test() ->
    Items = [
        relay(a),
        relay(b),
        relay(c),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:edge(b_to_c, {b, output}, {c, input}),
        ari_graph:out(output, {c, output})
    ],
    Messages = [{N, {N rem 3, []}} || N <- lists:seq(1, 9)],
    Done = run(Items, [{input, Messages}]),
    ?assertEqual(#{output => Messages}, ari_local_runtime:outputs(Done)),
    ?assertEqual([], ari_local_runtime:violations(Done)),
    ?assertEqual(27, ari_local_runtime:steps(Done)),
    #{states := States} = ari_local_runtime:inspect(Done),
    ?assertEqual([9, 9, 9], [Count || Node <- [a, b, c], {_Args, Count} <- [maps:get(Node, States)]]).

%% `a` рассылает в `b` и `c` двумя рёбрами одного слота, `b` и `c` сливаются
%% в один входной слот `d`.
fan_out_merge_test() ->
    Items = [
        relay(a),
        relay(b),
        relay(c, #{shift => 1}),
        relay(d),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:edge(a_to_c, {a, output}, {c, input}),
        ari_graph:edge(b_to_d, {b, output}, {d, input}),
        ari_graph:edge(c_to_d, {c, output}, {d, input}),
        ari_graph:out(output, {d, output})
    ],
    Done = run(Items, [{input, [{m1, {5, []}}, {m2, {5, []}}]}]),
    #{output := Output} = ari_local_runtime:outputs(Done),
    %% каждое сообщение приходит в `d` дважды: без сдвига через `b`
    %% и со сдвигом эпохи через `c`; порядок на каждом ребре сохранён
    ?assertEqual([{m1, {5, []}}, {m2, {5, []}}], [Item || {_, {5, []}} = Item <- Output]),
    ?assertEqual([{m1, {6, []}}, {m2, {6, []}}], [Item || {_, {6, []}} = Item <- Output]),
    ?assertEqual(4, length(Output)),
    ?assertEqual([], ari_local_runtime:violations(Done)),
    ?assertEqual(10, ari_local_runtime:steps(Done)).

%% `a` кладёт каждое сообщение в `a_to_b` дважды за один callback: второе
%% попадает в непустую очередь, и ребро остаётся в `ready` однократно.
double_emit_test() ->
    Items = [
        relay(a, #{emit => [output, output]}),
        relay(b),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:out(output, {b, output})
    ],
    Done = run(Items, [{input, [{m1, {5, []}}, {m2, {6, []}}]}]),
    ?assertEqual(
        #{output => [{m1, {5, []}}, {m1, {5, []}}, {m2, {6, []}}, {m2, {6, []}}]},
        ari_local_runtime:outputs(Done)
    ),
    ?assertEqual(6, ari_local_runtime:steps(Done)).

%% `agg` копит сообщения двух источников и выдаёт пакет времени по
%% уведомлению; пакет времени `5` выходит после сообщений времени `5`
%% с обоих рёбер, хотя между ними лежат сообщения времени `6`.
aggregation_test() ->
    Items = [
        relay(a),
        relay(b),
        notify(agg),
        ari_graph:in(left, {a, input}),
        ari_graph:in(right, {b, input}),
        ari_graph:edge(a_to_agg, {a, output}, {agg, input}),
        ari_graph:edge(b_to_agg, {b, output}, {agg, input}),
        ari_graph:out(output, {agg, output})
    ],
    Inputs = [
        {left, [{l5, {5, []}}, {l6, {6, []}}]},
        {right, [{r6, {6, []}}, {r5, {5, []}}]}
    ],
    Done = run(Items, Inputs),
    #{output := Output} = ari_local_runtime:outputs(Done),
    ?assertMatch([{{batch, _}, {5, []}}, {{batch, _}, {6, []}}], Output),
    [{{batch, Batch5}, _}, {{batch, Batch6}, _}] = Output,
    ?assertEqual([l5, r5], lists:sort(Batch5)),
    ?assertEqual([l6, r6], lists:sort(Batch6)),
    ?assertEqual([], ari_local_runtime:violations(Done)).

%% Уведомление времени эпохи ждёт сообщение, крутящееся в цикле: путь через
%% `egress` возвращает его в тот же pointstamp.
loop_blocks_notification_test() ->
    Items = [
        relay(source),
        notify(agg),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:edge(direct, {source, output}, {agg, input}),
        ari_graph:loop(iteration, [
            ari_graph:node(body, ari_loop_node, #{turns => 3}),
            relay(back),
            ari_graph:in(enter, {body, input}),
            ari_graph:edge(to_back, {body, next}, {back, input}),
            ari_graph:feedback(next, {back, output}, {body, input}),
            ari_graph:out(leave, {body, exit})
        ]),
        ari_graph:in(leave, {agg, input}),
        ari_graph:out(output, {agg, output})
    ],
    Done = run(Items, [{input, [{m, {5, []}}]}]),
    ?assertEqual(#{output => [{{batch, [m, m]}, {5, []}}]}, ari_local_runtime:outputs(Done)),
    ?assertEqual([], ari_local_runtime:violations(Done)).

%% Узел внутри цикла копит сообщения каждой итерации отдельно.
loop_aggregation_test() ->
    Items = [
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(iteration, [
            ari_graph:node(body, ari_loop_node, #{turns => 2}),
            notify(agg),
            relay(back),
            ari_graph:in(enter, {body, input}),
            ari_graph:edge(to_agg, {body, next}, {agg, input}),
            ari_graph:edge(to_back, {agg, output}, {back, input}),
            ari_graph:feedback(next, {back, output}, {body, input}),
            ari_graph:out(leave, {body, exit})
        ]),
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ],
    Done = run(Items, [{input, [{m1, {5, []}}, {m2, {5, []}}, {m3, {6, []}}]}]),
    #{output := Output} = ari_local_runtime:outputs(Done),
    ?assertEqual(
        [{{batch, [{batch, [m1, m2]}]}, {5, []}}, {{batch, [{batch, [m3]}]}, {6, []}}],
        Output
    ),
    ?assertEqual([], ari_local_runtime:violations(Done)),
    #{states := States} = ari_local_runtime:inspect(Done),
    %% `back` видит по одному пакету на итерацию каждой эпохи
    ?assertMatch({_, 4}, maps:get(back, States)).

nested_loops_items() ->
    [
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(outer, [
            ari_graph:node(outer_body, ari_loop_node, #{turns => 2}),
            relay(outer_back),
            ari_graph:in(enter, {outer_body, input}),
            ari_graph:out(inner_enter, {outer_body, next}),
            ari_graph:loop(inner, [
                ari_graph:node(inner_body, ari_loop_node, #{turns => 2}),
                relay(inner_back),
                ari_graph:in(inner_enter, {inner_body, input}),
                ari_graph:edge(inner_to_back, {inner_body, next}, {inner_back, input}),
                ari_graph:feedback(inner_next, {inner_back, output}, {inner_body, input}),
                ari_graph:out(inner_leave, {inner_body, exit})
            ]),
            ari_graph:in(inner_leave, {outer_back, input}),
            ari_graph:feedback(outer_next, {outer_back, output}, {outer_body, input}),
            ari_graph:out(leave, {outer_body, exit})
        ]),
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ].

nested_loops_test() ->
    Done = run(nested_loops_items(), [{input, [{m, {5, []}}]}]),
    ?assertEqual(#{output => [{m, {5, []}}]}, ari_local_runtime:outputs(Done)),
    ?assertEqual([], ari_local_runtime:violations(Done)),
    #{states := States} = ari_local_runtime:inspect(Done),
    %% два оборота внешнего цикла, в каждом — два оборота внутреннего
    ?assertMatch({_, 2}, maps:get(outer_back, States)),
    ?assertMatch({_, 4}, maps:get(inner_back, States)),
    %% source, sink, outer_body x3, outer_back x2, inner_body x6, inner_back x4
    ?assertEqual(17, ari_local_runtime:steps(Done)).

%% Уведомление во внешнем цикле ждёт сообщение из вложенного: сводка через
%% `egress` внутреннего цикла и `feedback` внешнего блокирует его до конца
%% итерации.
nested_loops_notification_test() ->
    Items = [
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(outer, [
            ari_graph:node(outer_body, ari_loop_node, #{turns => 2}),
            notify(agg),
            ari_graph:in(enter, {outer_body, input}),
            ari_graph:out(inner_enter, {outer_body, next}),
            ari_graph:edge(direct, {outer_body, next}, {agg, input}),
            ari_graph:loop(inner, [
                ari_graph:node(inner_body, ari_loop_node, #{turns => 2}),
                relay(inner_back),
                ari_graph:in(inner_enter, {inner_body, input}),
                ari_graph:edge(inner_to_back, {inner_body, next}, {inner_back, input}),
                ari_graph:feedback(inner_next, {inner_back, output}, {inner_body, input}),
                ari_graph:out(inner_leave, {inner_body, exit})
            ]),
            ari_graph:in(inner_leave, {agg, input}),
            ari_graph:feedback(outer_next, {agg, output}, {outer_body, input}),
            ari_graph:out(leave, {outer_body, exit})
        ]),
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ],
    Done = run(Items, [{input, [{m, {5, []}}]}]),
    %% на каждой итерации внешнего цикла `agg` собирает прямое сообщение и
    %% вышедшее из внутреннего цикла в один пакет
    ?assertEqual(
        #{output => [{{batch, [{batch, [m, m]}, {batch, [m, m]}]}, {5, []}}]},
        ari_local_runtime:outputs(Done)
    ),
    ?assertEqual([], ari_local_runtime:violations(Done)).

%% Нарушения не ломают инварианты: `b` роняет callback, `c` возвращает
%% результат не той формы, `d` нарушает правило времени.
violations_test() ->
    Items = [
        relay(a),
        relay(b, #{crash => true}),
        relay(c, #{result => broken}),
        relay(d, #{shift => -1}),
        notify(agg),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:edge(a_to_c, {a, output}, {c, input}),
        ari_graph:edge(a_to_d, {a, output}, {d, input}),
        ari_graph:edge(a_to_agg, {a, output}, {agg, input}),
        ari_graph:edge(b_to_agg, {b, output}, {agg, input}),
        ari_graph:edge(c_to_agg, {c, output}, {agg, input}),
        ari_graph:edge(d_to_agg, {d, output}, {agg, input}),
        ari_graph:out(output, {agg, output})
    ],
    Done = run(Items, [{input, [{m1, {5, []}}, {m2, {6, []}}]}]),
    ?assertEqual(
        #{output => [{{batch, [m1]}, {5, []}}, {{batch, [m2]}, {6, []}}]},
        ari_local_runtime:outputs(Done)
    ),
    Violations = ari_local_runtime:violations(Done),
    ?assertEqual(6, length(Violations)),
    ?assertEqual(
        [
            {crash, b, message, {5, []}},
            {invalid_result, c, message, {5, []}},
            {time_rule, d, message, {5, []}},
            {crash, b, message, {6, []}},
            {invalid_result, c, message, {6, []}},
            {time_rule, d, message, {6, []}}
        ],
        [{Kind, Node, Event, Time} || {Kind, Node, Event, Time, _} <- Violations]
    ).

%% Уведомление в цикле после сбоя узла: сообщение теряется, а запрос всё
%% равно исполняется, когда блокировавших его сообщений не остаётся.
loop_crash_test() ->
    Items = [
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(iteration, [
            ari_graph:node(body, ari_loop_node, #{turns => 2}),
            ari_graph:node(agg, ari_notify_node, #{crash_on => [{5, [1]}]}),
            relay(back),
            ari_graph:in(enter, {body, input}),
            ari_graph:edge(to_agg, {body, next}, {agg, input}),
            ari_graph:edge(to_back, {agg, output}, {back, input}),
            ari_graph:feedback(next, {back, output}, {body, input}),
            ari_graph:out(leave, {body, exit})
        ]),
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ],
    Done = run(Items, [{input, [{m1, {5, []}}, {m2, {6, []}}]}]),
    %% эпоха 5 обрывается на второй итерации, эпоха 6 проходит цикл целиком
    ?assertEqual(#{output => [{{batch, [{batch, [m2]}]}, {6, []}}]}, ari_local_runtime:outputs(Done)),
    ?assertMatch([{crash, agg, notification, {5, [1]}, {error, boom, _}}], ari_local_runtime:violations(Done)).
