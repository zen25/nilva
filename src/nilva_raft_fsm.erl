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
            % Dialyzer still complains about the lager code
            _Ignore = lager:error("Startup Error ~p", [Error]),
            {ok, follower, []};
        Config ->
            Data = init_raft_state(Config),
            % TODO: Dialyzer still throws warnings w.r.t lager
            _Ignore = lager:info("Started {node:~p} with {election_timeout:~p}",
                       [node(), Data#raft.election_timeout]),
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


% Follower state callback
%
% Invalid Config
follower(_, _, []) ->
    Error = "Server was not started properly. Please restart it with a valid config file",
    _Ignore = lager:error(Error),
    {stop, {error, Error}};
% State change (leader -> follower)
follower(enter, leader, Data) ->
    % Turn off the heart beat timer & start the election timer
    % The next event processed must be post-poned event
    TurnOffHeartBeat = {{timeout, heartbeat_timeout},
                        infinity,
                        heartbeat_timeout
                        },
    TurnOnElectionTimeout = {{timeout, election_timeout},
                             Data#raft.election_timeout, election_timeout},
    {keep_state_and_data, [TurnOffHeartBeat, TurnOnElectionTimeout]};
% State change (candidate -> follower)
follower(enter, candidate, Data) ->
    % Reset the election timer and process the post-poned event
    ResetElectionTimer = {{timeout, election_timeout},
                         Data#raft.election_timeout, election_timeout},
    {keep_state_and_data, [ResetElectionTimer]};
% Election timeout
follower({timeout, election_timeout}, election_timeout, Data) ->
    _Ignore = lager:info("{node:~p} starting {event:~p} in {term:~p}",
                         [node(), election, Data#raft.current_term + 1]),
    {next_state, candidate, Data};
% Append Entries request (valid)
follower(cast, AE = #ae{leaders_term=LT}, Data = #raft{current_term=FT})
    when FT =< LT ->
        % Process the data and reset election timer if it is from legitimate leader
        ResetElectionTimer = {{timeout, election_timeout},
                             Data#raft.election_timeout, election_timeout},
        {keep_state, Data, [ResetElectionTimer]};
% Append Entries request (in-valid)
follower(cast, AE = #ae{leaders_term=LT}, Data = #raft{current_term=FT})
    when FT > LT ->
        % Stale leader, reject the append entries
        {keep_state_and_data, []};
% Request Votes request (valid)
follower(cast, RV = #rv{candidates_term=CT}, Data = #raft{current_term=FT})
    when FT < CT ->
        % Grant the vote if already not given but do not reset election timer
        {keep_state, Data, []};
% Request Votes request (in-valid)
follower(cast, RV = #rv{candidates_term=CT}, Data = #raft{current_term=FT})
    when FT >= CT ->
        % Grant the vote if already not given but do not reset election timer
        {keep_state, Data, []};
% Stale Messages
% Heartbeats are not valid in follower state. Follower is passive
follower({timeout, heartbeat_timeout}, heartbeat_timeout, _) ->
    {keep_state_and_data, []};
% Ignoring replies to Append Entries
follower(cast, #rae{}, _) ->
    {keep_state_and_data, []};
% Ignoring replies to Request Votes
follower(cast, #rrv{}, _) ->
    {keep_state_and_data, []};
% TODO: Handle client request -> redirect to known leader if it exists
% Events not part of Raft
follower(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).



% Candidate state callback
%
% State Change (follower -> candidate)
candidate(enter, follower, Data) ->
    _Ignore = lager:info("Starting election"),
    % Increase the term, broadcast request votes, and reset election timer
    % TODO: Recalculate election timeout
    ResetElectionTimer = {{timeout, election_timeout},
                         Data#raft.election_timeout, election_timeout},
    {next_state, candidate, Data, [ResetElectionTimer]};
% Invalid State Change (leader x-> candidate)
candidate(enter, leader, _) ->
    Error = "Cannot become a candidate from a leader",
    _Ignore = lager:error(Error),
    {stop, {error, Error}};
% Election timeout
candidate({timeout, election_timeout}, election_timeout, Data) ->
    % Start a new election
    % TODO: Recalculate election timeout
    NewData = Data#raft{
                        current_term = Data#raft.current_term + 1,
                        election_timeout = get_election_timeout(Data#raft.config)
                        },
    _Ignore = lager:info("{node:~p} starting {event:~p} in {term:~p}",
                         [node(), election, NewData#raft.current_term]),
    ResetElectionTimer = {{timeout, election_timeout},
                         NewData#raft.election_timeout, election_timeout},
    {next_state, candidate, NewData, [ResetElectionTimer]};
% Request Votes reply
candidate(cast, #rrv{}, Data) ->
    % Collect the votes and see if you can become the leader
    {keep_state_and_data, []};
candidate(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).


% State Change (candidate -> leader)
leader(enter, candidate, Data) ->
    % Send out a no op to establish your authority,
    % stop the election timer and restart the heartbeat timer
    % Turn off the heart beat timer & start the election timer
    % The next event processed must be post-poned event
    TurnOnHeartBeat = {{timeout, heartbeat_timeout},
                        Data#raft.config#raft_config.heart_beat_interval,
                        heartbeat_timeout
                        },
    TurnOffElectionTimeout = {{timeout, election_timeout},
                             infinity, election_timeout},
    {keep_state_and_data, [TurnOnHeartBeat, TurnOffElectionTimeout]};
% Invalid State Change (follower x-> leader)
leader(enter, follower, Data) ->
     Error = "Cannot become a leader from a follower",
    _Ignore = lager:error(Error),
    {stop, {error, Error}};
leader({cast, From}, discoveredHigherTerm, Data) ->
    {next_state, follower, Data};
leader(EventType, EventContent, Data) ->
    % Handle the rest
    handle_event(EventType, EventContent, Data).

%% =========================================================================
%% Helpers (Private)
%% =========================================================================
% waitTillAllPeersHaveStarted(_Me, _Peers, _NumberOfHeartBeats) ->
%     % Send pings to all the peers and see if you get pong with given number of heartbeats
%     false.

handle_event({call, From}, {echo, Msg}, Data) ->
    {keep_state_and_data, {reply, From, {echo, ?MODULE, node(), Msg}}};
handle_event({call, From}, get_state, Data) ->
    {keep_state_and_data, {reply, From, Data}};
handle_event(_, _, Data) ->
    % Unknown event
    {keep_state_and_data, []}.


-spec broadcast_append_entries(list(), raft_state()) -> ok.
% TODO: Figure out the dialyzer error thrown by the above spec
broadcast_append_entries(Entries, Data) ->
    Peers = get_peers(Data),
    % Peers = nodes(),
    AE = #ae{},
    lists:foreach(fun(Node) -> cast(Node, AE) end, Peers).


-spec broadcast_request_votes(raft_state()) -> ok.
% TODO: Figure out the dialyzer error thrown by the above spec
broadcast_request_votes(Data) ->
    Peers = get_peers(Data),
    RV = #rv{},
    lists:foreach(fun(Node) -> cast(Node, RV) end, Peers).


-spec cast(node(), any()) -> no_return().
cast(Node, Msg) ->
    gen_statem:cast({?MODULE, Node}, Msg).

-spec init_raft_state(raft_config()) -> raft_state().
init_raft_state(Config) ->
    Peers = Config#raft_config.peers,
    #raft{
        config = Config,
        next_idx = [{P, 0} || P <- Peers],
        match_idx = [{P, 0} || P <- Peers],
        election_timeout = get_election_timeout(Config)
    }.


-spec get_election_timeout(raft_config()) -> timeout().
get_election_timeout(#raft_config{election_timeout_min=EMin,
                     election_timeout_max=EMax})
    when EMin > 0, EMax > EMin ->
        round(EMin + (EMax - EMin) * rand:uniform()).


-spec get_peers(raft_state()) -> list(raft_peer_id()).
get_peers(#raft{config=#raft_config{peers=Peers}}) ->
    Peers.


%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_statem:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_statem:call({?MODULE, Node}, {echo, Msg}).

