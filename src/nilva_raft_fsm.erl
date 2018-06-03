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
    % lager:start(),
    ConfigFile = "nilva_cluster.config",
    case nilva_config:read_config(ConfigFile) of
        {error, Error} ->
            % Dialyzer still complains about the lager code
            lager:error("Startup Error ~p", [Error]),
            {ok, follower, []};
        Config ->
            State = init_raft_state(Config),
            % TODO: Dialyzer still throws warnings w.r.t lager
            lager:info("Started node:~p with election_timeout:~p",
                       [node(), State#raft_state.election_timeout]),
            {ok, follower, State}
    end.

callback_mode() ->
    state_functions.

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


%% Events
%%
%% 1. AppendEntries
%% 2. RequestVotes
%% 3. Replies for AppendEntries (Ack/Nack)
%% 4. Replies for RequestVotes (Ack/Nack)
%% 5. TimeOuts (HeartBeats when leader, Election Timeouts when candidate/follower)
%% 6. Client Requests to RSM
%% 7. Config Management Commands
%% 8. Stop commands
%% 9. Test commands (like drop next N messages, drop 5% of messages etc.)
%%
%% Each of the above must be handled in every state
%%


% TODO: Too Many terms. Use a record to make the code concise
% follower({append_entries, LTerm, LId, PrevLogIdx, PrevLogTerm, Entries, LCommitIdx},
%          State) ->
%     % if
%     %     LTerm < FTerm ->
%     %         LId ! {reply_append_entries, FTerm, false};
%     %     true ->
%     %         Reply = nilva_raft_helper:handle_append_entries()
%     % end,
%     {next_state, follower, State};
follower({cast, From}, election_timeout, State) ->
    % Start an election and switch to candidate
    % NewState = startElection(State),
    % {next_state, candidate, NewState}.
    % broadcast_request_votes(State),
    {next_state, candidate, State};
follower(EventType, EventContent, State) ->
    % Handle the rest
    handle_event(EventType, EventContent, State).


% candidate(quorumAchieved, State) ->
%     IgnoreStaleMsg = nilva_raft_helper:CheckForStaleMessages(quorumAchieved),
%     if
%         IgnoreStaleMsg ->
%             {next_state, leader, State};
%         true ->
%             QuorumReached, NewState = nilva_raft_helper:waitForQuorum(State),
%             if
%                 QuorumReached ->
%                     % Establish your authority as leader and switch to leader state
%                     sendHeartBeatNoOp(NewState),
%                     {next_state, leader, NewState};
%                 true ->
%                     {next_state, candidate, NewState}
%             end
%     end;
% candidate({cast, From}, discoveredNewLeader, State) ->
%     {next_state, follower, State};
% candidate(discoveredHigherTerm, State) ->
%     {next_state, follower, State};
candidate({cast, From}, election_timeout, State) ->
    % Start a new election
    {next_state, candidate, State};
candidate(EventType, EventContent, State) ->
    % Handle the rest
    handle_event(EventType, EventContent, State).


% leader(handleClientRequest, State) ->
%     {next_state, leader, State};
leader({cast, From}, discoveredHigherTerm, State) ->
    {next_state, follower, State};
leader(EventType, EventContent, State) ->
    % Handle the rest
    handle_event(EventType, EventContent, State).

%% =========================================================================
%% Helpers (Private)
%% =========================================================================
% waitTillAllPeersHaveStarted(_Me, _Peers, _NumberOfHeartBeats) ->
%     % Send pings to all the peers and see if you get pong with given number of heartbeats
%     false.

handle_event({call, From}, {echo, Msg}, State) ->
    {keep_state_and_data, {reply, From, {echo, ?MODULE, node(), Msg}}};
handle_event({call, From}, get_state, State) ->
    {keep_state_and_data, {reply, From, State}};
handle_event(_, _, State) ->
    % Unknown event
    {keep_state_and_data, []}.


% -spec broadcast_append_entries(list(), raft_state()) -> ok.
% TODO: Figure out the dialyzer error thrown by the above spec
broadcast_append_entries(Entries, State) ->
    Peers = get_peers(State),
    % Peers = nodes(),
    AE = #ae{},
    lists:foreach(fun(Node) -> gen_statem:cast({?MODULE, Node}, AE) end, Peers),
    ok.


% -spec broadcast_request_votes(raft_state()) -> ok.
% TODO: Figure out the dialyzer error thrown by the above spec
broadcast_request_votes(State) ->
    Peers = get_peers(State),
    RV = #rv{},
    lists:foreach(fun(Node) -> cast(Node, RV) end, Peers).


-spec cast(node(), any()) -> no_return().
cast(Node, Msg) ->
    gen_statem:cast({?MODULE, Node}, Msg).

-spec init_raft_state(raft_config()) -> raft_state().
init_raft_state(Config) ->
    Peers = Config#raft_config.peers,
    #raft_state{
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
get_peers(#raft_state{config=#raft_config{peers=Peers}}) ->
    Peers.


%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_statem:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_statem:call({?MODULE, Node}, {echo, Msg}).

