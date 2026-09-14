%% A vertex incrementing a number until it reaches the limit given as
%% the arguments: a number below the limit goes on to `continue'
%% incremented, one at the limit or above it goes to `done' as it is.
-module(ari_test_until).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [continue, done].

init(Limit) -> Limit.

handle_message(in, N, Time, Limit) when N < Limit ->
    {Limit, [], [{continue, N + 1, Time}]};
handle_message(in, N, Time, Limit) ->
    {Limit, [], [{done, N, Time}]}.

handle_notification(_Time, Limit) ->
    {Limit, []}.

terminate(_State) -> ok.
