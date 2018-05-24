-module(raft_fsm).
-behaviour(gen_fsm).

%% Cluster & Peer management
-export([start/2, stop/1, join/1]).

%% Replicated State Machine (RSM) commands
%% TODO: Separate the RSM from Raft consensus modules
-export([get/1, put/2, delete/1]).

% gen_fsm callbacks & state
-export([init/4, terminate/3, handle_sync_event/4]).
-export([leader/2, follower/2, candidate/2]).


%% TODO: Extract these into a config file at a later point
-define(HEART_BEAT_TIMEOUT, 25).
-define(CLIENT_RESPONSE_TIMEOUT, 5000).     % Default
-define(MAXIMUM_TIME_FOR_BOOTSTRAPPING, 60000).     % Wait for a minute for bootstrapping

%% =========================================================================
%% Public API for CLient to interact with RSM
%% =========================================================================
get(K) ->
    % TODO
    K.

put(_K, _V) ->
    % TODO
    ok.

delete(_K) ->
    % TODO
    ok.

%% =========================================================================
%% Raft Peer/Cluster API
%% =========================================================================
start(PeerName, {Peers, ElectionTimeOut, CheckSuccessfulStartup}) ->
    % Assuming that Peer names are unique in the global erlang cluster
    gen_fsm:start_link({global, PeerName}, ?MODULE,
                       [PeerName, Peers, ElectionTimeOut, CheckSuccessfulStartup], []).

stop(PeerName) ->
    gen_fsm:sync_send_all_state_event(PeerName, stop).

join(_Peer) ->
    % Send a ping request to join the cluster
    % Do we need this? Aren't we using the erlangs distributed cluster management
    % capabilities?
    %
    ok.


%% =========================================================================
%% CALLBACKS (gen_fsm)
%% =========================================================================
init(_Me, _Peers, _ElectionTimeOut, _CheckSuccessfulStartup) ->
    {ok, follower, []}.

handle_sync_event(stop, _From, _State, LoopData) ->
    {stop, normal, LoopData}.


terminate(_Reason, _StateName, _LoopData) ->
    ok.


%% =========================================================================
%% STATES
%% =========================================================================

% TODO: For now, the events are named explictly. This is not possible in the
%       actual implementation.
%       We can have the handle_event handle all the responses for RequestVotes
%       and AppendEntries from the Peers and send a message to self() if the
%       corresponding event arises. But the problem is messages are handled in
%       order of their receival in the mailbox. So we might have processed some
%       responses fron peers we should not have processed before we make the state
%       state transistion. This will lead to bugs
%
%       So, the states themselves should handle the response for RequestVotes and
%       AppendEntries rpcs from the Peers.
%       They should also handle the requests from the various clients

follower(boot, State) ->
    {next_state, follower, State};
follower(election_timeout, State) ->
    % Start an election and switch to candidate
    {next_state, candidate, State}.


candidate(waitForQuorum, State) ->
    {next_state, candidate, State};
candidate(quorumAchieved, State) ->
    % Send out an empty append entries to solidify the position
    {next_state, leader, State};
candidate(discoveredNewLeader, State) ->
    {next_state, follower, State};
candidate(discoveredHigherTerm, State) ->
    {next_state, follower, State};
candidate(election_timeout, State) ->
    % Start a new election
    {next_state, candidate, State}.


leader(handleClientRequest, State) ->
    {next_state, leader, State};
leader(discoveredHigherTerm, State) ->
    {next_state, follower, State}.

%% =========================================================================
%% Helpers (Private)
%% =========================================================================
waitTillAllPeersHaveStarted(_Me, _Peers, _NumberOfHeartBeats) ->
    % Send pings to all the peers and see if you get pong with given number of heartbeats
    false.
