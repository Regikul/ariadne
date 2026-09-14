%% A vertex tracking the iterations of a loop: it increments a number
%% until it reaches the limit given as the arguments, the way
%% ari_test_until does, and asks to be notified at the time of every
%% message. Every notification is reported to `done' as the number of
%% notifications so far together with the time notified of.
-module(ari_test_tracker).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [continue, done].

init(Limit) -> {Limit, 0}.

handle_message(in, N, Time, {Limit, _Notified} = State) when N < Limit ->
    {State, [Time], [{continue, N + 1, Time}]};
handle_message(in, _N, Time, State) ->
    {State, [Time], []}.

handle_notification(Time, {Limit, Notified}) ->
    {{Limit, Notified + 1}, [{done, {Notified + 1, Time}, Time}]}.

terminate(_State) -> ok.
