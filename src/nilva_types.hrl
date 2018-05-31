% Contains records, types & macros
%


%% TODO: Extract these into a config file at a later point
-define(HEART_BEAT_TIMEOUT, 25).
-define(CLIENT_RESPONSE_TIMEOUT, 5000).     % Default
-define(MAXIMUM_TIME_FOR_BOOTSTRAPPING, 60000).     % Wait for a minute for bootstrapping

%% ========================================================================
%% Types
%% ========================================================================

% TODO: How the hell do I declare a Maybe type like in Haskell?
% -type maybe(X) -> nil() | X.
-type raft_term() :: non_neg_integer().
-type raft_log_idx() :: non_neg_integer().
-type raft_peer_id() :: string().

-type uuid() :: string().
-type client_sequence_number() :: uuid().
-type client_command() :: get | put | delete.
-type client_request() :: {uuid() | client_command(), string()}.
-type response_to_client() :: {uuid(), boolean(), string()}.

-type log_sequence_number() :: non_neg_integer().
-type entry() :: any().
-type status() :: volatile | durable | committed | applied.
-type response() :: undefined | string().

%% ========================================================================
%% Raft State
%% ========================================================================

-record(raft_state, {
        % Persistent state on all servers
        current_term = 0    :: raft_term(),
        voted_for           :: undefined | raft_peer_id(),
        log,

        % Volatile state on all server
        commit_idx = 0      :: raft_log_idx(),
        last_applied = 0    :: raft_log_idx(),      % Must be <= commit_idx

        % Volatile state on leaders
        next_idx,
        match_idx
        }).
-type raft_state() :: #raft_state{}.

%% ========================================================================
%% RAFT Messages & Replies (From Figure 2)
%% ========================================================================

% Append Entries Request
-record(ae, {
        leaders_term            :: raft_term(),
        leader_id               :: raft_peer_id(),
        prev_log_idx            :: raft_term(),
        prev_log_term           :: raft_term(),
        entries,
        leaders_commit_idx      :: raft_log_idx()
    }).
-type append_entries() :: #ae{}.


% Append Entries Reply
-record(rae, {
        peers_current_term      :: raft_term(),
        peer_id                 :: raft_peer_id(),
        success                 :: boolean()
        }).
-type reply_append_entries() :: #rae{}.


% Request Votes Request
-record(rv, {
        candidates_term     :: raft_term(),
        candidate_id        :: raft_peer_id(),
        last_log_idx        :: raft_log_idx(),
        last_log_term       :: raft_term()
        }).
-type request_votes() :: #rv{}.


% Request Votes Reply
-record(rrv, {
        peers_current_term      :: raft_term(),
        vote_granted            :: undefined | raft_peer_id()
        }).
-type reply_request_votes() :: #rrv{}.

%% ========================================================================
%% RAFT Messages & Replies (From Figure 2)
%% ========================================================================


