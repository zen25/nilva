-module(nilva_mnesia).
-include_lib("stdlib/include/qlc.hrl").

-include("nilva_types.hrl").
-export([init/0]).
-export([get_current_term/0, increment_current_term/0, set_current_term/1]).

-export_type([nilva_log_entry/0,
             nilva_persistent_state/0,
             nilva_term_lsn_range_idx/0,
             nilva_state_transition/0
             ]).

% Mnesia Tables (first 2 are required for implementing raft, next 2 make testing and
% implementation easier)
%
% NOTE: The structure of records is specific to mnesia. If you decide to use a different
%       storage engine in the future, you would need to make appropriate changes
%       to support the new storage engine's idiosyncrasies.
-record(nilva_log_entry, {
        % Primary key
        lsn     :: non_neg_integer(),
        % term & idx form a composite primary key. We have lsn as a stand-in
        % though to make things easier
        term    :: raft_term(),
        idx     :: raft_log_idx(),
        cmd     :: raft_commands(),
        res     :: rsm_response()
        }).
% TODO: Handle the opaque type errors in dialyzer properly
-opaque nilva_log_entry() :: #nilva_log_entry{}.

-record(nilva_persistent_state, {
        % A peer has only 1 term at any time, so this table has
        % single record at all times
        id              :: 0,
        current_term    :: raft_term(),
        voted_for       :: undefined | raft_peer_id()
        }).
-opaque nilva_persistent_state() :: #nilva_persistent_state{}.

-record(nilva_term_lsn_range_idx, {
        term        :: raft_term(),
        % Number of entries in term == end_lsn - start_lsn + 1
        % end_lsn >= start_lsn
        start_lsn   :: non_neg_integer(),
        end_lsn     :: non_neg_integer()
        }).
-opaque nilva_term_lsn_range_idx() :: #nilva_term_lsn_range_idx{}.

-record(nilva_state_transition, {
        % fromTerm & toTerm form the composite primary key
        fromTerm    :: raft_term(),
        toTerm      :: raft_term(),
        fromState   :: follower | candidate | leader,
        toState     :: follower | candidate | leader
        }).
-opaque nilva_state_transition() :: #nilva_state_transition{}.


init() ->
    create_tables().


create_tables() ->
    mnesia:create_table(nilva_persistent_state,
                        {attributes, record_info(fields, nilva_persistent_state)}),
    mnesia:create_table(nilva_log_entry,
                        {attributes, record_info(fields, nilva_log_entry)}),
    mnesia:create_table(nilva_term_lsn_range_idx,
                        {attributes, record_info(fields, nilva_term_lsn_range_idx)}),
    mnesia:create_table(nilva_state_transition,
                        {attributes, record_info(fields, nilva_state_transition)}).


get_current_term() ->
    mnesia:transaction(fun() ->
        [X] = mnesia:read(nilva_persistent_state, current_term),
        X
    end).

increment_current_term() ->
    mnesia:transaction(fun() ->
        [X] = mnesia:read(nilva_persistent_state, current_term),
        mnesia:write({nilva_persistent_state, current_term, X + 1}),
        [Y] = mnesia:read(nilva_persistent_state, current_term),
        Y
    end).

set_current_term(Term) ->
    mnesia:transaction(fun() ->
        [X] = mnesia:read(nilva_persistent_state, current_term),
        case X < Term of
            true ->
                mnesia:write({nilva_persistent_state, current_term, Term});
            false ->
                mnesia:abort("Current term >= given term to update")
        end
    end).
