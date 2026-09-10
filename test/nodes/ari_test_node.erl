%% @doc Минимальная реализация узла для тестов графового DSL.
-module(ari_test_node).

-behaviour(ariadne_node).

-export([
    handle_message/4,
    handle_notification/2,
    init/1,
    input/0,
    output/0
]).

%% @doc Объявляет единственный входной слот тестового узла.
input() ->
    [input].

%% @doc Объявляет единственный выходной слот тестового узла.
output() ->
    [output].

%% @doc Использует аргументы узла как его начальное состояние.
init(Args) ->
    {Args, []}.

%% @doc Оставляет состояние неизменным и не создаёт выходов.
handle_message(_InputSlot, _Message, _Time, State) ->
    {State, [], []}.

%% @doc Оставляет состояние неизменным после уведомления.
handle_notification(_Time, State) ->
    {State, [], []}.
