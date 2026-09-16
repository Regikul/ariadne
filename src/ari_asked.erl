%%%-------------------------------------------------------------------
%%% @doc
%%% The notifications asked for and not delivered yet, kept by the
%%% vertex in the order of their times, each with a value of the
%%% keeper's choosing.
%%%
%%% The point of the order is finding the notifications whose time
%%% is complete without asking about every one: the times of a
%%% vertex are walked from the earliest, and a time found incomplete
%%% blocks the times it precedes -- whatever keeps it from completing
%%% keeps them too -- so those are passed over without asking. For a
%%% vertex outside of every loop the times are totally ordered (see
%%% {@link ari_vtime:outside/1}), and the first incomplete time ends
%%% the walk of the vertex; inside of a loop the walk goes on past
%%% it, since a time iterating the loop the other way may well be
%%% complete. The order of the walk is that of terms, which puts a
%%% time before every time it precedes.
%%%
%%% Whether a time is complete is told by a function given, see
%%% {@link ari_progress:complete/3}.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_asked).

-export([
    new/0,
    find/3,
    add/4,
    remove/3,
    to_list/1,
    first/2,
    due/2
]).

-export_type([
    t/1,
    complete/0
]).

%% The times asked for of every vertex with any, with their values.
-opaque t(Value) :: #{Vertex :: atom() => gb_trees:tree(ari_vtime:t(), Value)}.

%% Tells whether a time is complete for a vertex.
-type complete() :: fun((Vertex :: atom(), ari_vtime:t()) -> boolean()).

%%--------------------------------------------------------------------
%% @doc
%% Nothing asked for.
%% @end
%%--------------------------------------------------------------------
-spec new() -> t(_).
new() ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% The value of the notification of the vertex `Vertex' at the time
%% `Time', if it was asked for.
%% @end
%%--------------------------------------------------------------------
-spec find(Vertex :: atom(), ari_vtime:t(), t(Value)) -> {value, Value} | none.
find(Vertex, Time, Asked) ->
    case Asked of
        #{Vertex := Times} -> gb_trees:lookup(Time, Times);
        _ -> none
    end.

%%--------------------------------------------------------------------
%% @doc
%% Remembers the notification of the vertex `Vertex' at the time
%% `Time' with the value `Value', in place of the value it had if it
%% was asked for already.
%% @end
%%--------------------------------------------------------------------
-spec add(Vertex :: atom(), ari_vtime:t(), Value, t(Value)) -> t(Value).
add(Vertex, Time, Value, Asked) ->
    Times = maps:get(Vertex, Asked, gb_trees:empty()),
    Asked#{Vertex => gb_trees:enter(Time, Value, Times)}.

%%--------------------------------------------------------------------
%% @doc
%% Forgets the notification of the vertex `Vertex' at the time
%% `Time', which is expected to have been asked for; otherwise the
%% call fails.
%% @end
%%--------------------------------------------------------------------
-spec remove(Vertex :: atom(), ari_vtime:t(), t(Value)) -> t(Value).
remove(Vertex, Time, Asked) ->
    Times = gb_trees:delete(Time, maps:get(Vertex, Asked)),
    case gb_trees:is_empty(Times) of
        true -> maps:remove(Vertex, Asked);
        false -> Asked#{Vertex := Times}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Every notification asked for, in no particular order.
%% @end
%%--------------------------------------------------------------------
-spec to_list(t(Value)) -> [{Vertex :: atom(), ari_vtime:t(), Value}].
to_list(Asked) ->
    [{Vertex, Time, Value} || Vertex := Times <- Asked, {Time, Value} <- gb_trees:to_list(Times)].

%%--------------------------------------------------------------------
%% @doc
%% The earliest notification whose time is complete, of the earliest
%% vertex among those of one and the same time, if there is one. It
%% is left where it is.
%% @end
%%--------------------------------------------------------------------
-spec first(complete(), t(Value)) -> {value, {Vertex :: atom(), ari_vtime:t(), Value}} | none.
first(Complete, Asked) ->
    Found = [
        {Time, Vertex, Value}
     || Vertex := Times <- Asked, {Time, Value} <- walk(one, Vertex, Times, Complete)
    ],
    case lists:sort(Found) of
        [] -> none;
        [{Time, Vertex, Value} | _] -> {value, {Vertex, Time, Value}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Every notification whose time is complete, the earliest times
%% first, taken off what is asked for.
%% @end
%%--------------------------------------------------------------------
-spec due(complete(), t(Value)) -> {[{Vertex :: atom(), ari_vtime:t(), Value}], t(Value)}.
due(Complete, Asked) ->
    Found = lists:sort([
        {Time, Vertex, Value}
     || Vertex := Times <- Asked, {Time, Value} <- walk(all, Vertex, Times, Complete)
    ]),
    Due = [{Vertex, Time, Value} || {Time, Vertex, Value} <- Found],
    {Due, lists:foldl(fun({Vertex, Time, _Value}, Acc) -> remove(Vertex, Time, Acc) end, Asked, Due)}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Walks the times asked for the vertex `Vertex' from the earliest
%% and returns those complete, the earliest first: all of them, or
%% the first alone.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec walk(one | all, Vertex :: atom(), gb_trees:tree(ari_vtime:t(), Value), complete()) ->
    [{ari_vtime:t(), Value}].
walk(How, Vertex, Times, Complete) ->
    walk(How, Vertex, gb_trees:iterator(Times), Complete, [], []).

%% `Blocking' holds the times found incomplete so far; `Found' those
%% found complete, the latest first.
-spec walk(
    one | all,
    Vertex :: atom(),
    gb_trees:iter(ari_vtime:t(), Value),
    complete(),
    Blocking :: [ari_vtime:t()],
    Found :: [{ari_vtime:t(), Value}]
) -> [{ari_vtime:t(), Value}].
walk(How, Vertex, Iterator, Complete, Blocking, Found) ->
    case gb_trees:next(Iterator) of
        none ->
            lists:reverse(Found);
        {Time, Value, Iterator2} ->
            case lists:any(fun(B) -> ari_vtime:le(B, Time) end, Blocking) of
                true ->
                    walk(How, Vertex, Iterator2, Complete, Blocking, Found);
                false ->
                    case Complete(Vertex, Time) of
                        true when How =:= one ->
                            [{Time, Value}];
                        true ->
                            walk(all, Vertex, Iterator2, Complete, Blocking, [{Time, Value} | Found]);
                        false ->
                            case ari_vtime:outside(Time) of
                                true ->
                                    lists:reverse(Found);
                                false ->
                                    walk(How, Vertex, Iterator2, Complete, [Time | Blocking], Found)
                            end
                    end
            end
    end.
