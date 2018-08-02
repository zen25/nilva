-module(nilva_mnesia).
-include_lib("stdlib/include/qlc.hrl").

-include("nilva_types.hrl").
-export([init/0]).
-export([get_current_term/0, increment_current_term/0, set_current_term/1]).
-export([get_voted_for/0, set_voted_for/1]).
-export([get_log_entry/2,
         get_log_entries_starting_from/2,
         del_log_entries_starting_from/2,
         write_entry/1,
         write_entries/1
         ]).


-define(PERSISTENT_STATE_KEY, 0).    % Just a key, no practical significance
-define(TXN_OK, {atomic, ok}).     % Transaction ok


%% =========================================================================
%% Mnesia Tables
%% =========================================================================

% NOTE: First 2 are required for implementing raft, next 2 make testing and
% implementation easier
%
% NOTE: The structure of records is specific to mnesia. If you decide to use a different
%       storage engine in the future, you would need to make appropriate changes
%       to support the new storage engine's idiosyncrasies.
-record(nilva_log_entry, {
        % Primary key
        pk      :: {raft_term(), raft_log_idx()},
        cmd     :: raft_commands(),
        res     :: rsm_response()
        }).
-type nilva_log_entry() :: #nilva_log_entry{}.

-record(nilva_persistent_state, {
        % A peer has only 1 term at any time, so this table has
        % single record at all times
        id              :: ?PERSISTENT_STATE_KEY,
        current_term    :: raft_term(),
        voted_for       :: undefined | raft_peer_id()
        }).
% -type nilva_persistent_state() :: #nilva_persistent_state{}.

-record(nilva_state_transition, {
        % fromTerm & toTerm form the composite primary key
        fromTerm    :: raft_term(),
        toTerm      :: raft_term(),
        fromState   :: follower | candidate | leader,
        toState     :: follower | candidate | leader
        }).
% -type nilva_state_transition() :: #nilva_state_transition{}.

%% =========================================================================
%% Mnesia setup etc.,
%% =========================================================================

-spec init() -> boolean().
% We assume mnesia schema has already been setup either manually or by setup script
% TODO: Automate the schema creation if not present
init() ->
    create_tables().

-spec create_tables() -> boolean().
%% Private
create_tables() ->
    % Hmm, it would be nice to have a monad like 'Either' here to handle
    % the `aborted` case
    %
    % NOTE: All the tables will be local to the node. They won't be replicated by Mnesia.
    %       Raft is responsible for replication
    Tbls = [nilva_persistent_state, nilva_log_entry, nilva_state_transition],
    erlang:display(Tbls),
    Results = lists:map(fun create_table_if_not_exists/1, Tbls),
    erlang:display(Results),
    lists:all(fun(X) -> X == ok end, Results).


-spec create_table_if_not_exists(atom()) -> ok | {error, any()}.
create_table_if_not_exists(TblName) ->
    Res = mnesia:create_table(TblName,
                              [{attributes, record_info(fields, nilva_log_entry)},
                              {disc_copies, [node()]}]),
    erlang:display(Res),
    case Res of
        ?TXN_OK -> ok;
        {aborted, {already_exists, TblName}} -> ok;
        {aborted, Error} -> {error, Error}
    end.


%% =========================================================================
%% Persistent Raft Peer State
%% =========================================================================
-spec get_current_term() -> raft_term() | {error, any()}.
get_current_term() ->
    F = fun() ->
            [X] = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            {_, _, CT, _} = X,
            CT
        end,
    txn_run_and_get_result(F).


-spec increment_current_term() -> ok | {error, any()}.
increment_current_term() ->
    F = fun() ->
            [{_, CT, _}] = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            % Reset voted_for when incrementing term
            mnesia:write({nilva_persistent_state, ?PERSISTENT_STATE_KEY, CT + 1, undefined})
        end,
   txn_run(F).


-spec set_current_term(raft_term()) -> ok | {error, any()}.
set_current_term(Term) ->
    F = fun() ->
            Xs = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            case Xs of
                % Reset voted_for when term changes
                [] -> mnesia:write({nilva_persistent_state, ?PERSISTENT_STATE_KEY,
                                 Term, undefined});
                [{_, _, CT, _}] ->
                    case CT < Term of
                        true ->
                            % Reset voted_for when term changes
                            mnesia:write({nilva_persistent_state, ?PERSISTENT_STATE_KEY,
                                         Term, undefined});
                        false ->
                            mnesia:abort("Current term >= given term to update")
                    end
            end
        end,
    txn_run(F).


-spec get_voted_for() -> undefined | raft_peer_id() | {error, any()}.
get_voted_for() ->
    F = fun() ->
            Xs = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            case Xs of
                [] -> undefined;
                [{_, _, _, Peer}] -> Peer
            end
        end,
    txn_run_and_get_result(F).


-spec set_voted_for(raft_peer_id()) -> ok | already_voted | {error, any()}.
set_voted_for(Peer) ->
    F = fun() ->
            Xs = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            case Xs of
                [] -> mnesia:abort("No peristent raft state");
                [{_, _, CT, undefined}] ->
                    mnesia:write({nilva_persistent_state, ?PERSISTENT_STATE_KEY,
                                 CT, Peer}),
                    ok;
                % Idempotent vote
                [{_, _, _, Peer}] -> ok;
                [{_, _, _, _}] -> already_voted
            end
        end,
    txn_run_and_get_result(F).

%% =========================================================================
%% Raft Replication Log
%% =========================================================================

% Assumes that log is up to date
% Storage layer is dumb, it does not know about Raft's log requirements
%
% Overwrites the entry if it already exists.
% Raft has the mechanism to handle this case
-spec write_entry(log_entry()) -> ok | {error, any()}.
write_entry(#log_entry{term=Term, index=Idx, entry=LE}) ->
    F = fun() ->
            mnesia:write({nilva_log_entry, {Term, Idx}, LE, undefined})
        end,
    txn_run(F).


-spec write_entries(list(log_entry())) -> ok | {error, any()}.
write_entries(LogEntries) ->
    F = fun() ->
            [mnesia:write({nilva_log_entry, {Term, Idx}, LE, undefined}) ||
            #log_entry{term=Term, index=Idx, entry=LE} <- LogEntries]
        end,
    txn_run(F).


get_log_entry(Term, Idx) ->
    F = fun() ->
            Xs = mnesia:read(nilva_log_entry, {Term, Idx}),
            case Xs of
                [] -> mnesia:abort("No such log entry");
                [X] -> X
            end
        end,
    LE = txn_run_and_get_result(F),
    convert_to_log_entry(LE).


% Inclusive Range
get_log_entries_starting_from(Term, Idx) ->
    Query = fun() ->
                Q =  qlc:q([X ||
                           X <- mnesia:table(nilva_log_entry),
                           is_log_entry_after_given_entry(X, Term, Idx)]),
                qlc:e(Q)
            end,
    LES = txn_run_and_get_result(Query),
    lists:map(fun convert_to_log_entry/1, LES).


del_log_entries_starting_from(Term, Idx) ->
    Query = fun() ->
                Q =  qlc:q([mnesia:delete({nilva_log_entry, X#nilva_log_entry.pk }) ||
                           X <- mnesia:table(nilva_log_entry),
                           is_log_entry_after_given_entry(X, Term, Idx)]),
                qlc:e(Q)
            end,
    txn_run(Query).


%Private
-spec is_log_entry_after_given_entry(nilva_log_entry(), raft_term(), raft_log_idx()) ->
    boolean().
is_log_entry_after_given_entry(#nilva_log_entry{pk={T, I}}, Term, Idx) ->
    (Term =< T) and (Idx =< I).


%% =========================================================================
%% helpers (private)
%% =========================================================================

txn_run_and_get_result(F) ->
    Res = mnesia:transaction(F),
    case Res of
        {atomic, Result} -> Result;
        {aborted, Error} -> {error, {mnesia_error, Error}}
    end.


txn_run(F) ->
    Res = mnesia:transaction(F),
    case Res of
        ?TXN_OK -> ok;
        {atomic, Results} ->
            lists:all(fun(X) -> X == ok end, Results);
        {aborted, Error} -> {error, {mnesia_error, Error}}
    end.


-spec convert_to_log_entry(nilva_log_entry()) -> log_entry().
convert_to_log_entry(#nilva_log_entry{pk=Pk, cmd=Cmd, res=Res}) ->
    {Term, Idx} = Pk,
    #log_entry{
        term = Term,
        index = Idx,
        status = volatile,
        entry = Cmd,
        response = Res
    }.
