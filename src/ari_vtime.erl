%% @doc Представляет многомерное логическое время Ariadne.
%%
%% Время состоит из базовой эпохи и стека координат вложенных циклов.
%% Голова стека относится к текущему, самому внутреннему циклу.
%% `ingress/1`, `feedback/1` и `egress/1` реализуют преобразования времени
%% на соответствующих специальных рёбрах графа.
-module(ari_vtime).

-export([egress/1, feedback/1, ingress/1, le/2, new/1]).
-export_type([t/0]).

-opaque t() :: {integer(), [non_neg_integer()]}.

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
