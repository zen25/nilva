-module(raft_server).
-export([start/1
        ]).
-import(rand, []).

-type server_state() :: leader | candidate | follower.
-type msg_types() :: append_entry | request_vote.

% TODO: Make this part of config file
-define(HEART_BEAT_INTERVAL_IN_MS, 20).  % 20 ms



start(Args) ->
    spawn(server, init, [Args]).


init(Args) ->
    _ = Args,
    ElectionTimeOut = get_election_timeout(),
    CurrentServerState = follower,
    Term = 1,
    loop(CurrentServerState, Term, ElectionTimeOut, ?HEART_BEAT_INTERVAL_IN_MS).

% TODO: How should I handle election timeout, hearbeats?
%       I think I need to spawn child processes to handle these concurrently
loop(follower, Term, ElectionTimeOut, HeartBeat) ->
    {NewState, NewTerm} = waitForMsgsFromLeaderOrCandidate(Term),
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
waitForMsgsFromLeaderOrCandidate(Term) ->
    {follower, Term}.

% If majority quorum is reached, become the leader
% Otherwise, begin the next term
waitForVotesFromPeers(Term) ->
    {candidate, Term}.

% Send heartbeats to all the followers. When not enouch followers respond with ACKs,
% step down as the leader
waitForClientRequests(Term) ->
    {leader, Term}.
