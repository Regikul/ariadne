%% A vertex passing every message from `in' to `out' and reporting its
%% termination: the arguments are the name to report and the process
%% to report it to.
-module(ari_test_reporter).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [out].

init({Name, Pid}) -> {Name, Pid}.

handle_message(in, Message, Time, State) ->
    {State, [], [{out, Message, Time}]}.

handle_notification(_Time, State) ->
    {State, []}.

terminate({Name, Pid}) ->
    Pid ! {terminated, Name},
    ok.
