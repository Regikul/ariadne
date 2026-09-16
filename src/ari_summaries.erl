%%%-------------------------------------------------------------------
%%% @doc
%%% Path summaries of a dataflow graph.
%%%
%%% The runtime keeps track of the work outstanding in the graph as a
%%% set of pointstamps: a place of the graph together with a
%%% timestamp. A message waiting on an edge is a pointstamp of that
%%% edge, a notification a vertex asked for is a pointstamp of that
%%% vertex. A time is complete for a vertex once no outstanding
%%% pointstamp can result in a message of that time or of an earlier
%%% one arriving at the vertex. Whether a pointstamp can do so is
%%% told by the summaries (see {@link ari_summary}) of the paths from
%%% its place to the vertex: the pointstamp can result in a time `T'
%%% at the vertex when some path advances its timestamp to `T' or to
%%% a time preceding `T'.
%%%
%%% {@link build/1} computes the summaries of the paths between every
%%% two places of a graph once, as the closure of the steps of the
%%% graph: an edge leads to the vertex at its end with the summary of
%%% its kind, a vertex leads to every edge leaving it with the
%%% identity. A cycle gives an endless series of paths, and only the
%%% minimal summaries are kept, see {@link ari_summary:minimal/1}.
%%% Building also checks that every cycle of the graph strictly
%%% advances the timestamp, see {@link ari_summary:advances/1}: a
%%% cycle that does not -- one without a feedback edge, or one that
%%% leaves a loop to enter it again from the start -- could carry an
%%% item back to a time that was complete, and no time would ever be
%%% complete for the places on it.
%%%
%%% {@link reaches/5} answers the question of the runtime; {@link
%%% returns/4} answers it for the notifications a vertex itself has
%%% pending, which reach its later times around a cycle alone.
%%%
%%% @private
%%% @end
%%%-------------------------------------------------------------------

-module(ari_summaries).

-include("ari_graph.hrl").

-export([
    build/1,
    reaches/5,
    returns/4
]).

-export_type([
    t/0,
    location/0
]).

%% A place of the graph a pointstamp belongs to.
-type location() :: {vertex, atom()} | {edge, atom()}.

%% One edge of the graph as a step of a path.
-type step() :: {From :: location(), To :: location(), ari_summary:t()}.

%% The minimal summaries of the paths of positive length between every
%% two places of the graph. A pair no path leads between is absent.
-opaque t() :: #{{From :: location(), To :: location()} => [ari_summary:t(), ...]}.

%%--------------------------------------------------------------------
%% @doc
%% Computes the summaries of the paths of the graph `Graph'.
%%
%% Fails with `{non_advancing_cycle, Location}' if the graph has a
%% cycle through `Location' that does not strictly advance the
%% timestamp.
%% @end
%%--------------------------------------------------------------------
-spec build(Graph :: #graph{}) -> t().
build(#graph{edges = Edges}) ->
    Steps = lists:flatmap(fun steps/1, Edges),
    Direct = lists:foldl(
        fun({From, To, Summary}, Table) ->
            add(Table, From, To, [Summary])
        end,
        #{},
        Steps
    ),
    Table = closure(Direct, Steps),
    check(Table).

%%--------------------------------------------------------------------
%% @doc
%% Tells whether an item of time `Time' at the place `From' can
%% result in an item arriving at the vertex `To' at time `Time2' or
%% at a time preceding it.
%%
%% A place reaches itself by the empty path: an item at `To' of a
%% time that precedes or equals `Time2' reaches `Time2'. For the
%% pointstamps of `To' itself the runtime asks {@link returns/4}
%% instead.
%% @end
%%--------------------------------------------------------------------
-spec reaches(
    Table :: t(), From :: location(), Time :: ari_vtime:t(), To :: location(), Time2 :: ari_vtime:t()
) -> boolean().
reaches(Table, From, Time, To, Time2) ->
    Summaries = maps:get({From, To}, Table, []),
    Paths = case From of
        To -> [ari_summary:identity() | Summaries];
        _ -> Summaries
    end,
    lists:any(
        fun(Summary) ->
            ari_vtime:le(ari_summary:advance(Summary, Time), Time2)
        end,
        Paths
    ).

%%--------------------------------------------------------------------
%% @doc
%% Tells whether an item of time `Time' at the vertex `Vertex' can
%% result in an item arriving back at the vertex at time `Time2' or
%% at a time preceding it: by a cycle, the empty path left out. The
%% notifications a vertex has pending are asked about this way,
%% since a notification sends its messages down the edges leaving
%% the vertex, and a later notification of the vertex is delivered
%% after it whatever the answer.
%% @end
%%--------------------------------------------------------------------
-spec returns(Table :: t(), Vertex :: location(), Time :: ari_vtime:t(), Time2 :: ari_vtime:t()) ->
    boolean().
returns(Table, Vertex, Time, Time2) ->
    lists:any(
        fun(Summary) ->
            ari_vtime:le(ari_summary:advance(Summary, Time), Time2)
        end,
        maps:get({Vertex, Vertex}, Table, [])
    ).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% The steps an edge contributes: from the vertex at its start to the
%% edge itself with the identity, and from the edge to the vertex at
%% its end with the summary of its kind. An end left `undefined' is
%% the outside world, which no path comes from or leads to.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec steps(Edge :: #edge{} | #ingress{} | #egress{} | #feedback{}) -> [step()].
steps(#edge{name = Name, from = From, to = To}) ->
    steps(Name, From, To, ari_summary:identity());
steps(#ingress{name = Name, from = From, to = To}) ->
    steps(Name, From, To, ari_summary:ingress());
steps(#egress{name = Name, from = From, to = To}) ->
    steps(Name, From, To, ari_summary:egress());
steps(#feedback{name = Name, from = From, to = To}) ->
    steps(Name, From, To, ari_summary:feedback()).

-spec steps(
    Name :: atom(),
    From :: endpoint() | undefined,
    To :: endpoint() | undefined,
    Summary :: ari_summary:t()
) -> [step()].
steps(Name, From, To, Summary) ->
    Into = case From of
        {Vertex, _Slot} -> [{{vertex, Vertex}, {edge, Name}, ari_summary:identity()}];
        undefined -> []
    end,
    OutOf = case To of
        {Vertex2, _Slot2} -> [{{edge, Name}, {vertex, Vertex2}, Summary}];
        undefined -> []
    end,
    Into ++ OutOf.

%%--------------------------------------------------------------------
%% @doc
%% Extends the paths of `Table' by the steps of `Steps' until no new
%% summary appears: every path from `A' to `B' followed by a step
%% from `B' to `C' is a path from `A' to `C'.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec closure(Table :: t(), Steps :: [step()]) -> t().
closure(Table, Steps) ->
    Next = maps:fold(
        fun({A, B}, Summaries, Acc) ->
            lists:foldl(
                fun({From, C, Step}, Acc2) when From =:= B ->
                        add(Acc2, A, C, [ari_summary:compose(S, Step) || S <- Summaries]);
                   (_Step, Acc2) ->
                        Acc2
                end,
                Acc,
                Steps
            )
        end,
        Table,
        Table
    ),
    case Next of
        Table -> Table;
        _ -> closure(Next, Steps)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Adds the summaries of paths from `From' to `To' to `Table',
%% keeping only the minimal ones.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec add(Table :: t(), From :: location(), To :: location(), [ari_summary:t()]) -> t().
add(Table, From, To, Summaries) ->
    Known = maps:get({From, To}, Table, []),
    Table#{{From, To} => ari_summary:minimal(Known ++ Summaries)}.

%%--------------------------------------------------------------------
%% @doc
%% Checks that every cycle of the graph strictly advances the
%% timestamp, i.e. that every summary of a path from a place back to
%% itself advances. Returns `Table' as it is.
%%
%% @private
%% @end
%%--------------------------------------------------------------------
-spec check(Table :: t()) -> t().
check(Table) ->
    maps:foreach(
        fun
            ({Location, Location}, Summaries) ->
                case lists:all(fun ari_summary:advances/1, Summaries) of
                    true -> ok;
                    false -> error({non_advancing_cycle, Location})
                end;
            (_Pair, _Summaries) ->
                ok
        end,
        Table
    ),
    Table.
