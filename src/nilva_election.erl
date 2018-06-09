% Implements the code for leader election and maintaining authority
%
% Note that all the functions in the module are pure.
% The nilva_raft_fsm still need to process the output and send them to its
% peers as necessary
-module(nilva_election).

-include("nilva_types.hrl").

-export([get_election_timeout/1]).
-export([start_election/1, resend_request_votes/2, count_votes/2]).
-export([cast_vote/2, deny_vote/2]).
-export([send_heart_beats/1]).


-spec get_election_timeout(raft_config()) -> timeout().
get_election_timeout(#raft_config{election_timeout_min=EMin,
                     election_timeout_max=EMax})
    when EMin > 0, EMax > EMin ->
        nilva_helper:getUniformRandInt(EMax, EMax).


% Election related
% TODO: We ignored the term for which the vote was granted. This is the most likely cause
%       of the bug
-spec count_votes(reply_request_votes(), raft_state()) ->
    {boolean(), raft_state()}.
count_votes(#rrv{peer_id=PeerId, vote_granted=VoteGranted},
            Data=#raft{votes_received=VTrue, votes_rejected=VFalse}) ->
    % Assumption: We always have odd number of peers in config
    VotesNeeded = (length(Data#raft.config#raft_config.peers) div 2) + 1,
    case VoteGranted of
        true ->
            case lists:member(PeerId, VTrue) of
                true ->
                    % Already processed, ignore
                    {false, Data};
                false ->
                    VotesReceived = length(Data#raft.votes_received) + 1,
                    if
                        VotesReceived >= VotesNeeded ->
                            {true, Data#raft{votes_received = VTrue ++ [PeerId]}};
                        true ->
                            % Quorum not reached
                            {false, Data#raft{votes_received = VTrue ++ [PeerId]}}
                    end
            end;
        false ->
            case lists:member(PeerId, VFalse) of
                true ->
                    % Already processed, ignore
                    {false, Data};
                false ->
                    {false, Data#raft{votes_rejected = VFalse ++ [PeerId]}}
            end
    end.


% Election related
-spec start_election(raft_state()) ->
    {request_votes(), raft_state()}.
start_election(R = #raft{current_term=T}) ->
    % TODO: Persist the two below
    NewR = R#raft{
                current_term = T + 1,
                voted_for = node(),
                % Calculate new election timeout for next term
                election_timeout = get_election_timeout(R#raft.config)
                },
    RV = #rv{
             candidates_term = NewR#raft.current_term,
             candidate_id = NewR#raft.voted_for,
             last_log_idx = get_previous_log_idx(),
             last_log_term = get_previous_log_term()
            },
    {RV, NewR}.


% Election related
-spec resend_request_votes(raft_state(), list(raft_peer_id())) ->
    {request_votes(), list(raft_peer_id())}.
resend_request_votes(R = #raft{votes_received=PTrue, votes_rejected=PFalse}, AllPeers) ->
    Unresponsive_peers = AllPeers -- (PTrue ++ PFalse),
    RV = #rv{
            candidates_term = R#raft.current_term,
            candidate_id = R#raft.voted_for,
            last_log_idx = get_previous_log_idx(),
            last_log_term = get_previous_log_term()
            },
    {RV, Unresponsive_peers}.


-spec cast_vote(raft_state(), request_votes()) ->
    {reply_request_votes(), raft_peer_id(), raft_state()}.
cast_vote(Data, #rv{candidate_id=From, candidates_term=Term}) ->
    % Update to candidate's term
    % TODO: Persist
    NewData = Data#raft{voted_for=From, current_term=Term},
    RRV = #rrv{
               peers_current_term = Term,
               peer_id = node(),
               vote_granted = true
              },
    {RRV, From, NewData}.


-spec deny_vote(raft_state(), request_votes()) ->
    {reply_request_votes(), raft_peer_id()}.
deny_vote(#raft{current_term=CT}, #rv{candidate_id=From}) ->
    RRV = #rrv{
               peers_current_term = CT,
               peer_id = node(),
               vote_granted = false
              },
    {RRV, From}.


-spec send_heart_beats(raft_state()) ->
    append_entries().
send_heart_beats(#raft{current_term=Term}) ->
    AE = #ae {
             leaders_term = Term,
             leader_id = node(),
             prev_log_idx = get_previous_log_idx(),
             prev_log_term = get_previous_log_term(),
             entries = [no_op],
             leaders_commit_idx = get_commit_idx()
             },
    AE.

% TODO
get_previous_log_term() -> 0.

% TODO
get_previous_log_idx() -> 0.

% TODO
get_commit_idx() -> 0.
