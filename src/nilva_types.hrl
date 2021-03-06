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
-type raft_cluster_commands() :: 'reload_config' | 'no_op'.

% Related to client requests to RSM
%
-type uuid() :: string().
-type csn() :: uuid().      % Client Sequence Number
% Note: Trying to simulate phantom types for string.
-type key() :: {'key', string()}.
-type value() :: {'value', string()}.
-type kv_error() :: {'error', string()}
                  | unavailable
                  | not_a_leader.
% Address of the client that we can use to reply to
-type client() :: any().
-type client_command() :: get | put | delete | cas.
-type client_request() :: {csn(), get, key()}
                        | {csn(), put, key(), value()}
                        | {csn(), delete, key()}
                        | {csn(), cas, key(), value(), value()}.
-type raft_commands() :: raft_cluster_commands()
                       | client_request().

-type response_to_client() :: {csn(), 'ok'}         % for put or delete
                            | {csn(), value()}      % for get
                            | {csn(), kv_error()}   % for errors
                            | undefined.

% Related to the log & log entries
%
-type entry() :: raft_commands().
-type status() :: volatile | durable | committed | applied.
-type rsm_response() :: 'undefined' | string().

% Others
%
-type kv_store() :: map().

%% ========================================================================
%% Log related records
%% ========================================================================
-record(log_entry, {
        term            :: raft_term(),
        index           :: raft_log_idx(),
        status          :: status(),
        entry           :: entry(),
        response        :: rsm_response()
        }).
-type log_entry() :: #log_entry{}.

% Note that Mnesia is being used as a storage engine.
% See nilva_mnesia.erl for more details

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

-record(raft, {
        % Persistent state on all servers
        current_term = 0    :: raft_term(),
        voted_for           :: 'undefined' | raft_peer_id(),
        % log                 :: raft_log(),
        % Note: There is a registered process for log
        config              :: raft_config(),

        % Voltile state on all server
        commit_idx = 0      :: raft_log_idx(),
        last_applied = 0    :: raft_log_idx(),      % Must be <= commit_idx

        % Volatile state on candidates
        % Number of elements in these two must equal number of peers or less
        votes_received      :: list(raft_peer_id()),
        votes_rejected      :: list(raft_peer_id()),

        % Volatile state on leaders
        next_idx            :: list({raft_peer_id(), raft_log_idx()}),
        match_idx           :: list({raft_peer_id(), raft_log_idx()}),

        % timeouts
        election_timeout    :: timeout(),   % calculated every term

        %
        % Implementation specific
        %

        % A buffer to store client requests.
        %
        % There is no selective receive in gen_statem. We keep
        % track of client requests we have not handled in a buffer
        % until we run into a msg that is not a client request.
        % Then we handle the client request in bulk
        %
        % TODO: We need a threshold on how long to wait before
        %       sending append entries or how many append entries
        %       should be buffered at max before they are serviced
        client_requests_buffer = [] :: list(client_request()),

        % Keeps track of which response must be sent to which client
        % Key :: csn(), Value :: client()
        csn_2_client = #{} :: map(),

        % Log Entries specific
        %
        % We are storing log entries as records in Mnesia.
        % There is no easy way to do "log_entries[-1]" to get the
        % last log entry to get it's term & index.
        % Hence, we are keeping track of them here for performance reasons.
        % We do not want to query the whole table everytime we need this info.
        last_log_idx = 0      :: raft_log_idx(),
        last_log_term = 0     :: raft_term(),

        % RSM KV Store
        %
        % Replcae this with something more robust at a later point
        kv_store = #{}        :: kv_store()
        }).
-type raft_state() :: #raft{}.



%% ========================================================================
%% RAFT Messages & Replies (From Figure 2)
%% ========================================================================

% Append Entries Request
-record(ae, {
        leaders_term            :: raft_term(),
        leader_id               :: raft_peer_id(),
        prev_log_idx            :: raft_log_idx(),
        prev_log_term           :: raft_term(),
        entries                 :: list(entry()),
        leaders_commit_idx      :: raft_log_idx()
    }).
-type append_entries() :: #ae{}.


% Append Entries Reply
-record(rae, {
        peers_current_term      :: raft_term(),
        % peer_id & peers_last_log_idx indicate the log state to the
        % leader so that it can update the next_index[] & match_index[]
        % appropriately
        peer_id                 :: raft_peer_id(),
        peers_last_log_idx      :: raft_log_idx(),
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
%
% Note that when a peer grants it vote, it updates its term to that of the candidate
% So, resending the message to the candidate becomes idempotent for that term
-record(rrv, {
        peers_current_term      :: raft_term(),
        peer_id                 :: raft_peer_id(),
        vote_granted            :: boolean()
        }).
-type reply_request_votes() :: #rrv{}.


