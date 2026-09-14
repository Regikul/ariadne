%%%-------------------------------------------------------------------
%%% @doc
%%% Summary of a path of a dataflow graph.
%%%
%%% A summary tells what a path does to the timestamp of an item
%%% travelling along it, see {@link ari_vtime}. Every edge of the
%%% path is one of the four steps: a plain edge leaves the timestamp
%%% as it is, an ingress edge pushes a counter, an egress edge drops
%%% one and a feedback edge increments the innermost one. Any chain
%%% of such steps folds into three numbers: how many counters of the
%%% original stack are dropped, how much is added to the counter that
%%% ends up on top of what is left, and which constants are pushed
%%% above it. Increments to a counter the path pushed itself are
%%% folded into the constant; increments to a counter the path drops
%%% afterwards are lost. Two paths of one and the same summary are
%%% thus indistinguishable for every timestamp, and a summary is a
%%% canonical form of a path.
%%%
%%% Summaries are composed with {@link compose/2} and applied to a
%%% timestamp with {@link advance/2}. They are ordered by {@link
%%% le/2}: a summary precedes another one when it never advances a
%%% timestamp further than the other. A cycle produces an endless
%%% series of summaries, each advancing further than the one before,
%%% and {@link minimal/1} is what keeps such a series finite: only
%%% the summaries no other one precedes are worth keeping.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(ari_summary).

-export([
    identity/0,
    ingress/0,
    egress/0,
    feedback/0,
    compose/2,
    advance/2,
    le/2,
    advances/1,
    minimal/1
]).

-export_type([
    t/0
]).

%% A summary: the counters dropped off the original stack, the amount
%% added to the counter left on top of it, and the constants pushed
%% above that, the innermost first.
-opaque t() :: {
    Drop :: non_neg_integer(),
    Incr :: non_neg_integer(),
    Push :: [non_neg_integer()]
}.

%%--------------------------------------------------------------------
%% @doc
%% The summary of an empty path and of a plain edge: the timestamp is
%% left as it is.
%% @end
%%--------------------------------------------------------------------
-spec identity() -> t().
identity() ->
    {0, 0, []}.

%%--------------------------------------------------------------------
%% @doc
%% The summary of an ingress edge, see {@link ari_vtime:ingress/1}.
%% @end
%%--------------------------------------------------------------------
-spec ingress() -> t().
ingress() ->
    {0, 0, [0]}.

%%--------------------------------------------------------------------
%% @doc
%% The summary of an egress edge, see {@link ari_vtime:egress/1}.
%% @end
%%--------------------------------------------------------------------
-spec egress() -> t().
egress() ->
    {1, 0, []}.

%%--------------------------------------------------------------------
%% @doc
%% The summary of a feedback edge, see {@link ari_vtime:feedback/1}.
%% @end
%%--------------------------------------------------------------------
-spec feedback() -> t().
feedback() ->
    {0, 1, []}.

%%--------------------------------------------------------------------
%% @doc
%% The summary of the path made of the path `First' followed by the
%% path `Second'.
%%
%% The second path drops counters off what the first one left: first
%% off the constants the first one pushed, then off the original
%% stack. Depending on how deep it reaches, the increment of the
%% second path lands on a constant of the first one, on the counter
%% the first one incremented, or on a counter below it, in which case
%% the increment of the first path is lost with the counter it was
%% added to.
%% @end
%%--------------------------------------------------------------------
-spec compose(First :: t(), Second :: t()) -> t().
compose({Drop1, Incr1, Push1}, {Drop2, Incr2, Push2}) ->
    case Drop2 - length(Push1) of
        Below when Below < 0 ->
            [Top | Rest] = lists:nthtail(Drop2, Push1),
            {Drop1, Incr1, Push2 ++ [Top + Incr2 | Rest]};
        0 ->
            {Drop1, Incr1 + Incr2, Push2};
        Below ->
            {Drop1 + Below, Incr2, Push2}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Returns the timestamp an item of time `Time' carries at the end of
%% a path of summary `Summary'.
%%
%% Fails with `function_clause' if the timestamp is too shallow for
%% the summary, i.e. if the path leaves more loops than the item is
%% inside of.
%% @end
%%--------------------------------------------------------------------
-spec advance(Summary :: t(), Time :: ari_vtime:t()) -> ari_vtime:t().
advance({Drop, Incr, Push}, Time) ->
    Dropped = times(Drop, fun ari_vtime:egress/1, Time),
    Incremented = times(Incr, fun ari_vtime:feedback/1, Dropped),
    lists:foldr(
        fun(Constant, Acc) ->
            times(Constant, fun ari_vtime:feedback/1, ari_vtime:ingress(Acc))
        end,
        Incremented,
        Push
    ).

%%--------------------------------------------------------------------
%% @doc
%% Tells whether summary `A' precedes summary `B' or is equal to it,
%% i.e. whether `advance(A, T)' precedes `advance(B, T)' for every
%% timestamp `T', see {@link ari_vtime:le/2}.
%%
%% A summary pushing fewer constants than the other never precedes
%% it: where the other has a constant, it has a counter of the
%% original stack, which can be arbitrarily large. A summary pushing
%% more constants precedes the other when its extra constants are not
%% above what the other has at those places -- the increment on the
%% top counter, and zero below it -- and it does not increment the
%% original stack itself.
%%
%% Both summaries are expected to change the depth of the stack by
%% one and the same amount, i.e. to be summaries of paths between
%% one and the same pair of places; otherwise the call fails with
%% `function_clause'.
%% @end
%%--------------------------------------------------------------------
-spec le(A :: t(), B :: t()) -> boolean().
le({DropA, IncrA, PushA}, {DropB, IncrB, PushB})
  when length(PushA) - DropA =:= length(PushB) - DropB ->
    le_pushed(PushA, IncrA, PushB, IncrB).

%%--------------------------------------------------------------------
%% @doc
%% Tells whether a path of summary `Summary' leading back to where it
%% started strictly advances every timestamp, i.e. whether
%% `le(advance(Summary, T), T)' is `false' for every timestamp `T'.
%% This is what a cycle of a graph has to do for times to complete.
%%
%% Whatever constants the path pushes, there are counters at least as
%% large for them to be compared with, so only the increment counts:
%% the path has to increment a counter of the original stack that it
%% does not drop afterwards.
%%
%% The summary is expected to leave the depth of the stack as it is;
%% otherwise the call fails with `function_clause'.
%% @end
%%--------------------------------------------------------------------
-spec advances(Summary :: t()) -> boolean().
advances({Drop, Incr, Push}) when length(Push) =:= Drop ->
    Incr > 0.

%%--------------------------------------------------------------------
%% @doc
%% Keeps the summaries of `Summaries' no other one of them precedes.
%% Of equal summaries a single one is kept.
%% @end
%%--------------------------------------------------------------------
-spec minimal(Summaries :: [t()]) -> [t()].
minimal(Summaries) ->
    Unique = lists:usort(Summaries),
    [S || S <- Unique, not lists:any(fun(Other) -> Other =/= S andalso le(Other, S) end, Unique)].

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Compares two summaries constant by constant, then by what is left
%% once the constants of one of them run out.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec le_pushed(
    [non_neg_integer()], non_neg_integer(), [non_neg_integer()], non_neg_integer()
) -> boolean().
le_pushed([ConstantA | PushA], IncrA, [ConstantB | PushB], IncrB) ->
    ConstantA =< ConstantB andalso le_pushed(PushA, IncrA, PushB, IncrB);
le_pushed([], IncrA, [], IncrB) ->
    IncrA =< IncrB;
le_pushed([ConstantA | PushA], IncrA, [], IncrB) ->
    ConstantA =< IncrB andalso lists:all(fun(C) -> C =:= 0 end, PushA) andalso IncrA =:= 0;
le_pushed([], _IncrA, [_ | _], _IncrB) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% Applies `Fun' to `Acc' `N' times.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec times(N :: non_neg_integer(), Fun :: fun((A) -> A), Acc :: A) -> A.
times(0, _Fun, Acc) ->
    Acc;
times(N, Fun, Acc) ->
    times(N - 1, Fun, Fun(Acc)).
