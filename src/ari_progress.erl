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
%%% The frontier is built anew when a time leaves it, from the
%%% outstanding times of the location kept in groups by their stack
%%% of loop counters: the times of a group differ in the epoch alone
%%% and are totally ordered, so the earliest of every group is the
%%% only one of it that may be on the frontier, and the cost of
%%% building is that of the number of groups -- the counters the
%%% work is spread over -- not of the number of epochs open.
%%%
%%% @private
%%% @end
%%%-------------------------------------------------------------------

-module(ari_progress).

-export([
    new/1,
    check_open/3,
    close/3,
    sum/2,
    apply/2,
    in_flight/1,
    complete/3
]).

-export_type([
    t/0,
    pointstamp/0,
    delta/0,
    sum/0,
    refusal/0
]).

%% A place of the graph work is outstanding at: a message waiting on
%% an edge or a notification a vertex asked for.
-type pointstamp() :: {ari_summaries:location(), ari_vtime:t()}.

%% What one delivery did to the work outstanding: the pointstamps it
%% took one item of work off, and the pointstamps it put one on. A
%% pointstamp put on is listed once per item.
-type delta() :: {Released :: [pointstamp()], Added :: [pointstamp()]}.

%% The deltas of several deliveries put together: how many items of
%% work every pointstamp gained less how many it lost, the pointstamps
%% that came out even left out. Deltas released work in one and the
%% same round it was added in, so several put together weigh as much
%% as the deliveries they came from, not as the events delivered.
-type sum() :: #{pointstamp() => integer()}.

%% Why a push or a closing was refused: the caller named an input
%% the graph has not, or an epoch closed already. A refusal is the
%% caller's fault and leaves the progress as it was; the counts
%% not adding up (see {@link apply/2}) is not a refusal but a failure.
-type refusal() :: {unknown_input, atom()} | {closed, {atom(), non_neg_integer()}}.

-record(progress, {
    %% How many items of work are outstanding at every pointstamp.
    pending :: #{pointstamp() => pos_integer()},
    %% The times work is outstanding at, of every location with any,
    %% in groups by the stack of loop counters (see {@link
    %% ari_vtime:iterations/1}), every group in the order of the
    %% epochs.
    times :: #{ari_summaries:location() => groups()},
    %% The frontier of every location with work outstanding.
    frontier :: #{ari_summaries:location() => [ari_vtime:t(), ...]},
    %% How many of the items are messages, i.e. outstanding on an edge.
    in_flight :: non_neg_integer(),
    %% The first open epoch of every input.
    inputs :: #{atom() => non_neg_integer()}
}).

-opaque t() :: #progress{}.

-type groups() :: #{[non_neg_integer()] => gb_sets:set(ari_vtime:t())}.

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
        inputs = maps:from_list([{Input, 0} || Input <- Inputs])
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
%% Puts the delta `Delta' together with the sum `Sum'.
%% @end
%%--------------------------------------------------------------------
-spec sum(delta(), sum()) -> sum().
sum({Released, Added}, Sum) ->
    Counted = lists:foldl(fun(Pointstamp, Acc) -> count(Pointstamp, 1, Acc) end, Sum, Added),
    lists:foldl(fun(Pointstamp, Acc) -> count(Pointstamp, -1, Acc) end, Counted, Released).

%%--------------------------------------------------------------------
%% @doc
%% Applies the delta `Delta', or the sum of several: the work added
%% is counted first, the work released is taken off afterwards.
%%
%% Fails with `{unbalanced, Pointstamp}' if the delta releases work
%% at a pointstamp with less: the deltas fed do not add up, and the
%% progress is not to be trusted any more.
%% @end
%%--------------------------------------------------------------------
-spec apply(delta() | sum(), t()) -> t().
apply({Released, Added}, #progress{in_flight = InFlight} = Progress) ->
    Counted = lists:foldl(fun(Pointstamp, Acc) -> add(Pointstamp, 1, Acc) end, Progress, Added),
    Applied = lists:foldl(fun(Pointstamp, Acc) -> release(Pointstamp, 1, Acc) end, Counted, Released),
    Applied#progress{in_flight = InFlight + messages(Added) - messages(Released)};
apply(Sum, #progress{in_flight = InFlight} = Progress) when is_map(Sum) ->
    Counted = maps:fold(
        fun
            (Pointstamp, N, Acc) when N > 0 -> add(Pointstamp, N, Acc);
            (_Pointstamp, _N, Acc) -> Acc
        end,
        Progress,
        Sum
    ),
    Applied = maps:fold(
        fun
            (Pointstamp, N, Acc) when N < 0 -> release(Pointstamp, -N, Acc);
            (_Pointstamp, _N, Acc) -> Acc
        end,
        Counted,
        Sum
    ),
    Applied#progress{
        in_flight = InFlight + lists:sum([N || {{{edge, _}, _}, N} <- maps:to_list(Sum)])
    }.

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
%% whether nothing outstanding can result in a message of `Time' or
%% of an earlier time arriving at the vertex, see {@link
%% ari_summaries:reaches/5}. An open input is outstanding at its
%% first open epoch; the later ones reach no further.
%%
%% The notifications the vertex itself has pending count by the
%% cycles alone, see {@link ari_summaries:returns/4}: a notification
%% sends its messages down the edges leaving the vertex, so an
%% earlier notification of the vertex pending keeps `Time' from
%% completing only if a cycle brings its messages back by `Time'.
%% The order of the notifications of a vertex is kept by whoever
%% delivers them, which takes the earliest complete first; a vertex
%% asks for a notification from a message, at the time of the
%% message or a later one, and no message of a time that is complete
%% is left to be delivered.
%%
%% Only the frontiers are asked: a time a frontier time precedes
%% reaches no further than the frontier time does.
%% @end
%%--------------------------------------------------------------------
-spec complete(ari_summaries:t(), {Vertex :: atom(), ari_vtime:t()}, t()) -> boolean().
complete(Summaries, {Vertex, Time}, #progress{frontier = Frontier, inputs = Inputs}) ->
    Own = {vertex, Vertex},
    Outstanding =
        [
            {Location, Earliest}
         || {Location, Frontline} <- maps:to_list(Frontier), Earliest <- Frontline
        ] ++
        [
            {{edge, Input}, ari_vtime:new(Open)}
         || {Input, Open} <- maps:to_list(Inputs)
        ],
    not lists:any(
        fun
            ({Location, From}) when Location =:= Own ->
                ari_summaries:returns(Summaries, Own, From, Time);
            ({Location, From}) ->
                ari_summaries:reaches(Summaries, Location, From, Own, Time)
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
%% Counts `N' more items of work at a pointstamp in a sum, or `N'
%% fewer if it is negative, leaving out a pointstamp that comes out
%% even.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec count(pointstamp(), integer(), sum()) -> sum().
count(Pointstamp, N, Sum) ->
    case maps:get(Pointstamp, Sum, 0) + N of
        0 -> maps:remove(Pointstamp, Sum);
        Total -> Sum#{Pointstamp => Total}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Puts `N' items of work on a pointstamp. A time new to its location
%% is put on the frontier of the location unless a time there
%% precedes it.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec add(pointstamp(), pos_integer(), t()) -> t().
add({Location, Time} = Pointstamp, N, #progress{pending = Pending} = Progress) ->
    case Pending of
        #{Pointstamp := Count} ->
            Progress#progress{pending = Pending#{Pointstamp := Count + N}};
        _ ->
            #progress{times = Times, frontier = Frontier} = Progress,
            Groups = maps:get(Location, Times, #{}),
            Iterations = ari_vtime:iterations(Time),
            Group = gb_sets:add(Time, maps:get(Iterations, Groups, gb_sets:empty())),
            Progress#progress{
                pending = Pending#{Pointstamp => N},
                times = Times#{Location => Groups#{Iterations => Group}},
                frontier = Frontier#{Location => earliest(Time, maps:get(Location, Frontier, []))}
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% Takes `N' items of work off a pointstamp. A time taken off its
%% location for good leaves the frontier of the location, which is
%% then built anew from the times left, if it was on it.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec release(pointstamp(), pos_integer(), t()) -> t().
release({Location, Time} = Pointstamp, N, #progress{pending = Pending} = Progress) ->
    case Pending of
        #{Pointstamp := N} ->
            #progress{times = Times, frontier = Frontier} = Progress,
            Groups = maps:get(Location, Times),
            Iterations = ari_vtime:iterations(Time),
            Group = gb_sets:delete(Time, maps:get(Iterations, Groups)),
            Left =
                case gb_sets:is_empty(Group) of
                    true -> maps:remove(Iterations, Groups);
                    false -> Groups#{Iterations := Group}
                end,
            case map_size(Left) =:= 0 of
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
        #{Pointstamp := Count} when Count > N ->
            Progress#progress{pending = Pending#{Pointstamp := Count - N}};
        _ ->
            error({unbalanced, Pointstamp})
    end.

%%--------------------------------------------------------------------
%% @doc
%% The frontier of the times of the groups `Groups', which have
%% some: the earliest of every group no earliest of another group
%% precedes.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec earliest_of(groups()) -> [ari_vtime:t(), ...].
earliest_of(Groups) ->
    earliest([gb_sets:smallest(Group) || {_Iterations, Group} <- maps:to_list(Groups)]).

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
