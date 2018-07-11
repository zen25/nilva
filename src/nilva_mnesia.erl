-module(nilva_mnesia).
-include_lib("stdlib/include/qlc.hrl").

-include("nilva_types.hrl").
-export([init/0]).
-export([get_current_term/0, increment_current_term/0, set_current_term/1]).
-export([get_voted_for/0, set_voted_for/1]).
-export([lsn_2_term_N_idx/1, term_N_idx_2_lsn/2]).


-define(PERSISTENT_STATE_KEY, 0).    % Just a key, no practical significance
-define(TXN_OK, {atomic, ok}).     % Transaction ok


%% =========================================================================
%% Mnesia Tables
%% =========================================================================

% NOTE: First 2 are required for implementing raft, next 2 make testing and
% implementation easier)
%
% NOTE: The structure of records is specific to mnesia. If you decide to use a different
%       storage engine in the future, you would need to make appropriate changes
%       to support the new storage engine's idiosyncrasies.
% -type log_sequence_number() :: non_negative_integer().
-record(nilva_log_entry, {
        % Primary key
        lsn     :: log_sequence_number(),
        % term & idx form a composite primary key. We have lsn as a stand-in
        % though to make things easier
        term    :: raft_term(),
        idx     :: raft_log_idx(),
        cmd     :: raft_commands(),
        res     :: rsm_response()
        }).
% -type nilva_log_entry() :: #nilva_log_entry{}.

-record(nilva_persistent_state, {
        % A peer has only 1 term at any time, so this table has
        % single record at all times
        id              :: ?PERSISTENT_STATE_KEY,
        current_term    :: raft_term(),
        voted_for       :: undefined | raft_peer_id()
        }).
% -type nilva_persistent_state() :: #nilva_persistent_state{}.

-record(nilva_term_lsn_range_idx, {
        term        :: raft_term(),
        % Number of entries in term == end_lsn - start_lsn + 1
        % end_lsn >= start_lsn
        start_lsn   :: non_neg_integer(),
        end_lsn     :: non_neg_integer()
        }).
% -type nilva_term_lsn_range_idx() :: #nilva_term_lsn_range_idx{}.

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

-spec init() -> no_return().
init() ->
    create_tables().

-spec create_tables() -> no_return().
create_tables() ->
    % Hmm, it would be nice to have a monad like 'Either' here to handle
    % the `aborted` case
    %
    % NOTE: All the tables will be local to the node. They won't be replicated.
    ?TXN_OK = mnesia:create_table(nilva_persistent_state,
            [{attributes, record_info(fields, nilva_persistent_state)},
            {disc_copies, [node()]}]),
    ?TXN_OK = mnesia:create_table(nilva_log_entry,
            [{attributes, record_info(fields, nilva_log_entry)},
            {disc_copies, [node()]}]),
    ?TXN_OK = mnesia:create_table(nilva_term_lsn_range_idx,
            [{attributes, record_info(fields, nilva_term_lsn_range_idx)},
            {ram_copies, [node()]}]),
    ?TXN_OK = mnesia:create_table(nilva_state_transition,
            [{attributes, record_info(fields, nilva_state_transition)},
            {disc_copies, [node()]}]).

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

-spec lsn_2_term_N_idx(log_sequence_number()) -> {raft_term(), raft_log_idx()}
                                               | {error, any()}.
lsn_2_term_N_idx(LSN) ->
    % TODO: Extract this pattern into a higher order function
    F = fun() ->
            Xs = mnesia:read(nilva_log_entry, LSN),
            case Xs of
                [] -> mnesia:abort("No such LSN");
                [{_, _, Term, Idx, _, _}] ->
                    {Term, Idx}
            end
        end,
    txn_run_and_get_result(F).

-spec term_N_idx_2_lsn(raft_term(), raft_log_idx()) -> log_sequence_number()
                                                    | {error, any()}.
term_N_idx_2_lsn(Term, Idx) ->
    F = fun() ->
            Xs = mnesia:read(nilva_term_lsn_range_idx, Term),
            case Xs of
                [] -> mnesia:abort("No log entries for that term");
                [{_, _, S, E}] ->
                    N = E - S + 1,
                    case Idx < N of
                        true -> S + Idx;
                        false -> mnesia:abort("No log entries for that index")
                    end
            end
        end,
    txn_run_and_get_result(F).

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
        {aborted, Error} -> {error, {mnesia_error, Error}}
    end.
