%%%-------------------------------------------------------------------
%% @doc ariadne public API
%% @end
%%%-------------------------------------------------------------------

-module(ariadne_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ariadne_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
