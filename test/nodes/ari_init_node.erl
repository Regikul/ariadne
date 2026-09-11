%% @doc Узел с настраиваемой инициализацией для тестов `new/2`.
%%
%% `Args` выбирает поведение `init/1`: `{ok, State, Notifications}` возвращает
%% заданные состояние и запросы, `{crash, Reason}` бросает `error(Reason)`,
%% `{return, Term}` возвращает `Term` как есть. Сообщения и уведомления
%% узел игнорирует.
-module(ari_init_node).

-behaviour(ariadne_node).

-export([
    handle_message/4,
    handle_notification/2,
    init/1,
    input/0,
    output/0
]).

%% @doc Объявляет единственный входной слот.
input() ->
    [input].

%% @doc Объявляет единственный выходной слот.
output() ->
    [output].

%% @doc Инициализирует узел по сценарию из `Args`.
init({ok, State, Notifications}) ->
    {State, Notifications};
init({crash, Reason}) ->
    erlang:error(Reason);
init({return, Term}) ->
    Term.

%% @doc Оставляет состояние неизменным и не создаёт выходов.
handle_message(_InputSlot, _Message, _Time, State) ->
    {State, [], []}.

%% @doc Оставляет состояние неизменным после уведомления.
handle_notification(_Time, State) ->
    {State, [], []}.
