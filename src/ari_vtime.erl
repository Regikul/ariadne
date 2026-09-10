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

%% @doc Проверяет покомпонентный частичный порядок времён одной глубины.
-spec le(t(), t()) -> boolean().
le({TimeA, IterationsA}, {TimeB, IterationsB}) ->
    TimeA =< TimeB andalso iterations_le(IterationsA, IterationsB).

iterations_le([], []) ->
    true;
iterations_le([IterationA | RestA], [IterationB | RestB]) ->
    IterationA =< IterationB andalso iterations_le(RestA, RestB).
