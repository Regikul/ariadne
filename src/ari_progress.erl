%% @doc Решает, допустимо ли уведомление о времени в узле.
%%
%% Уведомление `(X, T)` допустимо, когда ни одно живое сообщение и ни один
%% запрос уведомления не способны породить сообщение с временем `T' =< T` на
%% входе `X`. Сообщение блокирует уведомление прямым сравнением, если уже
%% лежит на входе `X`, и через сводки непустых путей из своего узла.
%% Запрос блокирует только через сводки непустых путей: сам по себе он
%% нового входа не создаёт.
%%
%% Функции чистые и не зависят от состояния прогона: они получают счётчики
%% живых сообщений, запросы и таблицу сводок явно.
-module(ari_progress).

-include("ariadne.hrl").

-export([admissible/5, message_blocks/5, request_blocks/5]).
-export_type([counts/0, requests/0, summaries/0]).

%% Живые сообщения по pointstamp'ам: ключ покрывает все сообщения времени `T`
%% на входящих рёбрах узла `X`.
-type counts() :: #{{name(), ari_vtime:t()} => pos_integer()}.

%% Ожидающие запросы уведомлений каждого узла.
-type requests() :: #{name() => ordsets:ordset(ari_vtime:t())}.

%% Антицепи минимальных сводок непустых путей между узлами.
-type summaries() :: #{{name(), name()} => [ari_vtime:summary()]}.

%% @doc Проверяет уведомление `(Node, Time)` против всех сообщений и запросов.
-spec admissible(name(), ari_vtime:t(), counts(), requests(), summaries()) -> boolean().
admissible(Node, Time, Counts, Requests, Summaries) ->
    MessageBlocks = fun({Source, Stamp}, _Count) ->
        message_blocks(Source, Stamp, Node, Time, Summaries)
    end,
    RequestBlocks = fun(Source, Stamps) ->
        lists:any(
            fun(Stamp) -> request_blocks(Source, Stamp, Node, Time, Summaries) end,
            Stamps
        )
    end,
    not (any(MessageBlocks, Counts) orelse any(RequestBlocks, Requests)).

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

any(Predicate, Map) ->
    maps:fold(fun(Key, Value, Found) -> Found orelse Predicate(Key, Value) end, false, Map).
