%% A minimal vertex used by the README quick start.
-module(ariadne_example_map).

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

init(Fun) when is_function(Fun, 1) -> Fun.

handle_message(in, Item, Time, Fun) ->
    {Fun, [], [{out, Fun(Item), Time}]}.

handle_notification(_Time, Fun) ->
    {Fun, []}.

terminate(_Fun) -> ok.
