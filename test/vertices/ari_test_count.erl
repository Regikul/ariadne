%% A vertex counting the messages of every time and sending the count
%% to `done' once the time is complete.
-module(ari_test_count).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [done].

init(_Args) -> #{}.

handle_message(in, _Message, Time, Counts) ->
    {maps:update_with(Time, fun(N) -> N + 1 end, 1, Counts), [Time], []}.

handle_notification(Time, Counts) ->
    {maps:remove(Time, Counts), [{done, maps:get(Time, Counts), Time}]}.

terminate(_State) -> ok.
