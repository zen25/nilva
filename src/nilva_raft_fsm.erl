% Implements the Raft Consensus algorithm
%
-module(nilva_raft_fsm).

-behaviour(gen_statem).
-include("nilva_types.hrl").

%% Cluster & Peer management
-export([start/2, start_link/0, stop/1, join/1]).

%% Replicated State Machine (RSM) commands
%% TODO: Separate the RSM from Raft consensus modules
-export([get/1, put/1, delete/1]).

% gen_statem callbacks & state
-export([init/1,
        callback_mode/0,
        terminate/3,
        handle_sync_event/4]).
-export([leader/3, follower/3, candidate/3]).

% For testing & debugging
-export([echo/1, echo/2]).

%% =========================================================================
%% Public API for CLient to interact with RSM
%% =========================================================================

% TODO: Is this a good idea, we can still get the errors if we call using put
-spec get(client_request()) -> response_to_client().
get({CSN, get, {key, K}}) ->
    % TODO:
    %       Convert to and fro from (CSN, string()) to internal types
    {CSN, {value, K}}.

-spec put(client_request()) -> response_to_client().
put({CSN, put, {key, _K}, {value, _V}}) ->
    % TODO
    {CSN, ok}.

-spec delete(client_request()) -> response_to_client().
delete({CSN, delete, {key, _K}}) ->
    % TODO
    {CSN, ok}.

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
            _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                                 [node(), -1, init, successfully_read_config, start]),
            _Ignore2 = lager:debug("election_timeout:~p", [Data#raft.election_timeout]),
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
% TODO: Move this to a join function
follower(enter, follower, Data) ->
    Peers = get_peers(Data),
    % TODO: Handle this properly, we can keep the cookie in the config file
    %       Instead of setting cookie for all nodes, ping them
    %       If the cookie is the same, the cluster should be connected
    Cookie = 'abcdefgh',
    lists:foreach(fun(Node) -> erlang:set_cookie(Node, Cookie) end, Peers),
    {keep_state_and_data, []};
% State change (candidate -> follower)
follower(enter, candidate, Data) ->
    % Reset the election timer and process the post-poned event
    % TODO: Figure out the runtime error when setting record value to undefined
    % NewData = Data#raft{voted_for=undefined},
    NewData = Data#raft{voted_for = undefined, votes_received = [], votes_rejected = []},
    _Ignore = lager:debug("Successfully reset voted_for"),
    {keep_state, NewData,
        [stop_heartbeat_timer(NewData), start_election_timer(NewData)]};
% State change (leader -> follower)
follower(enter, leader, Data) ->
    % Turn off the heart beat timer & start the election timer
    % The next event processed must be post-poned event
    {keep_state_and_data,
        [stop_heartbeat_timer(Data), start_election_timer(Data)]};
% Election timeout
follower({timeout, election_timeout}, election_timeout, Data) ->
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), -1, follower, election_timeout, nominate_self]),
    {next_state, candidate, Data};
% Append Entries request (valid)
follower(cast, #ae{leaders_term=LT}, Data = #raft{current_term=FT})
    when FT =< LT ->
        % Process the data and reset election timer if it is from legitimate leader
        NewData = Data#raft{current_term = LT},
        _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, received_valid_ae, process_ae]),
        _Ignore2 = lager:debug("Upgrading from term:~p to term:~p",
                               [FT, LT]),
        {keep_state, NewData, [reset_election_timer(NewData)]};
% Append Entries request (invalid)
follower(cast, #ae{leaders_term=LT}, #raft{current_term=FT})
    when FT > LT ->
        % Stale leader, reject the append entries
        _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                            [node(), FT, follower, received_invalid_ae, reject_ae]),
        {keep_state_and_data, []};
% Request Votes request (invalid)
follower(cast, RV = #rv{candidates_term=CT}, Data = #raft{current_term=FT})
    when FT > CT ->
        % Deny the vote
        _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
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
                _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), FT, follower, received_valid_rv, Reason]),
                {keep_state, NewData, [reset_election_timer(NewData)]};
            false ->
                {RRV, Candidate} = nilva_election:deny_vote(Data, RV),
                cast(Candidate, RRV),
                _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                                    [node(), FT, follower, received_valid_rv, Reason]),
                {keep_state_and_data, [reset_election_timer(Data)]}
        end;
% Stale Messages
% Heartbeats are not valid in follower state. Follower is passive
follower({timeout, heartbeat_timeout}, heartbeat_timeout, #raft{current_term=FT}) ->
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, stale_heartbeat_timeout, ignore]),
    {keep_state_and_data, []};
% Ignoring replies to Append Entries
follower(cast, #rae{}, #raft{current_term=FT}) ->
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, stale_rae, ignore]),
    {keep_state_and_data, []};
% Ignoring replies to Request Votes
follower(cast, #rrv{}, #raft{current_term=FT}) ->
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                        [node(), FT, follower, stale_rrv, ignore]),
    {keep_state_and_data, []};
% TODO: Handle client request -> redirect to known leader if it exists
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
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
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
    % _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
    %                     [node(), Data#raft.current_term, candidate,
    %                     heartbeat_timeout, resend_rv]),
    broadcast(Unresponsive_peers, RV),
    {keep_state_and_data, [start_heartbeat_timer(Data)]};
% Request Votes request (invalid)
candidate(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm >= CT ->
        % Either stale request or from the same term
        % Deny Vote
        _Ignore = lager:info("{node:~p} {event:~p} {from_node:~p}",
                            [node(), deny_vote_already_voted, RV#rv.candidate_id]),
        {RRV, Peer} = nilva_election:deny_vote(Data, RV),
        cast(Peer, RRV),
        {keep_state_and_data, []};
% Request Voes request (valid)
% TODO: SHould the request votes be synchronous?
candidate(cast, RV=#rv{candidates_term=CT}, Data=#raft{current_term=MyTerm})
    when MyTerm < CT ->
        % There is a candidate with higher term
        % Step down & re-process this event
        _Ignore =lager:info("{node:~p} {event:~p}", [node(), stepping_down_as_candidate]),
        ProcessEventAsFollower = {next_event, cast, RV},
        {next_state, follower, Data, [ProcessEventAsFollower]};
candidate(cast, RRV=#rrv{peers_current_term = PTerm}, Data = #raft{current_term = Term})
    when PTerm =:= Term ->
        % Collect the votes and see if you can become the leader
        {WonElection, NewData} = nilva_election:count_votes(RRV, Data),
        _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, candidate,
                            RRV, count_votes]),
        case WonElection of
            true ->
                _Ignore =lager:info("{node:~p} {event:~p} {term:~p}",
                                    [node(), elected_leader, Term]),
                {next_state, leader, NewData};
            false ->
                _Ignore =lager:info("{node:~p} {event:~p} {term:~p}",
                                    [node(), no_majority, Term]),
                {keep_state, NewData}
        end;
candidate(cast, #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm =< Term ->
        _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                            [node(), Term, candidate,
                            received_stale_rrv, ignore]),
        {keep_state_and_data, []};
candidate(cast, #rrv{peers_current_term = PTerm}, #raft{current_term = Term})
    when PTerm > Term ->
        Error = "Received a RRV from a future term. This should not even be possible",
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
    _Ignore = lager:info("{node:~p} {event:~p} {term:~p}",
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
    _Ignore = lager:info("{node:~p} {event:~p} {term:~p}",
                         [node(), sending_heart_beats, Data#raft.current_term]),
    AE = nilva_election:send_heart_beats(Data),
    broadcast(get_peers(Data), AE),
    {keep_state_and_data, [reset_heartbeat_timer(Data)]};
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
    _Ignore = lager:info("node:~p term:~p state:~p event:~p action:~p",
                         [node(), T, any, received_unknown_message, ignoring_unknown_message]),
    {keep_state_and_data, []}.


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
    Peers = Config#raft_config.peers,
    #raft{
        config = Config,
        votes_received = [],
        votes_rejected = [],
        next_idx = [{P, 0} || P <- Peers],
        match_idx = [{P, 0} || P <- Peers],
        election_timeout = nilva_election:get_election_timeout(Config)
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

