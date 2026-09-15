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
%%% @end
%%%-------------------------------------------------------------------

-module(ari_progress).

-export([
    new/1,
    check_open/3,
    close/3,
    apply/2,
    complete/3
]).

-export_type([
    t/0,
    pointstamp/0,
    delta/0
]).

%% A place of the graph work is outstanding at: a message waiting on
%% an edge or a notification a vertex asked for.
-type pointstamp() :: {ari_summaries:location(), ari_vtime:t()}.

%% What one delivery did to the work outstanding: the pointstamps it
%% took one item of work off, and the pointstamps it put one on. A
%% pointstamp put on is listed once per item.
-type delta() :: {Released :: [pointstamp()], Added :: [pointstamp()]}.

-record(progress, {
    %% How many items of work are outstanding at every pointstamp.
    pending :: #{pointstamp() => pos_integer()},
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
        inputs = #{Input => 0 || Input <- Inputs}
    }.

%%--------------------------------------------------------------------
%% @doc
%% Checks that items of epoch `Epoch' may be pushed on the input
%% `Input'. Fails with `{unknown_input, Input}' if there is no such
%% input and with `{closed, {Input, Epoch}}' if the epoch was closed.
%% @end
%%--------------------------------------------------------------------
-spec check_open(Input :: atom(), Epoch :: non_neg_integer(), t()) -> ok.
check_open(Input, Epoch, #progress{inputs = Inputs}) ->
    case Inputs of
        #{Input := Open} when Epoch < Open -> error({closed, {Input, Epoch}});
        #{Input := _Open} -> ok;
        _ -> error({unknown_input, Input})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Closes the epochs up to `Epoch' of the input `Input': no more items
%% of those epochs are to be pushed, and the times they contribute to
%% may complete. Closing an epoch that is closed already changes
%% nothing.
%%
%% Fails with `{unknown_input, Input}' if there is no such input.
%% @end
%%--------------------------------------------------------------------
-spec close(Input :: atom(), Epoch :: non_neg_integer(), t()) -> t().
close(Input, Epoch, #progress{inputs = Inputs} = Progress) ->
    case Inputs of
        #{Input := Open} -> Progress#progress{inputs = Inputs#{Input := max(Open, Epoch + 1)}};
        _ -> error({unknown_input, Input})
    end.

%%--------------------------------------------------------------------
%% @doc
%% Applies the delta `Delta': the work added is counted first, the
%% work released is taken off afterwards.
%%
%% Fails with `{nothing_outstanding, Pointstamp}' if the delta
%% releases work at a pointstamp with none.
%% @end
%%--------------------------------------------------------------------
-spec apply(delta(), t()) -> t().
apply({Released, Added}, #progress{pending = Pending} = Progress) ->
    Counted = lists:foldl(
        fun(Pointstamp, Acc) -> maps:update_with(Pointstamp, fun(N) -> N + 1 end, 1, Acc) end,
        Pending,
        Added
    ),
    Progress#progress{pending = lists:foldl(fun release/2, Counted, Released)}.

%%--------------------------------------------------------------------
%% @doc
%% Tells whether the time `Time' is complete for the vertex `Vertex':
%% whether nothing outstanding, the notification of the vertex at
%% that very time aside, can result in a message of `Time' or of an
%% earlier time arriving at the vertex, see {@link
%% ari_summaries:reaches/5}. An open input is outstanding at its
%% first open epoch; the later ones reach no further.
%% @end
%%--------------------------------------------------------------------
-spec complete(ari_summaries:t(), {Vertex :: atom(), ari_vtime:t()}, t()) -> boolean().
complete(Summaries, {Vertex, Time}, #progress{pending = Pending, inputs = Inputs}) ->
    Self = {{vertex, Vertex}, Time},
    Outstanding =
        [Pointstamp || Pointstamp := _Count <- Pending, Pointstamp =/= Self] ++
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
%% Takes one item of work off a pointstamp.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec release(pointstamp(), #{pointstamp() => pos_integer()}) -> #{pointstamp() => pos_integer()}.
release(Pointstamp, Pending) ->
    case Pending of
        #{Pointstamp := 1} -> maps:remove(Pointstamp, Pending);
        #{Pointstamp := N} -> Pending#{Pointstamp := N - 1};
        _ -> error({nothing_outstanding, Pointstamp})
    end.
