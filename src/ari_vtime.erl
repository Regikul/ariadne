%% @doc Представляет многомерное логическое время Ariadne.
%%
%% Время состоит из базовой эпохи и стека координат вложенных циклов.
%% Голова стека относится к текущему, самому внутреннему циклу.
%% `ingress/1`, `feedback/1` и `egress/1` реализуют преобразования времени
%% на соответствующих специальных рёбрах графа.
%%
%% Сводка пути описывает композицию преобразований вдоль рёбер в нормальной
%% форме «снять, увеличить, добавить». `summary/1` даёт сводку одного ребра,
%% `compose/2` соединяет два пути, `transfer/2` переносит время по пути,
%% `dominates/2` сравнивает сводки одной формы.
-module(ari_vtime).

-export([egress/1, feedback/1, ingress/1, le/2, new/1]).
-export([compose/2, dominates/2, summary/1, summary/3, transfer/2]).
-export_type([kind/0, summary/0, t/0]).

-opaque t() :: {integer(), [non_neg_integer()]}.

-type kind() :: message | ingress | egress | feedback.

-record(summary, {
    %% Добавленные координаты, внутренняя первой.
    push = [] :: [non_neg_integer()],
    %% Прибавка к внутренней уцелевшей координате.
    bump = 0 :: non_neg_integer(),
    %% Снятые координаты циклов.
    pop = 0 :: non_neg_integer()
}).

-opaque summary() :: #summary{}.

%% @doc Создаёт время базовой эпохи вне циклов.
-spec new(integer()) -> t().
new(Time) when is_integer(Time) ->
    {Time, []}.

%% @doc Входит в цикл и добавляет его начальную координату.
-spec ingress(t()) -> t().
ingress({Time, Iterations}) ->
    {Time, [0 | Iterations]}.

%% @doc Выходит из текущего цикла и удаляет его координату.
-spec egress(t()) -> t().
egress({Time, [_Iteration | OuterIterations]}) ->
    {Time, OuterIterations}.

%% @doc Переходит к следующей итерации текущего цикла.
-spec feedback(t()) -> t().
feedback({Time, [Iteration | OuterIterations]}) ->
    {Time, [Iteration + 1 | OuterIterations]}.

%% @doc Сравнивает эпохи и, независимо, векторы итераций одной глубины.
%% Итерации сравниваются лексикографически от внешнего цикла к внутреннему.
-spec le(t(), t()) -> boolean().
le({TimeA, IterationsA}, {TimeB, IterationsB}) ->
    TimeA =< TimeB andalso iterations_compare(IterationsA, IterationsB) =/= greater.

iterations_compare([], []) ->
    equal;
iterations_compare([IterationA | RestA], [IterationB | RestB]) ->
    case iterations_compare(RestA, RestB) of
        equal when IterationA < IterationB -> less;
        equal when IterationA > IterationB -> greater;
        Order -> Order
    end.

%% @doc Возвращает сводку одного ребра указанного вида.
-spec summary(kind()) -> summary().
summary(message) -> #summary{};
summary(ingress) -> #summary{push = [0]};
summary(feedback) -> #summary{bump = 1};
summary(egress) -> #summary{pop = 1}.

%% @doc Создаёт сводку из компонентов нормальной формы.
-spec summary(non_neg_integer(), non_neg_integer(), [non_neg_integer()]) -> summary().
summary(Pop, Bump, Push) ->
    #summary{pop = Pop, bump = Bump, push = Push}.

%% @doc Переносит время по пути: снимает `pop` координат, увеличивает
%% уцелевшую голову на `bump` и кладёт сверху `push`.
-spec transfer(summary(), t()) -> t().
transfer(#summary{pop = Pop, bump = Bump, push = Push}, {Time, Iterations}) ->
    case lists:nthtail(Pop, Iterations) of
        [] -> {Time, Push};
        [Iteration | Rest] -> {Time, Push ++ [Iteration + Bump | Rest]}
    end.

%% @doc Соединяет путь `First` с продолжением `Second`.
%%
%% Второй путь снимает координаты сверху результата первого. Пока снятое
%% укладывается в `push` первого, уцелевшая координата и `bump` первого
%% сохраняются. Ровно исчерпав `push`, второй путь увеличивает ту же
%% уцелевшую координату, и прибавки складываются. Сняв больше, второй путь
%% снимает и уцелевшую координату первого вместе с его `bump`.
-spec compose(summary(), summary()) -> summary().
compose(
    #summary{pop = Pop1, bump = Bump1, push = Push1},
    #summary{pop = Pop2, bump = Bump2, push = Push2}
) ->
    Pushed = length(Push1),
    if
        Pop2 < Pushed ->
            [Head | Rest] = lists:nthtail(Pop2, Push1),
            #summary{pop = Pop1, bump = Bump1, push = Push2 ++ [Head + Bump2 | Rest]};
        Pop2 =:= Pushed ->
            #summary{pop = Pop1, bump = Bump1 + Bump2, push = Push2};
        Pop2 > Pushed ->
            #summary{pop = Pop1 + Pop2 - Pushed, bump = Bump2, push = Push2}
    end.

%% @doc Проверяет, что первая сводка даёт время не больше второй на любом
%% входе. Сравнимы только сводки одной формы: с равным `pop` и равной
%% длиной `push`; они сравниваются покомпонентно по `bump` и `push`.
-spec dominates(summary(), summary()) -> boolean().
dominates(
    #summary{pop = Pop, bump = BumpA, push = PushA},
    #summary{pop = Pop, bump = BumpB, push = PushB}
) when length(PushA) =:= length(PushB) ->
    BumpA =< BumpB andalso
        lists:all(fun({A, B}) -> A =< B end, lists:zip(PushA, PushB));
dominates(#summary{}, #summary{}) ->
    false.
