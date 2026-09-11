%% @doc Узел, пересылающий каждое сообщение дальше; поведение задаёт `Args`.
%%
%% `Args` — map с ключами:
%%
%% - `shift` — сдвиг эпохи выходного времени, по умолчанию `0`;
%% - `emit` — список выходных слотов, в которые пересылается сообщение,
%%   по умолчанию `[output]`; неизвестный слот вызывает ошибку маршрутизации;
%% - `request` — список сдвигов эпохи; на каждое сообщение узел запрашивает
%%   уведомления о сдвинутых временах, по умолчанию `[]`;
%% - `crash` — при `true` обработчик сообщения бросает `error(boom)`;
%% - `result` — если задан, обработчик возвращает этот терм как есть.
%%
%% Состояние — число обработанных сообщений.
-module(ari_relay_node).

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

%% @doc Запоминает настройки и начинает счёт с нуля.
init(Args) ->
    {{Args, 0}, []}.

%% @doc Пересылает сообщение по настройкам `Args`.
handle_message(input, Message, Time, {Args, Count}) ->
    case Args of
        #{crash := true} ->
            erlang:error(boom);
        #{result := Result} ->
            Result;
        _ ->
            Shifted = shift(Time, maps:get(shift, Args, 0)),
            Outputs = [{Slot, Message, Shifted} || Slot <- maps:get(emit, Args, [output])],
            Requests = [shift(Time, Delta) || Delta <- maps:get(request, Args, [])],
            {{Args, Count + 1}, Requests, Outputs}
    end.

%% @doc Уведомлений узел не запрашивает.
handle_notification(_Time, State) ->
    {State, [], []}.

shift({Epoch, Iterations}, Delta) ->
    {Epoch + Delta, Iterations}.
