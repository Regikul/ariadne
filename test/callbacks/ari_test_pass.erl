%% A vertex passing every message from `in' to `out' as it is.
-module(ari_test_pass).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [out].

init(_Args) -> undefined.

handle_message(in, Message, Time, State) ->
    {State, [], [{out, Message, Time}]}.

handle_notification(_Time, State) ->
    {State, []}.

terminate(_State) -> ok.
