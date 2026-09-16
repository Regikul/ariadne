%%%-------------------------------------------------------------------
%%% @doc
%%% Progress of a dataflow graph: the work outstanding at every
%%% pointstamp and the epochs of the inputs still open.
%%%
%%% Progress is a value. It is fed with deltas -- the work released
%%% and the work created by the delivery of an event, as pointstamps
%%% -- and with the closing of the epochs of the inputs, and it is
%%% asked whether a time is complete for a vertex, see {@link
%%% complete/3}. It knows nothing of the vertices and the messages
%%% themselves: several engines running copies of one graph (see
%%% {@link ari_engine}) can feed one and the same progress.
%%%
%%% Along with the counts, the progress keeps the frontier of every
%%% location: the outstanding times of the location no other
%%% outstanding time of it precedes. Whether a time is complete is
%%% told by the frontier alone, since a later time at a location
%%% reaches no further than an earlier one does, so the cost of the
%%% question is that of the graph, not of the work outstanding.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_progress).

-export([
    new/1,
    check_open/3,
    close/3,
    apply/2,
    in_flight/1,
    complete/3
]).

-export_type([
    t/0,
    pointstamp/0,
    delta/0,
    refusal/0
]).

%% A place of the graph work is outstanding at: a message waiting on
%% an edge or a notification a vertex asked for.
-type pointstamp() :: {ari_summaries:location(), ari_vtime:t()}.

%% What one delivery did to the work outstanding: the pointstamps it
%% took one item of work off, and the pointstamps it put one on. A
%% pointstamp put on is listed once per item.
-type delta() :: {Released :: [pointstamp()], Added :: [pointstamp()]}.

%% Why a push or a closing was refused: the caller named an input
%% the graph has not, or an epoch closed already. A refusal is the
%% caller's fault and leaves the progress as it was; the counts
%% not adding up (see {@link apply/2}) is not a refusal but a failure.
-type refusal() :: {unknown_input, atom()} | {closed, {atom(), non_neg_integer()}}.

-record(progress, {
    %% How many items of work are outstanding at every pointstamp.
    pending :: #{pointstamp() => pos_integer()},
    %% The times work is outstanding at, of every location with any,
    %% in the order of terms, which puts a time before every time it
    %% precedes.
    times :: #{ari_summaries:location() => gb_sets:set(ari_vtime:t())},
    %% The frontier of every location with work outstanding.
    frontier :: #{ari_summaries:location() => [ari_vtime:t(), ...]},
    %% How many of the items are messages, i.e. outstanding on an edge.
    in_flight :: non_neg_integer(),
    %% The first open epoch of every input.
    inputs :: #{atom() => non_neg_integer()}
}).

-opaque t() :: #progress{}.

%%--------------------------------------------------------------------
%% @doc
%% Creates the progress of a graph of inputs `Inputs' (see {@link
%% ari_plan:inputs/1}) with nothing outstanding and every input open
%% at epoch 0.
%% @end
%%--------------------------------------------------------------------
-spec new(Inputs :: [atom()]) -> t().
new(Inputs) ->
    #progress{
        pending = #{},
        times = #{},
        frontier = #{},
        in_flight = 0,
        inputs = #{Input => 0 || Input <- Inputs}
    }.

%%--------------------------------------------------------------------
%% @doc
%% Checks that items of epoch `Epoch' may be pushed on the input
%% `Input'. Refuses with `{unknown_input, Input}' if there is no such
%% input and with `{closed, {Input, Epoch}}' if the epoch was closed.
%% @end
%%--------------------------------------------------------------------
-spec check_open(Input :: atom(), Epoch :: non_neg_integer(), t()) -> ok | {error, refusal()}.
check_open(Input, Epoch, #progress{inputs = Inputs}) ->
    case Inputs of
        #{Input := Open} when Epoch < Open -> {error, {closed, {Input, Epoch}}};
        #{Input := _Open} -> ok;
        _ -> {error, {unknown_input, Input}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input': no more items
%% of those epochs are to be pushed, and the times they contribute to
%% may complete. Closing an epoch that is closed already changes
%% nothing.
%%
%% Refuses with `{unknown_input, Input}' if there is no such input.
%% @end
%%--------------------------------------------------------------------
-spec close(Input :: atom(), Epoch :: non_neg_integer(), t()) -> {ok, t()} | {error, refusal()}.
close(Input, Epoch, #progress{inputs = Inputs} = Progress) ->
    case Inputs of
        #{Input := Open} -> {ok, Progress#progress{inputs = Inputs#{Input := max(Open, Epoch + 1)}}};
        _ -> {error, {unknown_input, Input}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Applies the delta `Delta': the work added is counted first, the
%% work released is taken off afterwards.
%%
%% Fails with `{unbalanced, Pointstamp}' if the delta releases work
%% at a pointstamp with none: the deltas fed do not add up, and the
%% progress is not to be trusted any more.
%% @end
%%--------------------------------------------------------------------
-spec apply(delta(), t()) -> t().
apply({Released, Added}, #progress{in_flight = InFlight} = Progress) ->
    Counted = lists:foldl(fun add/2, Progress, Added),
    Applied = lists:foldl(fun release/2, Counted, Released),
    Applied#progress{in_flight = InFlight + messages(Added) - messages(Released)}.

%%--------------------------------------------------------------------
%% @doc
%% The number of messages on their way: the items of work
%% outstanding on the edges, the notifications left aside.
%% @end
%%--------------------------------------------------------------------
-spec in_flight(t()) -> non_neg_integer().
in_flight(#progress{in_flight = InFlight}) ->
    InFlight.

%%--------------------------------------------------------------------
%% @doc
%% Tells whether the time `Time' is complete for the vertex `Vertex':
%% whether nothing outstanding, the notification of the vertex at
%% that very time aside, can result in a message of `Time' or of an
%% earlier time arriving at the vertex, see {@link
%% ari_summaries:reaches/5}. An open input is outstanding at its
%% first open epoch; the later ones reach no further.
%%
%% Only the frontiers are asked. A time a frontier time precedes
%% reaches no further than the frontier time does. The notification
%% left aside is either on the frontier of the vertex, and then no
%% other outstanding time of the vertex precedes `Time', and none
%% that follows it or is incomparable with it comes back at `Time'
%% or earlier, since no path leads to an earlier time; or it is not,
%% and then a frontier time of the vertex precedes `Time' and keeps
%% it from completing.
%% @end
%%--------------------------------------------------------------------
-spec complete(ari_summaries:t(), {Vertex :: atom(), ari_vtime:t()}, t()) -> boolean().
complete(Summaries, {Vertex, Time}, #progress{frontier = Frontier, inputs = Inputs}) ->
    Self = {{vertex, Vertex}, Time},
    Outstanding =
        [{Location, Earliest} ||
            Location := Frontline <- Frontier, Earliest <- Frontline, {Location, Earliest} =/= Self] ++
        [{{edge, Input}, ari_vtime:new(Open)} || Input := Open <- Inputs],
    not lists:any(
        fun({Location, From}) ->
            ari_summaries:reaches(Summaries, Location, From, {vertex, Vertex}, Time)
        end,
        Outstanding
    ).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% How many of the pointstamps `Pointstamps' are on edges.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec messages([pointstamp()]) -> non_neg_integer().
messages(Pointstamps) ->
    length([Edge || {{edge, Edge}, _Time} <- Pointstamps]).

%%--------------------------------------------------------------------
%% @doc
%% Puts one item of work on a pointstamp. A time new to its location
%% is put on the frontier of the location unless a time there
%% precedes it.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec add(pointstamp(), t()) -> t().
add({Location, Time} = Pointstamp, #progress{pending = Pending} = Progress) ->
    case Pending of
        #{Pointstamp := N} ->
            Progress#progress{pending = Pending#{Pointstamp := N + 1}};
        _ ->
            #progress{times = Times, frontier = Frontier} = Progress,
            Progress#progress{
                pending = Pending#{Pointstamp => 1},
                times = Times#{Location => gb_sets:add(Time, maps:get(Location, Times, gb_sets:empty()))},
                frontier = Frontier#{Location => earliest(Time, maps:get(Location, Frontier, []))}
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% Takes one item of work off a pointstamp. A time taken off its
%% location for good leaves the frontier of the location, which is
%% then built anew from the times left, if it was on it: outside of
%% every loop the times are totally ordered and the frontier is the
%% earliest time left; inside, the times left are gone over.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec release(pointstamp(), t()) -> t().
release({Location, Time} = Pointstamp, #progress{pending = Pending} = Progress) ->
    case Pending of
        #{Pointstamp := 1} ->
            #progress{times = Times, frontier = Frontier} = Progress,
            Left = gb_sets:delete(Time, maps:get(Location, Times)),
            case gb_sets:is_empty(Left) of
                true ->
                    Progress#progress{
                        pending = maps:remove(Pointstamp, Pending),
                        times = maps:remove(Location, Times),
                        frontier = maps:remove(Location, Frontier)
                    };
                false ->
                    Frontline = maps:get(Location, Frontier),
                    Progress#progress{
                        pending = maps:remove(Pointstamp, Pending),
                        times = Times#{Location := Left},
                        frontier =
                            case lists:member(Time, Frontline) of
                                true -> Frontier#{Location := earliest_of(Left)};
                                false -> Frontier
                            end
                    }
            end;
        #{Pointstamp := N} ->
            Progress#progress{pending = Pending#{Pointstamp := N - 1}};
        _ ->
            error({unbalanced, Pointstamp})
    end.

%%--------------------------------------------------------------------
%% @doc
%% The frontier of the times of `Times', which has some.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec earliest_of(gb_sets:set(ari_vtime:t())) -> [ari_vtime:t(), ...].
earliest_of(Times) ->
    Smallest = gb_sets:smallest(Times),
    case ari_vtime:outside(Smallest) of
        true -> [Smallest];
        false -> earliest(gb_sets:to_list(Times))
    end.

%%--------------------------------------------------------------------
%% @doc
%% The frontier of the times `Times': those no other one of them
%% precedes.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec earliest([ari_vtime:t(), ...]) -> [ari_vtime:t(), ...].
earliest(Times) ->
    lists:foldl(fun earliest/2, [], Times).

%%--------------------------------------------------------------------
%% @doc
%% Puts the time `Time' on the frontier `Frontline': the frontier is
%% left as it is if a time on it precedes `Time'; otherwise `Time'
%% goes on it and the times it precedes go off.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec earliest(ari_vtime:t(), [ari_vtime:t()]) -> [ari_vtime:t(), ...].
earliest(Time, Frontline) ->
    case lists:any(fun(Earliest) -> ari_vtime:le(Earliest, Time) end, Frontline) of
        true -> Frontline;
        false -> [Time | [Earliest || Earliest <- Frontline, not ari_vtime:le(Time, Earliest)]]
    end.
