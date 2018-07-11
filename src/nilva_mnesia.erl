-module(nilva_mnesia).
-include_lib("stdlib/include/qlc.hrl").

-include("nilva_types.hrl").
-export([init/0]).
-export([get_current_term/0, increment_current_term/0, set_current_term/1]).
-export([get_voted_for/0, set_voted_for/1]).

-export_type([nilva_log_entry/0,
             nilva_persistent_state/0,
             nilva_term_lsn_range_idx/0,
             nilva_state_transition/0
             ]).

-define(PERSISTENT_STATE_KEY, 0).    % Just a key, no practical significance
-define(TOK, {atomic, ok}).     % Transaction ok

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
        id              :: ?PERSISTENT_STATE_KEY,
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


-spec init() -> no_return().
init() ->
    create_tables().

-spec create_tables() -> no_return().
create_tables() ->
    % Hmm, it would be nice to have a monad like 'Either' here to handle
    % the `aborted` case
    %
    % NOTE: All the tables will be local to the node. They won't be replicated.
    ?TOK = mnesia:create_table(nilva_persistent_state,
            [{attributes, record_info(fields, nilva_persistent_state)},
            {disc_copies, [node()]}]),
    ?TOK = mnesia:create_table(nilva_log_entry,
            [{attributes, record_info(fields, nilva_log_entry)},
            {disc_copies, [node()]}]),
    ?TOK = mnesia:create_table(nilva_term_lsn_range_idx,
            [{attributes, record_info(fields, nilva_term_lsn_range_idx)},
            {ram_copies, [node()]}]),
    ?TOK = mnesia:create_table(nilva_state_transition,
            [{attributes, record_info(fields, nilva_state_transition)},
            {disc_copies, [node()]}]).


-spec get_current_term() -> raft_term() | {error, any()}.
get_current_term() ->
    Out = mnesia:transaction(fun() ->
        [X] = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
        {_, _, CT, _} = X,
        CT
    end),
    case Out of
        {atomic, CT} -> CT;
        {aborted, Reason} -> {error, {mnesia_error, Reason}}
    end.


-spec increment_current_term() -> ok | {error, any()}.
increment_current_term() ->
    Out = mnesia:transaction(fun() ->
            [{_, CT, _}] = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            % Reset voted_for when incrementing term
            mnesia:write({nilva_persistent_state, ?PERSISTENT_STATE_KEY, CT + 1, undefined})
          end),
    case Out of
        {atomic, _} -> ok;
        {aborted, Reason} -> {error, {mnesia_error, Reason}}
    end.


-spec set_current_term(raft_term()) -> ok | {error, any()}.
set_current_term(Term) ->
    Out = mnesia:transaction(fun() ->
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
          end),
    case Out of
        ?TOK -> ok;
        {aborted, Reason} -> {error, {mnesia_error, Reason}}
    end.


-spec get_voted_for() -> undefined | raft_peer_id() | {error, any()}.
get_voted_for() ->
    Out = mnesia:transaction(fun() ->
            Xs = mnesia:read(nilva_persistent_state, ?PERSISTENT_STATE_KEY),
            case Xs of
                [] -> undefined;
                [{_, _, _, Peer}] -> Peer
            end
          end),
    case Out of
        {atomic, Peer} -> Peer;
        {aborted, Reason} -> {error, {mnesia_error, Reason}}
    end.


-spec set_voted_for(raft_peer_id()) -> ok | already_voted | {error, any()}.
set_voted_for(Peer) ->
    Out = mnesia:transaction(fun() ->
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
          end),
    case Out of
        ?TOK -> ok;
        {atomic, already_voted} -> already_voted;
        {aborted, Reason} -> {error, {mnesia_error, Reason}}
    end.
