%% A vertex breaking a rule of the behaviour, the one chosen by the
%% arguments:
%%   {time, Time}   -- sends every message to `out' at `Time', whatever
%%                     the time of the message;
%%   {slot, Slot}   -- sends every message to `Slot';
%%   {notify, Time} -- asks to be notified at `Time' on every message.
-module(ari_test_rogue).

-behaviour(ariadne_vertex).

-export([inputs/0, outputs/0, init/1, handle_message/4, handle_notification/2, terminate/1]).

inputs() -> [in].

outputs() -> [out].

init(Rule) -> Rule.

handle_message(in, Message, _Time, {time, Time} = Rule) ->
    {Rule, [], [{out, Message, Time}]};
handle_message(in, Message, Time, {slot, Slot} = Rule) ->
    {Rule, [], [{Slot, Message, Time}]};
handle_message(in, _Message, _Time, {notify, Time} = Rule) ->
    {Rule, [Time], []}.

handle_notification(_Time, Rule) ->
    {Rule, []}.

terminate(_State) -> ok.
