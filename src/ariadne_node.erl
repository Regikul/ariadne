%% @doc Определяет контракт узла dataflow-графа Ariadne.
-module(ariadne_node).

-include("ariadne.hrl").

%% @doc Возвращает статический список входных слотов узла.
-callback input() -> [slot()].

%% @doc Возвращает статический список выходных слотов узла.
-callback output() -> [slot()].

%% @doc Создаёт начальное состояние и запросы уведомлений узла.
-callback init(Args :: term()) -> {State :: term(), Notifications :: [term()]}.

%% @doc Обрабатывает сообщение, пришедшее в указанный входной слот.
-callback handle_message(
    InputSlot :: slot(),
    Message :: term(),
    Time :: term(),
    State :: term()
) ->
    {NewState :: term(), Notifications :: [term()], Outputs :: [output()]}.

%% @doc Обрабатывает уведомление о завершении логического времени.
-callback handle_notification(Time :: term(), State :: term()) ->
    {NewState :: term(), Notifications :: [term()], Outputs :: [output()]}.

-type output() :: {OutputSlot :: slot(), Message :: term(), Time :: term()}.
