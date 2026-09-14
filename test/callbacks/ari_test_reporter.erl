%% A vertex passing every message from `in' to `out' and reporting its
%% termination: the arguments are the name to report and the process
%% to report it to. A third argument makes the vertex faulty: `init'
%% fails the initialisation, `terminate' fails the termination once
%% it has been reported.
-module(ari_test_reporter).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [out].

init({Name, Pid}) -> {Name, Pid, none};
init({Name, _Pid, init}) -> error({init_failed, Name});
init({Name, Pid, Fault}) -> {Name, Pid, Fault}.

handle_message(in, Message, Time, State) ->
    {State, [], [{out, Message, Time}]}.

handle_notification(_Time, State) ->
    {State, []}.

terminate({Name, Pid, Fault}) ->
    Pid ! {terminated, Name},
    case Fault of
        terminate -> error({terminate_failed, Name});
        none -> ok
    end.
