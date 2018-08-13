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
follower(cast, AE=#ae{leaders_term=LT, entries=[no_op]}, Data = #raft{current_term=FT})
    when FT =:= LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, reset_election_timer]),
        RAE = #rae{peers_current_term = FT,
                   peer_id = node(),
                   success = true
                   },
        cast(AE#ae.leader_id, RAE),
        {keep_state_and_data, [reset_election_timer(Data)]};
% Append Entries request (valid heartbeat, leader with higher term)
follower(cast, AE=#ae{leaders_term=LT, entries=[no_op]}, Data = #raft{current_term=FT})
    when FT < LT ->
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, update_term_and_reset_election_timer]),
        NewData = update_term(Data, LT),
        RAE = #rae{peers_current_term = NewData#raft.current_term,
                   peer_id = node(),
                   success = true
                   },
        cast(AE#ae.leader_id, RAE),
        {keep_state, NewData, [reset_election_timer(NewData)]};
% Append Entries request (invalid)
follower(cast, AE=#ae{leaders_term=LT}, #raft{current_term=FT})
    when FT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, AE, reject_ae]),
        RAE = #rae{peers_current_term = FT,
                   peer_id = node(),
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
candidate(cast, AE=#ae{leaders_term=LT}, #raft{current_term=CT})
    when CT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, candidate, AE, reject_ae]),
        RAE = #rae{peers_current_term = CT,
                   peer_id = node(),
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
leader(cast, AE=#ae{leaders_term=LT}, #raft{current_term=CT})
    when CT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:debug("node:~p term:~p state:~p event:~p action:~p",
                            [node(), CT, leader, AE, reject_ae]),
        RAE = #rae{peers_current_term = CT,
                   peer_id = node(),
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
leader(cast, #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm =:= Term ->
        % TODO: Handle other things that are not no_op
        {keep_state_and_data, []};
% Impossible message
leader(cast, #rae{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm > Term ->
        Error = "Received a RAE from a future term. This should not even be possible",
        _Ignore = lager:error(Error),
        {stop, {error, Error}};
% Client Request
%
% Replicate the client request, once replicated on quorum of peers, apply to rsm
% and return the result to client. Notify the peers about commit index too
leader({call, From}, {client_request, Req}, Data) ->
    % NOTE: gen_statem does not have selective recieve. You can simulate
    %       it by postponing the events that you are not interested in and
    %       and using a buffer to store the interesting events.
    % TODO: Collect multiple client requests and handle them together
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
    %       not a client request.
    % AEs = make_append_entries(Data#raft.client_requests_buffer, Data),
    ok = lager:info("node:~p term:~p state:~p event:~p action:~p",
                    [node(), Data#raft.current_term, leader,
                    {client_request, Req}, handle_client_request]),
    AEs = make_append_entries([Req], Data),
    broadcast(get_peers(Data), AEs),
    {keep_state, NewData, []};
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
% TODO: Buffer requests
%       As a first pass, implemented only single element append entries
buffer_client_request(_From, {_CSN, get, _K} , Data) ->
    Data;
buffer_client_request(_From, {_CSN, put, _K, _V}, Data) ->
    Data;
buffer_client_request(_From, {_CSN, delete, _K}, Data) ->
    Data;
buffer_client_request(_From, {_CSN, cas, _K, _EV, _NV}, Data) ->
    Data.


-spec make_append_entries([client_request()], raft_state()) -> append_entries().
make_append_entries(ClientRequests, Data) ->
    #ae{
        leaders_term    = Data#raft.current_term,
        leader_id       = node(),
        prev_log_idx    = Data#raft.last_log_idx,
        prev_log_term   = Data#raft.last_log_term,
        entries         = ClientRequests,
        leaders_commit_idx = Data#raft.commit_idx
    }.



% TODO: Fix the dialyzer error "Created function has no local return"
-spec broadcast(list(raft_peer_id()), any()) -> no_return().
broadcast(Peers, Msg) ->
    lists:foreach(fun(Node) -> cast(Node, Msg) end, Peers).


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
    #raft{
        config = Config,
        votes_received = [],
        votes_rejected = [],
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

