%% A vertex asking, on every message, to be notified at the epochs
%% given as the arguments, and reporting every notification to `done'.
-module(ari_test_waiter).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [done].

init(Epochs) -> Epochs.

handle_message(in, _Message, _Time, Epochs) ->
    {Epochs, [ari_vtime:new(Epoch) || Epoch <- Epochs], []}.

handle_notification(Time, Epochs) ->
    {Epochs, [{done, fired, Time}]}.

terminate(_State) -> ok.
