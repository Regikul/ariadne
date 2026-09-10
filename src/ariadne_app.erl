%% @doc Запускает OTP-приложение Ariadne.
-module(ariadne_app).

-behaviour(application).

-export([start/2, stop/1]).

%% @doc Запускает корневой супервизор приложения.
start(_StartType, _StartArgs) ->
    ariadne_sup:start_link().

%% @doc Завершает работу приложения.
stop(_State) ->
    ok.
