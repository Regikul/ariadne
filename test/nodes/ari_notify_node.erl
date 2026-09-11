%% @doc Узел, копящий сообщения до уведомления об их времени.
%%
%% На каждое сообщение узел запрашивает уведомление о его времени. По
%% уведомлению выдаёт `{batch, Messages}` в `output` с этим временем.
%%
%% `Args` — map с ключами:
%%
%% - `initial` — запросы уведомлений из `init/1`, по умолчанию `[]`;
%% - `on_notify` — map «время уведомления => запросы», которые обработчик
%%   уведомления делает один раз, после чего запись удаляется;
%% - `crash_on` — список времён, уведомление о которых бросает `error(boom)`.
-module(ari_notify_node).

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

%% @doc Запоминает настройки и делает начальные запросы.
init(Args) ->
    {Args#{pending => #{}}, maps:get(initial, Args, [])}.

%% @doc Откладывает сообщение и запрашивает уведомление о его времени.
handle_message(input, Message, Time, #{pending := Pending} = State) ->
    Batch = maps:get(Time, Pending, []),
    {State#{pending := Pending#{Time => Batch ++ [Message]}}, [Time], []}.

%% @doc Выдаёт накопленные сообщения времени и повторные запросы из `on_notify`.
handle_notification(Time, #{pending := Pending} = State) ->
    lists:member(Time, maps:get(crash_on, State, [])) andalso erlang:error(boom),
    OnNotify = maps:get(on_notify, State, #{}),
    Requests = maps:get(Time, OnNotify, []),
    NewState = State#{pending := maps:remove(Time, Pending), on_notify => maps:remove(Time, OnNotify)},
    {NewState, Requests, [{output, {batch, maps:get(Time, Pending, [])}, Time}]}.
