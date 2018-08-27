-module(nilva_mnesia).
-include_lib("stdlib/include/qlc.hrl").

-include("nilva_types.hrl").
-export([init/0]).
% For debugging
% -export([create_tables/0, init_tables/0]).
-export([get_current_term/0, increment_current_term/0, set_current_term/1]).
-export([get_voted_for/0, set_voted_for/1]).
-export([get_log_entry/1,
         get_log_entries_starting_from/1,
         del_log_entries_starting_from/1,
         write_entry/1,
         write_entries/1
         ]).
-export([get_last_log_idx_and_term/0]).


-define(PERSISTENT_STATE_KEY, 0).    % Just a key, no practical significance
-define(FIRST_TERM, 0).
-define(FIRST_LOG_IDX, 0).
-define(TXN_OK, {atomic, ok}).     % Transaction ok

% NOTE: Supresses unused record dialyzer warnings that you know are not true
% Not really intended to be an export
-export_type([nilva_state_transition/0,
             nilva_persistent_state/0]).

%% =========================================================================
%% Mnesia Tables
%% =========================================================================

% NOTE: First 2 are required for implementing raft, rest of them make testing and
% implementation easier
%
% NOTE: The structure of records is specific to mnesia. If you decide to use a different
%       storage engine in the future, you would need to make appropriate changes
%       to support the new storage engine's idiosyncrasies.
%
% TODO: This is almost the same record from nilva_types.hrl.
%       Use that instead of declaring it again
-record(nilva_log_entry, {
        % Index is monotonically increasing starting from '0'
        index   :: raft_log_idx(),
        term    :: raft_term(),
        % csn must be unique too. We can think of it as uuid.
        % % Practically, collisions should not be possible
        % csn     :: undefined | csn(),
        %
        % csn is already part of raft_command if it is a client request.
        % Should we store it again to make indexing easier?
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
-opaque nilva_persistent_state() :: #nilva_persistent_state{}.

-record(nilva_state_transition, {
        % fromTerm & toTerm form the composite primary key
        fromTerm    :: raft_term(),
        toTerm      :: raft_term(),
        fromState   :: boot | follower | candidate | leader,
        toState     :: follower | candidate | leader
        }).
-opaque nilva_state_transition() :: #nilva_state_transition{}.

%% =========================================================================
%% Mnesia setup etc.,
%% =========================================================================

-spec init() -> boolean().
% We assume mnesia schema has already been setup either manually or by setup script
% TODO: Automate the schema creation if not present
init() ->
    case create_tables() of
        ok ->
            case init_tables() of
                ok ->
                    true;
                _Error1 ->
                    % ok = lager:error("Mnesia tables not initialized properly: ~n~p",
                    %                  [Error1]),
                    false
            end;
        _Error2 ->
            % ok = lager:error("Mnesia tables not created properly: ~n~p",
            %                  [Error2]),
            false
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
% Raft is also responsible for making sure that there are no holes in
% log indexes sequence
-spec write_entry(log_entry()) -> ok | {error, any()}.
write_entry(#log_entry{term=Term, index=Idx, entry=LE}) ->
    F = fun() ->
            mnesia:write({nilva_log_entry, Idx, Term, LE, undefined})
        end,
    txn_run(F).


-spec write_entries(list(log_entry())) -> ok | {error, any()}.
write_entries(LogEntries) ->
    F = fun() ->
            [mnesia:write({nilva_log_entry, Idx, Term, LE, undefined}) ||
            #log_entry{term=Term, index=Idx, entry=LE} <- LogEntries]
        end,
    txn_run(F).


get_log_entry(Idx) ->
    F = fun() ->
            Xs = mnesia:read(nilva_log_entry, Idx),
            case Xs of
                [] -> mnesia:abort("No such log entry");
                [X] -> X
            end
        end,
    LE = txn_run_and_get_result(F),
    case LE of
        {error, Error} ->
            {error, Error};
        _ ->
            convert_to_log_entry(LE)
    end.


% Inclusive Range
get_log_entries_starting_from(Idx) ->
    Query = fun() ->
                Q =  qlc:q([X ||
                           X <- mnesia:table(nilva_log_entry),
                           Idx =< X#nilva_log_entry.index]),
                qlc:e(Q)
            end,
    LES = txn_run_and_get_result(Query),
    % NOTE: We are storing the log entries in a set
    %       Sorting by Idx is necessary to give the illusion of order
    SortByIdx = fun({nilva_log_entry, Idx1, _, _, _}, {nilva_log_entry, Idx2, _, _, _}) ->
                    Idx1 =< Idx2
                end,
    OrdredLES = lists:sort(SortByIdx, LES),
    lists:map(fun convert_to_log_entry/1, OrdredLES).


del_log_entries_starting_from(Idx) ->
    Query = fun() ->
                Q =  qlc:q([mnesia:delete({nilva_log_entry, X#nilva_log_entry.index }) ||
                           X <- mnesia:table(nilva_log_entry),
                           Idx =< X#nilva_log_entry.index]),
                qlc:e(Q)
            end,
    txn_run(Query).


%% =========================================================================
%% helpers (public)
%% =========================================================================


get_last_log_idx_and_term() ->
    F = fun() ->
            Indices = mnesia:all_keys(nilva_log_entry),
            MaxIdx = lists:max(Indices),
            [X] = mnesia:read(nilva_log_entry, MaxIdx),
            {MaxIdx, X#nilva_log_entry.term}
        end,
    txn_run_and_get_result(F).




%% =========================================================================
%% helpers (private)
%% =========================================================================

-spec create_tables() -> ok | {error, any()}.
create_tables() ->
    % Hmm, it would be nice to have a monad like 'Either' here to handle
    % the `aborted` case
    %
    % NOTE: All the tables will be local to the node. They won't be replicated by Mnesia.
    %       Raft is responsible for replication
    % NOTE: record_info is resolved at compile time, so it cannot be passed arguments
    %       as a function
    % TODO: You can test the tables creation by running `mnesia:table_info(Tbl, attributes)`
    %       and checking that the attributes match what you expected
    Tbls = [{nilva_persistent_state, record_info(fields, nilva_persistent_state)},
            {nilva_log_entry, record_info(fields, nilva_log_entry)},
            {nilva_state_transition, record_info(fields, nilva_state_transition)}
            ],
    Results = lists:map(fun create_table_if_not_exists/1, Tbls),
    case lists:all(fun(X) -> X =:= ok end, Results) of
        true -> ok;
        false ->
            {error, lists:filter(fun(X) -> X =/= ok end, Results)}
    end.


-spec create_table_if_not_exists({atom(), list(atom())}) -> ok | {error, any()}.
create_table_if_not_exists({TblName, Attributes}) ->
    Res = mnesia:create_table(TblName,
                              [{attributes, Attributes},
                              {disc_copies, [node()]}]),
    case Res of
        ?TXN_OK -> ok;
        {aborted, {already_exists, TblName}} -> ok;
        {aborted, Error} -> {error, Error}
    end.


init_tables() ->
    F = fun() ->
            mnesia:write({nilva_persistent_state,
                         ?PERSISTENT_STATE_KEY, ?FIRST_TERM, undefined})
            % mnesia:write({nilva_state_transition, 0, FirstValidTerm, boot, follower})
        end,
    txn_run(F).


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
convert_to_log_entry(#nilva_log_entry{index=Idx, term=Term, cmd=Cmd, res=Res}) ->
    #log_entry{
        term = Term,
        index = Idx,
        status = volatile,
        entry = Cmd,
        response = Res
    }.
