% Implements the Raft Consensus algorithm
%
-module(nilva_raft_fsm).

-behaviour(gen_statem).
-include("nilva_types.hrl").

%% Cluster & Peer management
-export([start/2, start_link/0, stop/1, join/1]).

% gen_statem callbacks & state
-export([init/1,
        callback_mode/0,
        terminate/3,
        handle_sync_event/4]).
-export([leader/3, follower/3, candidate/3]).

% For testing & debugging
-export([echo/1, echo/2]).


%% =========================================================================
%% Raft Peer/Cluster API
%% =========================================================================
start(PeerName, {Peers, ElectionTimeOut, CheckSuccessfulStartup}) ->
    % Assuming that Peer names are unique in the global erlang cluster
    gen_statem:start_link({global, PeerName}, ?MODULE,
                       [PeerName, Peers, ElectionTimeOut, CheckSuccessfulStartup], []).

start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

stop(PeerName) ->
    gen_statem:stop(PeerName).

join(_Peer) ->
    % Send a ping request to join the cluster
    % Do we need this? Aren't we using the erlangs distributed cluster management
    % capabilities?
    %
    ok.


%% =========================================================================
%% CALLBACKS (gen_statem)
%% =========================================================================
init(_Args) ->
    % Read the config file, calculate election timeout and initialize raft state
    % as follower. The cluster should become connected when the first election
    % starts
    ConfigFile = "nilva_cluster.config",
    case nilva_config:read_config(ConfigFile) of
        {error, Error} ->
            % TODO: Dialyzer still throws warnings w.r.t lager
            _Ignore = lager:error("node:~p term:~p state:~p event:~p action:~p",
                                  [node(), -1, init, error_reading_config, stop]),
            _Ignore2 = lager:error("Please correct the config file."),
            {stop, {error, Error}};
        Config ->
            Data = init_raft_state(Config),
            _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                                 [node(), -1, init, successfully_read_config, start]),
            _Ignore2 = lager:info("election_timeout:~p", [Data#raft.election_timeout]),
            ElectionTimeOutAction = {{timeout, election_timeout},
                                    Data#raft.election_timeout, election_timeout },
            {ok, follower, Data, [ElectionTimeOutAction]}
    end.

callback_mode() ->
    [state_functions, state_enter].

handle_sync_event(stop, _From, _State, LoopData) ->
    {stop, normal, LoopData}.


terminate(_Reason, _StateName, _LoopData) ->
    ok.


%% =========================================================================
%% STATES
%% =========================================================================


% Follower State Callback
%
% State change (candidate -> follower)
follower(enter, candidate, Data) ->
    {keep_state_and_data, [stop_heartbeat_timer(Data), reset_election_timer(Data)]};
% State change (leader -> follower)
follower(enter, leader, Data) ->
    % Turn off the heart beat timer & start the election timer
    % The next event processed must be post-poned event
    {keep_state_and_data,
        [stop_heartbeat_timer(Data), start_election_timer(Data)]};
% Election timeout
follower({timeout, election_timeout}, election_timeout, Data) ->
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), Data#raft.current_term, follower,
                        election_timeout, nominate_self]),
    {next_state, candidate, Data};
% Append Entries request (valid heartbeat, current term)
follower(cast, AE=#ae{leaders_term=LT, entries=[]}, Data = #raft{current_term=FT})
    when FT =:= LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, reset_election_timer]),
        Success = log_is_up_to_date == nilva_replication_log:check_log_completeness(AE, Data),
        RAE = #rae{peers_current_term = FT,
                   peer_id = node(),
                   peers_last_log_idx = Data#raft.last_log_idx,
                   success = Success
                   },
        erlang:display(RAE),
        cast(AE#ae.leader_id, RAE),
        {keep_state_and_data, [reset_election_timer(Data)]};
% Append Entries request (valid heartbeat, leader with higher term)
follower(cast, AE=#ae{leaders_term=LT, entries=[]}, Data = #raft{current_term=FT})
    when FT < LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, update_term_and_reset_election_timer]),
        NewData = update_term(Data, LT),
        {keep_state, NewData, [{next_event, cast, AE}]};
% Append Entries request (valid, leader with higher term)
follower(cast, AE=#ae{leaders_term=LT}, Data=#raft{current_term=FT})
    when FT < LT ->
        NewData = update_term(Data, LT),
        {keep_state, NewData, [{next_event, cast, AE}]};
% Append Entries request (valid, leader with current term)
follower(cast, AE=#ae{leaders_term=LT}, Data=#raft{current_term=FT})
    when FT =:= LT ->
        ok = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, AE, append_entries_to_log]),
        % TODO: Refactor this into a separate function
        case append_entries_to_log(AE, Data) of
            log_not_up_to_date ->
                ok = lager:info("Follower's log is NOT complete"),
                ok = lager:info("Last Entry {idx, term}: F = {~p, ~p}, L = {~p, ~p}",
                                [Data#raft.last_log_idx, Data#raft.last_log_term,
                                AE#ae.prev_log_idx, AE#ae.prev_log_term]),
                RAE = #rae{
                        peers_current_term = FT,
                        peer_id = node(),
                        peers_last_log_idx = Data#raft.last_log_idx,
                        success = false
                    },
                cast(AE#ae.leader_id, RAE),
                {keep_state_and_data, []};
            failed_to_update_log ->
                % TODO: This is a peculiar case, we can retry to append entries here
                %       or stop after throwing the error
                ok = lager:error("Failed to persist log entries to ~p's log",
                                 [node()]),
                RAE = #rae{
                        peers_current_term = FT,
                        peer_id = node(),
                        peers_last_log_idx = Data#raft.last_log_idx,
                        success = false
                    },
                cast(AE#ae.leader_id, RAE),
                {keep_state_and_data, []};
            NewData ->
                RAE = #rae{
                        peers_current_term = FT,
                        peer_id = node(),
                        peers_last_log_idx = NewData#raft.last_log_idx,
                        success = true
                    },
                cast(AE#ae.leader_id, RAE),
                {keep_state, NewData, []}
        end;
% Append Entries request (invalid)
follower(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=FT})
    when FT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, reject_ae]),
        RAE = #rae{peers_current_term = FT,
                   peer_id = node(),
                   peers_last_log_idx = Data#raft.last_log_idx,
                   success = false
                   },
        cast(AE#ae.leader_id, RAE),
        {keep_state_and_data, []};
% Request Votes request (invalid)
follower(cast, RV = #rv{candidates_term=CT}, Data = #raft{current_term=FT})
    when FT > CT ->
        % Deny the vote
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower,
                            received_invalid_rv, deny_vote_stale_term]),
        {RRV, Candidate} = nilva_election:deny_vote(Data, RV),
        cast(Candidate, RRV),
        {keep_state_and_data, []};
% Request Votes (valid)
follower(cast, RV = #rv{candidates_term=CT}, Data=#raft{current_term=FT})
    when FT =< CT ->
        {CanGrantVote, Reason} = nilva_election:is_viable_leader(Data, RV),
        case CanGrantVote of
            true ->
                {RRV, Candidate, NewData} = nilva_election:cast_vote(Data, RV),
                cast(Candidate, RRV),
                _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), FT, follower, received_valid_rv, Reason]),
                {keep_state, NewData, [reset_election_timer(NewData)]};
            false ->
                {RRV, Candidate} = nilva_election:deny_vote(Data, RV),
                cast(Candidate, RRV),
                _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), FT, follower, received_valid_rv, Reason]),
                {keep_state_and_data, [reset_election_timer(Data)]}
        end;
% Stale Messages
% Heartbeats are not valid in follower state. Follower is passive
follower({timeout, heartbeat_timeout}, heartbeat_timeout, #raft{current_term=FT}) ->
    _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, stale_heartbeat_timeout, ignore]),
    {keep_state_and_data, []};
% Ignoring replies to Append Entries. Follower is passive
follower(cast, #rae{}, #raft{current_term=FT}) ->
    _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, stale_rae, ignore]),
    {keep_state_and_data, []};
% Client Request
%
% Simply return that you are not a leader, the client can try the other peers
% till it finds the leader.
% TODO: Return the leader if known
follower({call, From}, {client_request, _}, _) ->
    Reply = not_a_leader,
    {keep_state_and_data, [{reply, From, Reply}]};
% Events not part of Raft
follower(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).




% Candidate State Callback
%
% State Change (follower -> candidate)
candidate(enter, follower, Data) ->
    % Start a new election
    {RV, NewData} = nilva_election:start_election(Data),
    _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                        [node(), NewData#raft.current_term, candidate,
                        election_timeout, start_election]),
    % TODO: Persist data before broadcasting request votes
    broadcast(get_peers(NewData), RV),
    {next_state, candidate, NewData,
        [start_heartbeat_timer(NewData), start_election_timer(NewData)]};
% Invalid State Change (leader x-> candidate)
candidate(enter, leader, _) ->
    Error = "Cannot become a candidate from a leader",
    _Ignore = lager:error(Error),
    {stop, {error, Error}};
% Election timeout
candidate({timeout, election_timeout}, election_timeout, Data) ->
    % Start a new election
    {RV, NewData} = nilva_election:start_election(Data),
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), NewData#raft.current_term, candidate,
                        election_timeout, start_election]),
    % TODO: Persist data before broadcasting request votes
    broadcast(get_peers(NewData), RV),
    {next_state, candidate, NewData,
        [reset_heartbeat_timer(NewData), start_election_timer(NewData)]};
% Heartbeat timeout
candidate({timeout, heartbeat_timeout}, heartbeat_timeout, Data) ->
    % Resend request votes for peers who did not reply & start heart beat timer again
    {RV, Unresponsive_peers} = nilva_election:resend_request_votes(Data, get_peers(Data)),
    % _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
    %                     [node(), Data#raft.current_term, candidate,
    %                     heartbeat_timeout, resend_rv]),
    broadcast(Unresponsive_peers, RV),
    {keep_state_and_data, [start_heartbeat_timer(Data)]};
% Append Entries request (valid, there is already a leader for this term)
candidate(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=CT})
    when CT =:= LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, candidate, AE, step_down]),
        ProcessEventAsFollower = {next_event, cast, AE},
        {next_state, follower, Data, [ProcessEventAsFollower]};
% Append Entries request (valid, leader with higher term)
candidate(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=CT})
    when CT < LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, candidate, AE, update_term_and_step_down]),
        NewData = update_term(Data, LT),
        ProcessEventAsFollower = {next_event, cast, AE},
        {next_state, follower, NewData, [ProcessEventAsFollower]};
% Append Entries request (invalid)
candidate(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=CT})
    when CT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, candidate, AE, reject_ae]),
        RAE = #rae{peers_current_term = CT,
                   peer_id = node(),
                   peers_last_log_idx = Data#raft.last_log_idx,
                   success = false
                   },
        cast(AE#ae.leader_id, RAE),
        {keep_state_and_data, []};
% Request Votes request (invalid)
candidate(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm >= CT ->
        % Either stale request or from the same term
        % Deny Vote
        _Ignore = lager:debug("{node:~p} {event:~p} {from_node:~p}",
                            [node(), deny_vote_already_voted, RV#rv.candidate_id]),
        {RRV, Peer} = nilva_election:deny_vote(Data, RV),
        cast(Peer, RRV),
        {keep_state_and_data, []};
% Request Votes request (valid)
candidate(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm < CT ->
        % There is a candidate with higher term
        % Step down & re-process this event
        _Ignore =lager:debug("{node:~p} {event:~p}", [node(), stepping_down_as_candidate]),
        ProcessEventAsFollower = {next_event, cast, RV},
        {next_state, follower, Data, [ProcessEventAsFollower]};
% Reply to Request Votes (valid)
candidate(cast, RRV=#rrv{peers_current_term = PTerm}, Data = #raft{current_term = Term})
    when PTerm =:= Term ->
        % Collect the votes and see if you can become the leader
        {WonElection, NewData} = nilva_election:count_votes(RRV, Data),
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, candidate,
                            RRV, count_votes]),
        case WonElection of
            true ->
                _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), Term, candidate, RRV, stepup_as_leader]),
                {next_state, leader, NewData};
            false ->
                _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), Term, candidate, RRV,
                                    no_majority_continue_waiting]),
                {keep_state, NewData}
        end;
% Stale msg
candidate(cast, RRV= #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm < Term ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, candidate,
                            RRV, ignore]),
        {keep_state_and_data, []};
% Impossible message
candidate(cast, #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm > Term ->
        Error = "Received a RRV from a future term. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
% Stale msg
candidate(cast, RAE = #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm < Term ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, candidate,
                            RAE, ignore]),
        {keep_state_and_data, []};
% Client Request
%
% Simply return that you are not available for processing requests. Client
% can either try other peers or wait & retry
candidate({call, From}, {client_request, _}, _) ->
    {keep_state_and_data, [{reply, From, unavailable}]};
% Impossible message
candidate(cast, #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm >= Term ->
        Error = "Received a RAE from a future term. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
candidate(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).



% Leader State Callback
%
% State Change (candidate -> leader)
leader(enter, candidate, Data) ->
    % Send out a no op to establish your authority,
    % stop the election timer and restart the heartbeat timer
    % Turn off the heart beat timer & start the election timer
    % The next event processed must be post-poned event
    % TODO: Reinitialize nextIndex & matchIndex
    NewData = Data#raft{votes_received = [], votes_rejected = []},
    _Ignore = lager:debug("{node:~p} {event:~p} {term:~p}",
                         [node(), starting_term_as_leader, Data#raft.current_term]),
    AE = nilva_election:send_heart_beats(NewData),
    broadcast(get_peers(NewData), AE),
    {keep_state, NewData,
        [start_heartbeat_timer(NewData), stop_election_timer(NewData)]};
% Invalid State Change (follower x-> leader)
leader(enter, follower, _) ->
     Error = "Cannot become a leader from a follower",
    _Ignore = lager:error(Error),
    {stop, {error, Error}};
leader({timeout, heartbeat_timeout}, heartbeat_timeout, Data) ->
    % Send a no-op append entries to maintain authority
    _Ignore = lager:debug("{node:~p} {event:~p} {term:~p}",
                         [node(), sending_heart_beats, Data#raft.current_term]),
    AE = nilva_election:send_heart_beats(Data),
    broadcast(get_peers(Data), AE),
    {keep_state_and_data, [reset_heartbeat_timer(Data)]};
% Append Entries (Impossible, there should only be one leader per term)
leader(cast, #ae{leaders_term=LT}, #raft{current_term=CT})
    when CT =:= LT ->
        Error = "Received a AE from current term as leader. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
% Append Entries request (valid, leader with higher term)
leader(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=CT})
    when CT < LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, leader, AE, update_term_and_step_down]),
        NewData = update_term(Data, LT),
        ProcessEventAsFollower = {next_event, cast, AE},
        {next_state, follower, NewData, [ProcessEventAsFollower]};
% Append Entries request (invalid)
leader(cast, AE=#ae{leaders_term=LT}, Data = #raft{current_term=CT})
    when CT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, leader, AE, reject_ae]),
        RAE = #rae{peers_current_term = CT,
                   peer_id = node(),
                   peers_last_log_idx = Data#raft.last_log_idx,
                   success = false
                   },
        cast(AE#ae.leader_id, RAE),
        {keep_state_and_data, []};
% Request Votes request (invalid)
leader(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm >= CT ->
        % Either stale request or from the same term
        % Deny Vote
        _Ignore = lager:debug("{node:~p} {event:~p} {from_node:~p}",
                            [node(), deny_vote_already_voted, RV#rv.candidate_id]),
        {RRV, Peer} = nilva_election:deny_vote(Data, RV),
        cast(Peer, RRV),
        {keep_state_and_data, []};
% Request Votes request (valid)
leader(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm < CT ->
        % There is a candidate with higher term
        % Step down & re-process this event
        _Ignore =lager:debug("{node:~p} {event:~p}", [node(), step_down_as_leader]),
        NewData = update_term(Data, CT),
        ProcessEventAsFollower = {next_event, cast, RV},
        {next_state, follower, NewData, [ProcessEventAsFollower]};
% Stale msg
leader(cast, RRV= #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm =< Term ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, leader,
                            RRV, ignore]),
        {keep_state_and_data, []};
% Impossible message
leader(cast, #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm > Term ->
        Error = "Received a RRV from a future term. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
% Stale msg
leader(cast, RAE = #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm < Term ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, leader,
                            RAE, ignore]),
        {keep_state_and_data, []};
% Append Entries Reply (valid, current term)
leader(cast, RAE = #rae{peers_current_term = PTerm}, Data = #raft{current_term = Term})
    when PTerm =:= Term ->
        % TODO: Handle other things that are not no_op
        ok = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                        [node(), Term, leader, RAE, handle_reply_to_ae]),
        NewData = handle_reply_to_ae(RAE, Data),
        {keep_state, NewData, []};
% Impossible message
leader(cast, #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm > Term ->
        Error = "Received a RAE from a future term. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
% Buffer Client Requests
leader({call, From}, {client_request, Req}, Data) ->
    % NOTE: gen_statem does not have selective recieve. You can simulate
    %       it by postponing the events that you are not interested in and
    %       and using a buffer to store the interesting events.
    NewData = buffer_client_request(From, Req, Data),
    % NOTE: The reply should happen after the rsm command has been applied
    %       For that to happen, we cannot block here.
    %       We probably need to include From address in the rsm command or
    %       have a map of CSN -> From somewhere
    %
    % NOTE: Client is still waiting in the mean time as it made a synchronous
    %       call.
    % TODO: Where & how should you handle client request timeouts? Makes sense
    %       to handle it on the client side
    %
    % TODO: Broadcast of AEs should happen once we encounter a msg that is
    %       not a client request or a timeout has been reached or if the
    %       number of messages in the buffer has exceeded a specific threshold.
    %       The threshold & timeout must be user configurable
    ok = lager:info("node:~p term:~p state:~p event:~p action:~p",
                    [node(), Data#raft.current_term, leader,
                    {client_request, Req}, handle_client_request]),

    {keep_state, NewData, [{next_event, cast, process_buffered_requests}]};
% Process Buffered Client Requests
%
% Replicate the client request, once replicated on quorum of peers, apply to rsm
% and return the result to client. Notify the peers about commit index too
leader(cast, process_buffered_requests, Data) ->
    % NOTE: We do not need to create AEs to write client requests to leader's log.
    %       But we still do it as we can use the same code a follower does
    AEs = make_append_entries(Data),
    case append_entries_to_log(AEs, Data) of
        log_not_up_to_date ->
            Error = "Leader's log is always complete",
            ok = lager:error(Error),
            {stop, {error, Error}};
        failed_to_update_log ->
            ok = lager:error("Failed to persist log entries to leader's log"),
            {keep_state_and_data, []};
        NewData ->
            AE_MsgForPeers = [{P, make_ae_for_peer(Data, P)} ||
                              P <- get_peers(Data)],
            broadcast(AE_MsgForPeers),
            {keep_state, NewData, []}
    end;
leader(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).


%% =========================================================================
%% Helpers (Private)
%% =========================================================================

handle_event({call, From}, {echo, Msg}, _) ->
    {keep_state_and_data, {reply, From, {echo, ?MODULE, node(), Msg}}};
handle_event({call, From}, get_state, Data) ->
    {keep_state_and_data, {reply, From, Data}};
handle_event(_, _, #raft{current_term=T}) ->
    _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                         [node(), T, any, received_unknown_message, ignoring_unknown_message]),
    {keep_state_and_data, []}.


-spec buffer_client_request(client(), client_request(), raft_state()) -> raft_state().
buffer_client_request(From, Req = {CSN, _, _} , Data) ->
    CSN_2_Client = maps:put(CSN, From, Data#raft.csn_2_client),
    % NOTE: Appending an element to the end of the list is inefficient
    %       as we would need to traverse the whole list before adding to
    %       the tail. Hence, we are building the buffer in reverse order
    %       so that a single reverse gives us the correct requests order.
    %
    % NOTE: Order of arrival is important as we intend to provide linearizability
    % TODO: Setup a test to check this
    Client_requests_buffer = [Req] ++ Data#raft.client_requests_buffer,
    Data#raft{
        client_requests_buffer = Client_requests_buffer,
        csn_2_client = CSN_2_Client
    };
buffer_client_request(From, Req = {CSN, _, _, _}, Data) ->
    CSN_2_Client = maps:put(CSN, From, Data#raft.csn_2_client),
    Client_requests_buffer = [Req] ++ Data#raft.client_requests_buffer,
    Data#raft{
        client_requests_buffer = Client_requests_buffer,
        csn_2_client = CSN_2_Client
    };
buffer_client_request(From, Req = {CSN, _, _, _, _}, Data) ->
    CSN_2_Client = maps:put(CSN, From, Data#raft.csn_2_client),
    Client_requests_buffer = [Req] ++ Data#raft.client_requests_buffer,
    Data#raft{
        client_requests_buffer = Client_requests_buffer,
        csn_2_client = CSN_2_Client
    }.


-spec append_entries_to_log(append_entries(), raft_state()) ->
    raft_state()
    | log_not_up_to_date
    | failed_to_update_log.
append_entries_to_log(AE, Data) ->
    case nilva_replication_log:check_log_completeness(AE, Data) of
        log_is_missing_entries ->
            % NOTE: Leader's log is the single source of truth. It is
            %       by definition complete. Hence, log completion should
            %       always return true for the leader
            log_not_up_to_date;
        log_is_up_to_date ->
            % We have all the entries from leader and there are no extraneous log entries
            LogEntries = convert_ae_to_log_entries(AE),
            case nilva_replication_log:append_entries(LogEntries) of
                ok ->
                    [LastLogEntry | _] = lists:reverse(LogEntries),
                    NewData = Data#raft{
                                    client_requests_buffer = [],
                                    last_log_idx = LastLogEntry#log_entry.index,
                                    last_log_term = LastLogEntry#log_entry.term
                                },
                    NewData;
                {error, Error} ->
                    ok = lager:error("Unable to persist log entries"),
                    ok = lager:error(Error),
                    failed_to_update_log
            end;
        log_needs_to_be_overwritten ->
            % We have the entries but there are extraneous log entries in follower
            LastCommonLEIdx = AE#ae.prev_log_idx,
            nilva_replication_log:erase_log_entries(LastCommonLEIdx + 1),
            LogEntries = convert_ae_to_log_entries(AE),
            case nilva_replication_log:append_entries(LogEntries) of
                ok ->
                    [LastLogEntry | _] = lists:reverse(LogEntries),
                    NewData = Data#raft{
                                    client_requests_buffer = [],
                                    last_log_idx = LastLogEntry#log_entry.index,
                                    last_log_term = LastLogEntry#log_entry.term
                                },
                    NewData;
                {error, Error} ->
                    ok = lager:error("Unable to persist log entries"),
                    ok = lager:error(Error),
                    failed_to_update_log
            end
    end.


-spec make_append_entries(raft_state()) -> append_entries().
% TODO: Some followers might be stale, we need to send other
%       log entries that are not part of current buffered client requests
make_append_entries(Data) ->
    % See the note in buffer_client_request/3 w.r.t reverse
    ClientRequestInOrderOfArrival = lists:reverse(Data#raft.client_requests_buffer),
    #ae{
        leaders_term    = Data#raft.current_term,
        leader_id       = node(),
        prev_log_idx    = Data#raft.last_log_idx,
        prev_log_term   = Data#raft.last_log_term,
        entries         = ClientRequestInOrderOfArrival,
        leaders_commit_idx = Data#raft.commit_idx
    }.


-spec make_ae_for_peer(raft_state(), raft_peer_id()) -> append_entries().
make_ae_for_peer(Data, Peer) ->
    NextIndex = proplists:get_value(Peer, Data#raft.next_idx),
    LEs = nilva_replication_log:get_log_entries(NextIndex),
    Entries = [LE#log_entry.entry || LE <- LEs],
    {LastLogIdx, LastLogTerm} = case NextIndex =< 1 of
        true ->
            {0, 0};
        false ->
            LastLogEntry = nilva_replication_log:get_log_entry(NextIndex - 1),
            % erlang:display(LastLogEntry),
            {LastLogEntry#log_entry.index, LastLogEntry#log_entry.term}
    end,
    % See the note in buffer_client_request/3 w.r.t reverse
    ClientRequestInOrderOfArrival = lists:reverse(Data#raft.client_requests_buffer),
    #ae{
        leaders_term    = Data#raft.current_term,
        leader_id       = node(),
        prev_log_idx    = LastLogIdx,
        prev_log_term   = LastLogTerm,
        entries         = Entries ++ ClientRequestInOrderOfArrival,
        leaders_commit_idx = Data#raft.commit_idx
    }.


-spec convert_ae_to_log_entries(append_entries()) -> list(log_entry()).
convert_ae_to_log_entries(AE) ->
    % Monotonically increase index starting from last_log_index if the term is the
    % same, otherwise add a no-op and increment the index starting from 0.
    %
    % TODO: Handle more than one log entry
    LE = #log_entry{
            term = AE#ae.leaders_term,
            index = AE#ae.prev_log_idx + 1,
            status = volatile,
            entry = hd(AE#ae.entries),
            response = undefined
        },
    [LE].


-spec handle_reply_to_ae(reply_append_entries(), raft_state()) -> raft_state().
handle_reply_to_ae(RAE = #rae{success=true, peer_id=Peer}, Data) ->
    % Update the nextIndex & matchIndex after checking if we got a duplicate
    % or stale message
    MatchIdx = proplists:get_value(Peer, Data#raft.match_idx),
    Res = case MatchIdx >= RAE#rae.peers_last_log_idx of
        true ->
            % We can ignore this message
            % Either we already processed a duplicate of this message
            % or assumed log completeness as we received success for a
            % last_log_idx higher than this msg's
            Data;
        false ->
            MatchIndices = proplists:delete(Peer, Data#raft.match_idx),
            NextIndices = proplists:delete(Peer, Data#raft.next_idx),
            Data#raft{
                next_idx = NextIndices ++ [{Peer, RAE#rae.peers_last_log_idx + 1}],
                match_idx = MatchIndices ++ [{Peer, RAE#rae.peers_last_log_idx}]
            }
    end,
    NewRes = check_and_commit_log_entries(Res),
    NewRes;
handle_reply_to_ae(RAE = #rae{success=false, peer_id=Peer}, Data) ->
    % Update the nextIndex & matchIndex after checking if we got a duplicate
    % or stale message
    MatchIdx = proplists:get_value(Peer, Data#raft.match_idx),
    Res = case MatchIdx >= RAE#rae.peers_last_log_idx of
        true ->
            % We can ignore this message
            % Either we already processed a duplicate of this message
            % or assumed log completeness as we received success for a
            % last_log_idx higher than this msg's
            Data;
        false ->
            NextIndices = proplists:delete(Peer, Data#raft.next_idx),
            NewData = Data#raft{
                next_idx = NextIndices ++ [{Peer, max(RAE#rae.peers_last_log_idx - 1, 0)}]
            },
            ok = lager:info("~p is lagging behind leader ~p. Bring it up to date",
                            [Peer, node()]),
            AE = make_ae_for_peer(NewData, Peer),
            cast(Peer, AE)
    end,
    Res.


-spec check_and_commit_log_entries(raft_state()) -> raft_state().
check_and_commit_log_entries(Data) ->
    % See if there any outstanding log entries for which a quorum has been reached,
    % commit them, apply to rsm, reply to client & send commit_idx to all peers
    NewCommitIdx = get_new_commit_index(Data),
    case NewCommitIdx > Data#raft.commit_idx of
        false ->
            % Nothing to do, we have already committed all the possible log entries
            Data;
        true ->
            % Apply log entries in [commit_idx + 1, N] to RSM
            % get the results and send response to clients
            % using csn_2_client table
            {Responses, KVStore} = apply_to_RSM(Data#raft.commit_idx + 1,
                                                NewCommitIdx, Data#raft.kv_store),
            % Send responses to appropriate clients while updating csn_2_client
            P = fun(R, CSN_2_Client) ->
                New_CSN_2_Client = reply_to_client(R, CSN_2_Client),
                New_CSN_2_Client
            end,
            Final_CSN_2_Client = lists:foldl(P, Data#raft.csn_2_client, Responses),
            Data#raft{
                commit_idx=NewCommitIdx,
                csn_2_client=Final_CSN_2_Client,
                kv_store=KVStore}
    end.


-spec get_new_commit_index(raft_state()) -> raft_log_idx().
get_new_commit_index(Data = #raft{
                         current_term=Term,
                         commit_idx=CommitIdx,
                         match_idx=MatchIndices})
->
    NQuorum = nilva_config:num_required_for_quorum(Data),
    NewCommitIdx = get_new_commit_index_loop(Term, CommitIdx + 1, MatchIndices, NQuorum),
    NewCommitIdx.


get_new_commit_index_loop(Term, N, MatchIndices, NQuorum) ->
    case ready_to_commit(Term, N, MatchIndices, NQuorum) of
        true ->
            get_new_commit_index_loop(Term, N + 1, MatchIndices, NQuorum);
        false ->
            N - 1
    end.


ready_to_commit(Term, N, MatchIndices, NQuorum) ->
    case nilva_replication_log:get_log_entry(N) of
        {error, _} ->
            false;
        LE ->
            LETerm = LE#log_entry.term,
            Xs = lists:filter(
                    fun({_Peer, MIdx}) ->
                        (MIdx >= N) and (Term == LETerm)
                    end,
                    MatchIndices),
            % +1 is for counting the leader's log entry
            NQuorum =< (length(Xs) + 1)
    end.


-spec apply_to_RSM(raft_log_idx(), raft_log_idx(), map()) ->
    {list(response_to_client()), kv_store()}.
apply_to_RSM(StartingIdx, EndingIdx, KVStore) ->
    LogEntries = lists:map(fun nilva_replication_log:get_log_entry/1,
                           lists:seq(StartingIdx, EndingIdx)),
    {FinalKVStore, Responses} = lists:foldl(
                                    fun apply_log_entry/2,
                                    {KVStore, []},
                                    LogEntries),
    {Responses, FinalKVStore}.


% TODO: We just need the commands here, no need for log_entry(). Refactor
-spec apply_log_entry(log_entry(), {kv_store(), list(response_to_client())}) ->
    {kv_store(), list(response_to_client())}.
apply_log_entry(LE, {KVStore, Responses}) ->
    % TODO: We need to update the replication log with response so that
    %       we can serve idempotent client requests in the future
    case LE#log_entry.entry of
        {CSN, get, K} ->
            case maps:find(K, KVStore) of
                {ok, V} ->
                    {KVStore, Responses ++ [{CSN, V}]};
                error ->
                    {KVStore, Responses ++ [{CSN, {error, "No such key"}}]}
            end;
        {CSN, put, K, V} ->
            NewKVStore = maps:put(K, V, KVStore),
            {NewKVStore, Responses ++ [{CSN, ok}]};
        {CSN, delete, K} ->
            NewKVStore = maps:remove(K, KVStore),
            {NewKVStore, Responses ++ [{CSN, ok}]};
        no_op ->
            {KVStore, Responses};
        % reload_config ->
        %     % TODO: Support on the fly configuration changes in the future
        %     {KVStore, Responses};
        Unknown ->
            ok = lager:error("Unknown RSM command: ~p, ignoring.", [Unknown]),
            {KVStore, Responses}
    end.



-spec reply_to_client(response_to_client(), map()) -> map().
% Send response to the client based on csn & then remove the corresponding
% entry from csn_2_client map
reply_to_client(Response = {CSN, _}, CSN_2_Client) ->
    {ok, Client} = maps:find(CSN, CSN_2_Client),
    % Note: See gen_statem.erl source code on the structure of `From`
    {ClientPID, Tag} = Client,
    % TODO: Since otp already tags the msg when sending it, is csn necessary
    %       for erlang api?
    ClientPID ! {Tag, Response},
    maps:remove(CSN, CSN_2_Client);
reply_to_client(_, CSN_2_Client) ->
    CSN_2_Client.


-spec broadcast(list(raft_peer_id()), any()) -> no_return().
% Send the given msg to all the peers
broadcast(Peers, Msg) ->
    lists:foreach(fun(Node) -> cast(Node, Msg) end, Peers).


-spec broadcast(list({raft_peer_id(), any()})) -> no_return().
% Send the message to the chosen peer, for all X in given list of msgs
broadcast(Msgs) ->
    lists:foreach(fun({Node, Msg}) -> cast(Node, Msg) end, Msgs).


-spec cast(node(), any()) -> no_return().
-ifdef(TEST).
% Route through proxy when testing
cast(Node, Msg) ->
    gen_server:cast(nilva_test_proxy, {send_to, Node, Msg}).
-else.
cast(Node, Msg) ->
    gen_statem:cast({?MODULE, Node}, Msg).
-endif.


-spec init_raft_state(raft_config()) -> raft_state().
init_raft_state(Config) ->
    nilva_replication_log:init(),
    Peers = Config#raft_config.peers,
    {LastLogIdx, LastLogTerm} = nilva_replication_log:get_last_log_idx_and_term(),
    #raft{
            config = Config,
            votes_received = [],
            votes_rejected = [],
            last_log_idx = LastLogIdx,
            last_log_term = LastLogTerm,
            next_idx = [{P, 0} || P <- Peers],
            match_idx = [{P, 0} || P <- Peers],
            election_timeout = nilva_election:get_election_timeout(Config)
        }.


-spec update_term(raft_state(), raft_term()) -> raft_state().
update_term(Raft = #raft{current_term = CT}, Term)
    when Term > 0, CT < Term ->
        % NOTE: Clear the voting related entries as we are in a new term
        %       Reset the election timeout too
        nilva_replication_log:set_current_term(Term),
        NewElectionTimeout = nilva_election:get_election_timeout(Raft#raft.config),
        Raft#raft{current_term = Term,
                  voted_for = undefined,
                  votes_received = [],
                  votes_rejected = [],
                  election_timeout = NewElectionTimeout
                  }.


-spec get_peers(raft_state()) -> list(raft_peer_id()).
get_peers(#raft{config=#raft_config{peers=Peers}}) ->
    [P || P <- Peers, P =/= node()].


% Timers
-spec start_heartbeat_timer(raft_state()) -> gen_statem:timeout_action().
start_heartbeat_timer(#raft{config=#raft_config{heart_beat_interval=H}}) ->
    {{timeout, heartbeat_timeout}, H, heartbeat_timeout}.

-spec reset_heartbeat_timer(raft_state()) -> gen_statem:timeout_action().
reset_heartbeat_timer(R) ->
    % gen_statem resets the timer if you start it again
    start_heartbeat_timer(R).

-spec stop_heartbeat_timer(raft_state()) -> gen_statem:timeout_action().
stop_heartbeat_timer(#raft{}) ->
    {{timeout, heartbeat_timeout}, infinity, heartbeat_timeout}.

-spec start_election_timer(raft_state()) -> gen_statem:timeout_action().
start_election_timer(#raft{election_timeout=ET}) ->
    {{timeout, election_timeout}, ET, election_timeout}.

-spec reset_election_timer(raft_state()) -> gen_statem:timeout_action().
reset_election_timer(R) ->
    % gen_statem resets the timer if you start it again
    start_election_timer(R).

-spec stop_election_timer(raft_state()) -> gen_statem:timeout_action().
stop_election_timer(#raft{}) ->
    {{timeout, election_timeout}, infinity, election_timeout}.



%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_statem:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_statem:call({?MODULE, Node}, {echo, Msg}).

