%% @doc Замеры локального runtime на воспроизводимых нагрузках.
%%
%% Модуль собирается только в профиле `test`. Запуск:
%%
%% ```
%% ./silent_rebar3 as test shell --eval 'ari_local_runtime_bench:run(), halt().'
%% ```
%%
%% Три замера отвечают трём частям runtime:
%%
%% - `summaries/0` — сборка сводок путей в `compile/1` на цепочках узлов
%%   в плоском графе, в одном цикле и в трёх вложенных циклах;
%% - `throughput/0` — переходы в секунду на цепочке пересылающих узлов без
%%   запросов уведомлений, при одном и при разных временах сообщений;
%% - `recheck/0` — стоимость пересчёта допустимости после шага при растущем
%%   числе ожидающих запросов и живых pointstamp'ов;
%% - `initial/0` — `new/2` и `advance/2` отдельно для узла с начальными
%%   запросами, образующими широкий фронтир несравнимых времён;
%% - `violations/0` — накопление нарушений: узел нарушает правило времени
%%   на каждом сообщении, и список нарушений растёт с числом шагов;
%% - `sources/0` — несколько источников одного узла-получателя: на шаге
%%   меняется фронтир одного источника, остальные блокируют запросы.
%%
%% Результаты и условия воспроизведения записаны в
%% `okf/design/local-runtime-performance.md`.
-module(ari_local_runtime_bench).

-export([initial/0, recheck/0, run/0, sources/0, summaries/0, throughput/0, violations/0]).

-define(REPEAT, 5).

%% @doc Выполняет все замеры и печатает таблицы.
run() ->
    io:format("~n== summaries: compile/1 ==~n"),
    summaries(),
    io:format("~n== throughput: steps per second ==~n"),
    throughput(),
    io:format("~n== recheck: microseconds per step ==~n"),
    recheck(),
    io:format("~n== initial: wide frontier of initial requests ==~n"),
    initial(),
    io:format("~n== violations: accumulation ==~n"),
    violations(),
    io:format("~n== sources: several sources of one receiver ==~n"),
    sources(),
    ok.

%% Сборка сводок.

%% @doc Измеряет `compile/1`: медиана по повторам, размер таблицы сводок.
summaries() ->
    io:format("~-24s ~6s ~10s ~10s~n", ["graph", "nodes", "us", "pairs"]),
    lists:foreach(
        fun({Label, Graph}) ->
            {ok, Program} = ari_local_runtime:compile(Graph),
            #{summaries := Summaries, node_order := Nodes} = ari_local_runtime:inspect(Program),
            Micros = median(fun() -> {ok, _} = ari_local_runtime:compile(Graph) end),
            io:format("~-24s ~6b ~10b ~10b~n", [Label, length(Nodes), Micros, maps:size(Summaries)])
        end,
        [
            {"flat chain", flat_chain(N)}
         || N <- [10, 20, 40, 80]
        ] ++
            [
                {"loop chain", loop_chain(N)}
             || N <- [10, 20, 40]
            ] ++
            [
                {"nested x3", nested_chain(N, 3)}
             || N <- [4, 8, 16]
            ]
    ).

%% Цепочка `n1 -> n2 -> ... -> nN` в плоском графе.
flat_chain(N) ->
    ari_graph:graph(chain_items(N)).

chain_items(N) ->
    Names = names(N),
    [relay(Name) || Name <- Names] ++
        [ari_graph:in(input, {hd(Names), input}), ari_graph:out(output, {lists:last(Names), output})] ++
        chain_edges(Names).

chain_edges([From, To | Rest]) ->
    [ari_graph:edge(edge_name(From, To), {From, output}, {To, input}) | chain_edges([To | Rest])];
chain_edges([_Last]) ->
    [].

%% Та же цепочка внутри одного цикла с обратным ребром от конца к началу.
loop_chain(N) ->
    ari_graph:graph(loop_chain_items(N)).

loop_chain_items(N) ->
    Names = names(N),
    [
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter, {source, output}),
        ari_graph:loop(loop, [
            ari_graph:in(enter, {hd(Names), input}),
            ari_graph:feedback(next, {lists:last(Names), output}, {hd(Names), input}),
            ari_graph:out(leave, {lists:last(Names), output})
            | [relay(Name) || Name <- Names] ++ chain_edges(Names)
        ]),
        relay(sink),
        ari_graph:in(leave, {sink, input}),
        ari_graph:out(output, {sink, output})
    ].

%% `Depth` вложенных циклов, на каждом уровне цепочка из `N` узлов
%% и обратное ребро; внутренний цикл вставлен в середину цепочки.
nested_chain(N, Depth) ->
    ari_graph:graph([
        relay(source),
        ari_graph:in(input, {source, input}),
        ari_graph:out(enter_1, {source, output}),
        nested_loop(N, 1, Depth),
        relay(sink),
        ari_graph:in(leave_1, {sink, input}),
        ari_graph:out(output, {sink, output})
    ]).

nested_loop(N, Level, Depth) ->
    Names = [name("l~b_n~b", [Level, I]) || I <- lists:seq(1, N)],
    {Front, Back} = lists:split(N div 2, Names),
    Inner =
        case Level < Depth of
            true ->
                [
                    ari_graph:out(name("enter_~b", [Level + 1]), {lists:last(Front), output}),
                    nested_loop(N, Level + 1, Depth),
                    ari_graph:in(name("leave_~b", [Level + 1]), {hd(Back), input})
                ];
            false ->
                [ari_graph:edge(edge_name(lists:last(Front), hd(Back)), {lists:last(Front), output}, {hd(Back), input})]
        end,
    ari_graph:loop(name("loop_~b", [Level]), [
        ari_graph:in(name("enter_~b", [Level]), {hd(Names), input}),
        ari_graph:feedback(name("next_~b", [Level]), {lists:last(Names), output}, {hd(Names), input}),
        ari_graph:out(name("leave_~b", [Level]), {lists:last(Names), output})
        | [relay(Name) || Name <- Names] ++ chain_edges(Front) ++ chain_edges(Back) ++ Inner
    ]).

%% Пропускная способность.

%% @doc Измеряет переходы в секунду на цепочке из десяти узлов.
throughput() ->
    io:format("~-24s ~8s ~10s ~12s~n", ["load", "messages", "steps", "steps/s"]),
    Graph = flat_chain(10),
    {ok, Program} = ari_local_runtime:compile(Graph),
    lists:foreach(
        fun({Label, Messages}) ->
            {ok, Execution} = ari_local_runtime:new(Program, [{input, Messages}]),
            {Micros, {done, Done}} = timer:tc(fun() -> ari_local_runtime:advance(Execution, infinity) end),
            Steps = ari_local_runtime:steps(Done),
            io:format("~-24s ~8b ~10b ~12b~n", [Label, length(Messages), Steps, Steps * 1000000 div max(Micros, 1)])
        end,
        [
            {"same time", [{I, {5, []}} || I <- lists:seq(1, 10000)]},
            {"distinct times", [{I, {I, []}} || I <- lists:seq(1, 10000)]},
            {"same time x10", [{I, {5, []}} || I <- lists:seq(1, 100000)]}
        ]
    ).

%% Пересчёт допустимости.

%% @doc Измеряет микросекунды на шаг, когда узел-получатель запрашивает
%% уведомление на каждое сообщение. При возрастающих временах каждый запрос
%% исполняется до следующего, и пересчёт видит один запрос против всех
%% живых pointstamp'ов. При убывающих временах запросы копятся до конца
%% входа, и каждый шаг пересчитывает их все против всех pointstamp'ов.
recheck() ->
    io:format("~-24s ~8s ~10s ~12s~n", ["load", "messages", "steps", "us/step"]),
    lists:foreach(
        fun({Label, Module, Order, Count}) ->
            Items = [
                relay(a),
                ari_graph:node(agg, Module, #{}),
                ari_graph:in(input, {a, input}),
                ari_graph:edge(a_to_agg, {a, output}, {agg, input}),
                ari_graph:out(output, {agg, output})
            ],
            {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
            Times =
                case Order of
                    ascending -> lists:seq(1, Count);
                    descending -> lists:seq(Count, 1, -1)
                end,
            Messages = [{I, {I, []}} || I <- Times],
            {ok, Execution} = ari_local_runtime:new(Program, [{input, Messages}]),
            {Micros, {done, Done}} = timer:tc(fun() -> ari_local_runtime:advance(Execution, infinity) end),
            Steps = ari_local_runtime:steps(Done),
            io:format("~-24s ~8b ~10b ~12.1f~n", [Label, Count, Steps, Micros / Steps])
        end,
        [
            {"relay", ari_relay_node, ascending, 1000},
            {"notify ascending", ari_notify_node, ascending, 100},
            {"notify ascending", ari_notify_node, ascending, 1000},
            {"notify descending", ari_notify_node, descending, 100},
            {"notify descending", ari_notify_node, descending, 300},
            {"notify descending", ari_notify_node, descending, 1000}
        ]
    ).

%% Широкий фронтир.

%% @doc Измеряет `new/2` и `advance/2` для узла в цикле с начальными
%% запросами `{I, [N-I]}`: времена попарно несравнимы, все уведомления
%% допустимы с начала, вход пуст.
initial() ->
    io:format("~-24s ~8s ~10s ~12s~n", ["load", "requests", "new us", "advance us"]),
    lists:foreach(
        fun(Count) ->
            Initial = [{I, [Count - I]} || I <- lists:seq(1, Count)],
            Items = [
                ari_graph:loop(iteration, [
                    ari_graph:node(agg, ari_notify_node, #{initial => Initial})
                ])
            ],
            {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
            {NewMicros, {ok, Execution}} = timer:tc(fun() -> ari_local_runtime:new(Program, []) end),
            {AdvanceMicros, {done, Done}} = timer:tc(fun() -> ari_local_runtime:advance(Execution, infinity) end),
            Count = ari_local_runtime:steps(Done),
            io:format("~-24s ~8b ~10b ~12b~n", ["incomparable", Count, NewMicros, AdvanceMicros])
        end,
        [100, 200, 400, 800]
    ).

%% Нарушения.

%% @doc Измеряет прогон, в котором узел `b` сдвигает время назад и получает
%% `time_rule` на каждом сообщении; `a` пересылает без нарушений для
%% сравнения с обычной пересылкой.
violations() ->
    io:format("~-24s ~8s ~10s ~12s~n", ["load", "messages", "violations", "us/step"]),
    Items = [
        relay(a),
        ari_graph:node(b, ari_relay_node, #{shift => -1}),
        ari_graph:in(input, {a, input}),
        ari_graph:edge(a_to_b, {a, output}, {b, input}),
        ari_graph:out(output, {b, output})
    ],
    {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
    lists:foreach(
        fun(Count) ->
            Messages = [{I, {5, []}} || I <- lists:seq(1, Count)],
            {ok, Execution} = ari_local_runtime:new(Program, [{input, Messages}]),
            {Micros, {done, Done}} = timer:tc(fun() -> ari_local_runtime:advance(Execution, infinity) end),
            Steps = ari_local_runtime:steps(Done),
            Violations = length(ari_local_runtime:violations(Done)),
            io:format("~-24s ~8b ~10b ~12.1f~n", ["time_rule each", Count, Violations, Micros / Steps])
        end,
        [1000, 3000, 10000]
    ).

%% Несколько источников.

%% @doc Измеряет прогон, где `K` пересылающих узлов кормят один `agg`,
%% запрашивающий уведомление на каждое сообщение. Времена чередуются между
%% источниками, поэтому запрос блокируется чужим источником, а на шаге
%% меняется фронтир только одного из них.
sources() ->
    io:format("~-24s ~8s ~10s ~12s~n", ["load", "sources", "steps", "us/step"]),
    lists:foreach(
        fun(K) ->
            Names = [name("s~b", [I]) || I <- lists:seq(1, K)],
            Items =
                [relay(Name) || Name <- Names] ++
                    [ari_graph:node(agg, ari_notify_node, #{}), ari_graph:out(output, {agg, output})] ++
                    [ari_graph:in(name("in_~s", [Name]), {Name, input}) || Name <- Names] ++
                    [ari_graph:edge(name("~s_to_agg", [Name]), {Name, output}, {agg, input}) || Name <- Names],
            {ok, Program} = ari_local_runtime:compile(ari_graph:graph(Items)),
            Inputs = [
                {name("in_~s", [Name]), [{T, {T, []}} || T <- lists:seq(I, 1000, K)]}
             || {I, Name} <- lists:zip(lists:seq(1, K), Names)
            ],
            {ok, Execution} = ari_local_runtime:new(Program, Inputs),
            {Micros, {done, Done}} = timer:tc(fun() -> ari_local_runtime:advance(Execution, infinity) end),
            Steps = ari_local_runtime:steps(Done),
            io:format("~-24s ~8b ~10b ~12.1f~n", ["interleaved", K, Steps, Micros / Steps])
        end,
        [1, 10, 100]
    ).

%% Вспомогательные функции.

relay(Name) ->
    ari_graph:node(Name, ari_relay_node, #{}).

names(N) ->
    [name("n~b", [I]) || I <- lists:seq(1, N)].

name(Format, Args) ->
    list_to_atom(lists:flatten(io_lib:format(Format, Args))).

edge_name(From, To) ->
    name("~s_to_~s", [From, To]).

median(Fun) ->
    Times = lists:sort([element(1, timer:tc(Fun)) || _ <- lists:seq(1, ?REPEAT)]),
    lists:nth((?REPEAT + 1) div 2, Times).
