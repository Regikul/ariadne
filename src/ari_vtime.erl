%%%-------------------------------------------------------------------
%%% @doc
%%% Virtual time of a dataflow graph.
%%%
%%% A timestamp marks the point of the computation a data item belongs
%%% to. It consists of an epoch -- the number of the batch that entered
%%% the graph from the outside world -- and a stack of loop counters,
%%% one per loop scope the item is currently inside of. The innermost
%%% loop is at the head of the stack, the outermost one at its tail;
%%% an item outside of every loop carries an empty stack.
%%%
%%% The stack changes only at the edges of a loop scope: {@link
%%% ingress/1} is applied to an item entering a loop, {@link
%%% feedback/1} to an item travelling along the back edge to the next
%%% iteration, and {@link egress/1} to an item leaving the loop. The
%%% epoch is set once, by {@link new/1}, and is never changed
%%% afterwards.
%%%
%%% Timestamps are ordered by {@link le/2}. The order is partial: an
%%% item of the second epoch does not follow an item of the first
%%% epoch that is still spinning in a loop, because the loop may
%%% produce more items of the first epoch. Comparison is defined for
%%% timestamps of one and the same loop depth, i.e. for items of one
%%% and the same place of the graph.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_vtime).

-export([
    new/1,
    ingress/1,
    egress/1,
    feedback/1,
    le/2,
    outside/1,
    iterations/1
]).

-export_type([
    t/0
]).

%% A timestamp: the epoch of the item and the counters of the loops it
%% is inside of, the innermost loop first.
-opaque t() :: {Epoch :: non_neg_integer(), [non_neg_integer()]}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the timestamp of an item of epoch `Epoch' entering the
%% graph. The item is outside of every loop, so it carries no loop
%% counters.
%% @end
%%--------------------------------------------------------------------
-spec new(Epoch :: non_neg_integer()) -> t().
new(Epoch) ->
    {Epoch, []}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the timestamp of an item entering a loop scope. The item
%% starts at iteration 0 of that loop, which becomes the innermost one
%% for it.
%%
%% @see egress/1
%% @end
%%--------------------------------------------------------------------
-spec ingress(t()) -> t().
ingress({Epoch, Iterations}) ->
    {Epoch, [0 | Iterations]}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the timestamp of an item leaving a loop scope. The counter
%% of the innermost loop is dropped: outside of the loop it is no
%% longer possible to tell on which iteration the item was produced.
%%
%% Fails with `function_clause' if the item is not inside of a loop.
%%
%% @see ingress/1
%% @end
%%--------------------------------------------------------------------
-spec egress(t()) -> t().
egress({Epoch, [_ | Iterations]}) ->
    {Epoch, Iterations}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the timestamp of an item passed along the back edge of the
%% innermost loop. Its counter is incremented, the counters of the
%% enclosing loops are kept as they are.
%%
%% Fails with `function_clause' if the item is not inside of a loop.
%% @end
%%--------------------------------------------------------------------
-spec feedback(t()) -> t().
feedback({Epoch, [Outer | Iterations]}) ->
    {Epoch, [Outer + 1 | Iterations]}.

%%--------------------------------------------------------------------
%% @doc
%% Tells whether timestamp `A' precedes timestamp `B' or is equal to
%% it, i.e. whether an item of time `A' may still influence an item of
%% time `B'. This holds when the epoch of `A' does not follow the
%% epoch of `B' and none of the loop counters of `A' follows the
%% respective counter of `B'.
%%
%% The order is partial: of two timestamps that iterate loops in
%% opposite directions, neither precedes the other, and `le(A, B)' and
%% `le(B, A)' are both `false'.
%%
%% Both timestamps are expected to be of one and the same loop depth,
%% i.e. of one and the same place of the graph; otherwise the call
%% fails with `function_clause'.
%% @end
%%--------------------------------------------------------------------
-spec le(A :: t(), B :: t()) -> boolean().
le({EpochA, IterationsA}, {EpochB, IterationsB}) ->
    le_iterations(IterationsA, IterationsB) andalso EpochA =< EpochB.

%%--------------------------------------------------------------------
%% @doc
%% Tells whether the timestamp is of an item outside of every loop.
%% There the order of the timestamps is total: of any two, one
%% precedes the other.
%% @end
%%--------------------------------------------------------------------
-spec outside(t()) -> boolean().
outside({_Epoch, Iterations}) ->
    Iterations =:= [].

%%--------------------------------------------------------------------
%% @doc
%% The stack of loop counters of the timestamp, the innermost loop
%% at the head. Timestamps of one and the same stack differ in the
%% epoch alone, and of any two, one precedes the other.
%% @end
%%--------------------------------------------------------------------
-spec iterations(t()) -> [non_neg_integer()].
iterations({_Epoch, Iterations}) ->
    Iterations.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Tells whether every loop counter of the first stack precedes the
%% respective counter of the second one or is equal to it.
%%
%% The recursive call comes before the comparison, so both stacks are
%% walked to the end even when an outer loop already breaks the order,
%% and stacks of different depth fail with `function_clause' whatever
%% the counters are.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec le_iterations([non_neg_integer()], [non_neg_integer()]) -> boolean().
le_iterations([], []) ->
    true;
le_iterations([IterationA | IterationsA], [IterationB | IterationsB]) ->
    le_iterations(IterationsA, IterationsB) andalso IterationA =< IterationB.
