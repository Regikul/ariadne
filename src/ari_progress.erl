%% @doc Решает, допустимо ли уведомление о времени в узле.
%%
%% Уведомление `(X, T)` допустимо, когда ни одно живое сообщение и ни один
%% запрос уведомления не способны породить сообщение с временем `T' =< T` на
%% входе `X`. Сообщение блокирует уведомление прямым сравнением, если уже
%% лежит на входе `X`, и через сводки непустых путей из своего узла.
%% Запрос блокирует только через сводки непустых путей: сам по себе он
%% нового входа не создаёт.
%%
%% Блокировка монотонна по времени источника: если время `U` блокирует
%% уведомление, его блокирует и любое `U' =< U`. Поэтому проверка идёт по
%% фронтирам: минимальным временам каждого узла среди живых сообщений и
%% среди запросов. `blocker/5` возвращает первое блокирующее время — оно
%% служит runtime свидетелем блокировки — или `none`.
%%
%% Узкий фронтир строится вставкой, широкий — сортировкой и одним проходом:
%% `le/2` — произведение линейного порядка эпох и лексикографического
%% порядка итераций одной глубины, поэтому после сортировки время
%% минимально ровно тогда, когда его итерации строго меньше, чем у
%% последнего оставленного.
%%
%% Функции чистые и не зависят от состояния прогона: они получают фронтиры,
%% счётчики живых сообщений, запросы и таблицу сводок явно.
-module(ari_progress).

-include("ariadne.hrl").

%% Ширина антицепи, после которой фронтир достраивается сортировкой.
-define(WIDE, 8).

-export([
    admissible/5,
    blocker/5,
    insert/3,
    message_blocks/5,
    message_frontier/1,
    minimal/1,
    request_blocks/5,
    request_frontier/1
]).
-export_type([blocker/0, counts/0, frontier/0, requests/0, summaries/0]).

%% Живые сообщения по pointstamp'ам: счётчик времени `T` у узла `X`
%% покрывает все сообщения этого времени на входящих рёбрах узла.
-type counts() :: #{name() => #{ari_vtime:t() => pos_integer()}}.

%% Ожидающие запросы уведомлений каждого узла.
-type requests() :: #{name() => ordsets:ordset(ari_vtime:t())}.

%% Антицепи минимальных сводок непустых путей между узлами.
-type summaries() :: #{{name(), name()} => [ari_vtime:summary()]}.

%% Минимальные времена каждого узла: антицепь без порядка элементов.
-type frontier() :: #{name() => [ari_vtime:t()]}.

%% Время фронтира сообщений или запросов, блокирующее уведомление.
-type blocker() :: {message | request, name(), ari_vtime:t()}.

%% @doc Проверяет уведомление `(Node, Time)` против фронтиров сообщений
%% и запросов.
-spec admissible(name(), ari_vtime:t(), frontier(), frontier(), summaries()) -> boolean().
admissible(Node, Time, Messages, Requests, Summaries) ->
    blocker(Node, Time, Messages, Requests, Summaries) =:= none.

%% @doc Находит время фронтира, блокирующее уведомление `(Node, Time)`,
%% или `none`. Сводки пары узлов берутся один раз на узел-источник;
%% источник без пути к `Node` и без прямого сравнения пропускается целиком.
-spec blocker(name(), ari_vtime:t(), frontier(), frontier(), summaries()) -> none | blocker().
blocker(Node, Time, Messages, Requests, Summaries) ->
    case search(message, Node, Time, Messages, Summaries) of
        none -> search(request, Node, Time, Requests, Summaries);
        Blocker -> Blocker
    end.

search(Kind, Node, Time, Frontier, Summaries) ->
    maps:fold(
        fun
            (Source, Stamps, none) ->
                Direct = Kind =:= message andalso Source =:= Node,
                case blocking(Stamps, Direct, Time, maps:get({Source, Node}, Summaries, [])) of
                    none -> none;
                    Stamp -> {Kind, Source, Stamp}
                end;
            (_Source, _Stamps, Found) ->
                Found
        end,
        none,
        Frontier
    ).

blocking(_Stamps, false, _Time, []) ->
    none;
blocking(Stamps, Direct, Time, Paths) ->
    case
        lists:search(
            fun(Stamp) ->
                (Direct andalso ari_vtime:le(Stamp, Time)) orelse
                    lists:any(fun(Path) -> ari_vtime:le(ari_vtime:transfer(Path, Stamp), Time) end, Paths)
            end,
            Stamps
        )
    of
        {value, Stamp} -> Stamp;
        false -> none
    end.

%% @doc Добавляет время в фронтир узла и возвращает вытесненные времена.
%% Доминируемое время фронтир не меняет, доминирующее вытесняет большие.
-spec insert(name(), ari_vtime:t(), frontier()) -> {frontier(), [ari_vtime:t()]}.
insert(Node, Time, Frontier) ->
    Kept = maps:get(Node, Frontier, []),
    case lists:any(fun(Known) -> ari_vtime:le(Known, Time) end, Kept) of
        true ->
            {Frontier, []};
        false ->
            {Dropped, Rest} = lists:partition(fun(Known) -> ari_vtime:le(Time, Known) end, Kept),
            {maps:put(Node, [Time | Rest], Frontier), Dropped}
    end.

%% @doc Строит фронтир живых сообщений по `counts`.
-spec message_frontier(counts()) -> frontier().
message_frontier(Counts) ->
    maps:map(fun(_Node, Times) -> minimal(maps:keys(Times)) end, Counts).

%% @doc Строит фронтир запросов уведомлений.
-spec request_frontier(requests()) -> frontier().
request_frontier(Requests) ->
    maps:map(fun(_Node, Times) -> minimal(Times) end, Requests).

%% @doc Оставляет минимальные времена списка.
-spec minimal([ari_vtime:t()]) -> [ari_vtime:t()].
minimal(Times) ->
    finish(lists:foldl(fun add/2, {narrow, []}, Times)).

%% Построение антицепи минимальных времён одной глубины. Узкая антицепь
%% строится вставкой: каждое время сравнивается с оставленными. Когда
%% оставленных больше `?WIDE`, дальнейшие времена копятся как есть, и в
%% конце весь список сортируется и проходится один раз: после сортировки
%% эпоха не убывает, и время не доминируется ни одним оставленным ровно
%% тогда, когда его итерации строго меньше, чем у последнего оставленного.
%% Оставленные до переключения минимумы достаточны: отброшенные ими времена
%% доминируются и после сортировки.
add(Time, {narrow, Kept}) ->
    case lists:any(fun(Known) -> ari_vtime:le(Known, Time) end, Kept) of
        true ->
            {narrow, Kept};
        false ->
            Next = [Time | [Known || Known <- Kept, not ari_vtime:le(Time, Known)]],
            case length(Next) > ?WIDE of
                true -> {wide, Next};
                false -> {narrow, Next}
            end
    end;
add(Time, {wide, Times}) ->
    {wide, [Time | Times]}.

finish({narrow, Kept}) ->
    Kept;
finish({wide, Times}) ->
    skyline(ari_vtime:sort(Times)).

skyline(Sorted) ->
    lists:foldl(
        fun(Time, []) ->
            [Time];
           (Time, [Last | _] = Kept) ->
            case ari_vtime:le(Last, Time) of
                true -> Kept;
                false -> [Time | Kept]
            end
        end,
        [],
        Sorted
    ).

%% @doc Проверяет, способно ли сообщение времени `Stamp` на входе `Source`
%% породить сообщение времени `=< Time` на входе `Node`.
-spec message_blocks(name(), ari_vtime:t(), name(), ari_vtime:t(), summaries()) -> boolean().
message_blocks(Source, Stamp, Node, Time, Summaries) ->
    (Source =:= Node andalso ari_vtime:le(Stamp, Time)) orelse
        path_blocks(Source, Stamp, Node, Time, Summaries).

%% @doc Проверяет, способен ли запрос уведомления `(Source, Stamp)` породить
%% сообщение времени `=< Time` на входе `Node`.
-spec request_blocks(name(), ari_vtime:t(), name(), ari_vtime:t(), summaries()) -> boolean().
request_blocks(Source, Stamp, Node, Time, Summaries) ->
    path_blocks(Source, Stamp, Node, Time, Summaries).

path_blocks(Source, Stamp, Node, Time, Summaries) ->
    lists:any(
        fun(Summary) -> ari_vtime:le(ari_vtime:transfer(Summary, Stamp), Time) end,
        maps:get({Source, Node}, Summaries, [])
    ).
