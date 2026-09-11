%% @doc Узел тела цикла: гонит сообщение по кругу заданное число оборотов.
%%
%% `Args` — map с ключом `turns`: число оборотов или `infinity`. Пока
%% координата текущего цикла меньше `turns`, сообщение уходит в слот `next`,
%% иначе — в слот `exit`. Время не меняется: преобразования выполняют рёбра.
-module(ari_loop_node).

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

%% @doc Объявляет слоты продолжения и выхода из цикла.
output() ->
    [next, exit].

%% @doc Запоминает число оборотов.
init(#{turns := Turns}) ->
    {Turns, []}.

%% @doc Выбирает слот по координате текущего цикла.
handle_message(input, Message, {_Epoch, [Iteration | _]} = Time, Turns) ->
    Slot =
        case Iteration < Turns of
            true -> next;
            false -> exit
        end,
    {Turns, [], [{Slot, Message, Time}]}.

%% @doc Уведомлений узел не запрашивает.
handle_notification(_Time, State) ->
    {State, [], []}.
