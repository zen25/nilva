-module(raft_server).
-export([start/1
        ]).
-import(rand, []).

-type server_state() :: leader | candidate | follower.

% TODO: Make this part of config file
-define(HEART_BEAT_INTERVAL_IN_MS, 20).  % 20 ms



start(Args) ->
    spawn(server, init, [Args]).


init(Args) ->
    _ = Args,
    ElectionTimeOut = get_election_timeout(),
    CurrentServerState = follower,
    loop(CurrentServerState, ElectionTimeOut, ?HEART_BEAT_INTERVAL_IN_MS).

% TODO: How should I handle election timeout, hearbeats?
%       I think I need to spawn child processes to handle these concurrently
loop(follower, ElectionTimeOut, HeartBeat) ->
    NewState = waitForMsgsFromLeaderOrCandidate(),
    loop(NewState, ElectionTimeOut, HeartBeat);
loop(candidate, ElectionTimeOut, HeartBeat) ->
    NewState = waitForVotesFromPeers(),
    loop(NewState, ElectionTimeOut, HeartBeat);
loop(leader, ElectionTimeOut, HeartBeat) ->
    NewState = waitForClientRequests(),
    loop(NewState, ElectionTimeOut, HeartBeat).


% Return an election timeout based on heartbeat interval
% TODO: Base this on the psuedo random number generator with PID and ip address as seed
get_election_timeout() ->
    10 * ?HEART_BEAT_INTERVAL_IN_MS.


% If a leader sends a heartbeat before election timeout timer, reset the timer
waitForMsgsFromLeaderOrCandidate() ->
    follower.

% If majority quorum is reached, become the leader
% Otherwise, begin the next term
waitForVotesFromPeers() ->
    candidate.

% Send heartbeats to all the followers. When not enouch followers respond with ACKs,
% step down as the leader
waitForClientRequests() ->
    leader.
