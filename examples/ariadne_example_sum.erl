%% A vertex summing the items of every completed timestamp.
-module(ariadne_example_sum).

-behaviour(ariadne_vertex).

-export([
    inputs/0,
    outputs/0,
    init/1,
    handle_message/4,
    handle_notification/2,
    terminate/1
]).

inputs() -> [in].

outputs() -> [out].

init(_Args) -> #{}.

handle_message(in, Item, Time, Sums) ->
    Updated = maps:update_with(Time, fun(Sum) -> Sum + Item end, Item, Sums),
    {Updated, [Time], []}.

handle_notification(Time, Sums) ->
    Total = maps:get(Time, Sums),
    {maps:remove(Time, Sums), [{out, Total, Time}]}.

terminate(_Sums) -> ok.
