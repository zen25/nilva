-module(nilva_raft_helper).

% Leadership change related
% TODO: Implement these
-export([startElection/1, castVote/2, waitForQuorum/2,
        stepDownAsLeader/1, stepDownAsCandidate/1]).
% NOTE: To disable a timer, simply set its timeout to infinity
-export([startElectionTimer/0, resetElectionTimer/1,
        startHeartBeatTimer/0, resetHeartBeatTimer/1]).


% Log Replication related
-export([appendLogEntries/2, applyLogEntries/1]).
-export([checkIfCommandAlreadyApplied/1]).

% Other
%
% Any message can be stale, even the timeouts. For example,
% we might recieve an heartbeat timeout after we have stepped
% down as leader
-export([staleMessage/3]).



