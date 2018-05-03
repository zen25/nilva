-module(raft_server).
-export([start/1
        ]).
-import(rand, []).

-type server_state() :: leader | candidate | follower.
-type raft_msg() :: append_entry | request_vote.

% NOTE: `Term` must be included along with response when responding to both
%        `append_entry` and `request_vote` msgs. This is needed as we have no way of
%        knowing which msg the peer responded to if there are more than one input
%        messages. Erlang does guarantee in order delivery in case of a single process.
-type response_to_raft_msg() :: ack | nack.

% TODO: Make this part of config file
-define(HEART_BEAT_INTERVAL_IN_MS, 20).  % 20 ms



start(Args) ->
    spawn(server, init, [Args]).


% TODO: We need to keep track of peers, current term, last known leaders term etc.
init(Args) ->
    _ = Args,
    ElectionTimeOut = get_election_timeout(),
    CurrentServerState = follower,
    Term = 1,
    loop(CurrentServerState, Term, ElectionTimeOut, ?HEART_BEAT_INTERVAL_IN_MS).

% Process Skeleton
%
% All of the child processes need to be under supervision tree
%
% ^
% + Main Raft Server
%       |
%       +- ElectionTimeout Timer (start, reset, alert) x 1
%       |
%       +- HandleIncomingMessages x #Peers
%       |
%       +- SendOutgoingMessages x #Peers

% TODO: How should I handle election timeout, hearbeats?
%       I think I need to spawn child processes to handle these concurrently
loop(follower, Term, ElectionTimeOut, HeartBeat) ->
    {NewState, NewTerm} = waitForMsgsFromLeaderOrCandidate(Term, ElectionTimeOut),
    loop(NewState, NewTerm, ElectionTimeOut, HeartBeat);
loop(candidate, Term, ElectionTimeOut, HeartBeat) ->
    {NewState, NewTerm} = waitForVotesFromPeers(Term),
    loop(NewState, NewTerm, ElectionTimeOut, HeartBeat);
loop(leader, Term, ElectionTimeOut, HeartBeat) ->
    {NewState, NewTerm} = waitForClientRequests(Term),
    loop(NewState, NewTerm, ElectionTimeOut, HeartBeat).


% Return an election timeout based on heartbeat interval
% TODO: Base this on the psuedo random number generator with PID and ip address as seed
get_election_timeout() ->
    10 * ?HEART_BEAT_INTERVAL_IN_MS.


% If a leader sends a heartbeat before election timeout timer, reset the timer
waitForMsgsFromLeaderOrCandidate(Term, ElectionTimeOut) ->
    receive
        % Hmm, this is wrong. ElectionTimeout is independent of wheather you are a
        % candidate/follower. When a heartbeat is acknowledged, the timeout should reset
        {From, request_vote, CandidateTerm} when CandidateTerm > Term ->
            % vote for the first candidate who requested to be the leader,
            % reject others
            From ! {self(), ack, Term};
        {From, append_entry, LeaderTerm} when LeaderTerm >= Term ->
            % If the leader sends a heartbeat, acknowledge it
            From ! {self(), ack, Term};
        {From, _, _} ->
            From ! {self(), nack, Term}
    after ElectionTimeOut ->
        {candidate, Term + 1}
    end.

% If majority quorum is reached, become the leader
% Otherwise, begin the next term
waitForVotesFromPeers(Term) ->
    {candidate, Term}.

% Send heartbeats to all the followers. When not enough followers respond with ACKs,
% step down as the leader
%
% Child Processes:
%     - 1 to handle election timeouts
%     - 1 to handle incoming messages
%     - 1 to handle outgoing messages
waitForClientRequests(Term) ->
    {leader, Term}.
