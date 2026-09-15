%% A vertex keeping every message it is given and sending nothing.
-module(ari_test_hoarder).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [out].

init(_Args) -> [].

handle_message(in, Message, _Time, Kept) ->
    {[Message | Kept], [], []}.

handle_notification(_Time, Kept) ->
    {Kept, []}.

terminate(_Kept) -> ok.
