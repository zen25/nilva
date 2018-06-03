% Contains records, types & macros
%

%% ========================================================================
%% Types
%% ========================================================================

% TODO: How the hell do I declare a Maybe type like in Haskell?
% -type maybe(X) -> nil() | X.
-type raft_term() :: non_neg_integer().
-type raft_log_idx() :: non_neg_integer().
-type raft_peer_id() :: node().     % This is the node name.
                                    % Note that we are sending the msgs to a locally
                                    % registered process on various nodes

% Related to client requests to RSM
%
-type uuid() :: string().
-type csn() :: uuid().      % Client Sequence Number
% Note: Trying to simulate phantom types for string.
-type key() :: {'key', string()}.
-type value() :: {'value', string()}.
-type kv_error() :: {'error', string()}.
-type client_command() :: 'get' | 'put' | 'delete'.
-type client_request() :: {csn(), 'get', key()}
                        | {csn(), 'put', key(), value()}
                        | {csn(), 'delete', key()}.
-type response_to_client() :: {csn(), 'ok'}         % for put or delete
                            | {csn(), value()}      % for get
                            | {csn(), kv_error()}.  % for errors

% Related to the log & log entries
%
-type log_sequence_number() :: non_neg_integer().
-type entry() :: any().
-type status() :: volatile | durable | committed | applied.
-type rsm_response() :: 'undefined' | string().

% Others
%


%% ========================================================================
%% Log related records
%% ========================================================================
-record(log_entry, {
        lsn             :: log_sequence_number(),
        status          :: status(),
        entry           :: entry(),
        response        :: rsm_response()
        }).
-type log_entry() :: #log_entry{}.

-type file_name() :: string().
-type storage() :: file_name().

-record(raft_log, {
        log_entries     :: list(log_entry()),
        storage         :: storage(),
        last_applied    :: log_sequence_number(),
        last_committed  :: log_sequence_number(),
        last_written    :: log_sequence_number()
        }).
-type raft_log() :: #raft_log{}.

%% ========================================================================
%% Raft State
%% ========================================================================

-record(raft_config, {
        peers                   :: list(raft_peer_id()),
        heart_beat_interval     :: timeout(),
        election_timeout_min    :: timeout(),
        election_timeout_max    :: timeout(),
        client_request_timeout  :: timeout()
        }).
-type raft_config() :: #raft_config{}.

-record(raft_state, {
        % Persistent state on all servers
        current_term = 0    :: raft_term(),
        voted_for           :: 'undefined' | raft_peer_id(),
        % log                 :: raft_log(),
        % Note: There is a registered process for log
        config              :: raft_config(),

        % Voltile state on all server
        commit_idx = 0      :: raft_log_idx(),
        last_applied = 0    :: raft_log_idx(),      % Must be <= commit_idx

        % Volatile state on leaders
        next_idx            :: list({raft_peer_id(), raft_log_idx()}),
        match_idx           :: list({raft_peer_id(), raft_log_idx()}),

        % timeouts
        election_timeout    :: timeout()   % calculated every term
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
        entries                 :: list(entry()),
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
        vote_granted            :: 'undefined' | raft_peer_id()
        }).
-type reply_request_votes() :: #rrv{}.


