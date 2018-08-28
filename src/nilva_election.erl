% Implements the code for leader election and maintaining authority
%
% Note that all the functions in the module are pure.
% The nilva_raft_fsm still need to process the output and send them to its
% peers as necessary
-module(nilva_election).

-include("nilva_types.hrl").

-include_lib("eunit/include/eunit.hrl").


-export([get_election_timeout/1]).
-export([start_election/1, resend_request_votes/2, count_votes/2]).
-export([is_viable_leader/2, cast_vote/2, deny_vote/2]).
-export([send_heart_beats/1]).


-spec get_election_timeout(raft_config()) -> timeout().
get_election_timeout(#raft_config{election_timeout_min=EMin,
                     election_timeout_max=EMax})
    when EMin > 0, EMax > EMin ->
        nilva_helper:getUniformRandInt(EMin, EMax).


% Election related
-spec count_votes(reply_request_votes(), raft_state()) ->
    {boolean(), raft_state()}.
count_votes(#rrv{peer_id=PeerId, vote_granted=VoteGranted},
            Data=#raft{votes_received=VTrue, votes_rejected=VFalse}) ->
    % Assumption: We always have odd number of peers in config
    VotesNeeded = (length(Data#raft.config#raft_config.peers) div 2) + 1,
    _Ignore = lager:info("NumVotesNeeded:~p, VotesReceived:~p, VotesRejected:~p",
                          [VotesNeeded, VTrue, VFalse]),
    case VoteGranted of
        true ->
            case lists:member(PeerId, VTrue) of
                true ->
                    % Already processed, ignore
                    {false, Data};
                false ->
                    % NOTE: One vote from self & one vote from new peer
                    VotesReceived = length(Data#raft.votes_received) + 1 + 1,
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
    % Persist state
    nilva_replication_log:set_current_term(T + 1),
    nilva_replication_log:vote(node()),
    CT = nilva_replication_log:get_current_term(),
    VF = nilva_replication_log:voted_for(),

    % Update local data and create request votes request
    NewR = R#raft{
                current_term = CT,
                voted_for = VF,
                votes_received = [],
                votes_rejected = [],
                % Calculate new election timeout for next term
                election_timeout = get_election_timeout(R#raft.config)
                },
    RV = #rv{
             candidates_term = NewR#raft.current_term,
             candidate_id = NewR#raft.voted_for,
             last_log_idx = NewR#raft.last_log_idx,
             last_log_term = NewR#raft.last_log_term
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
            last_log_idx = R#raft.last_log_idx,
            last_log_term = R#raft.last_log_term
            },
    {RV, Unresponsive_peers}.


-spec is_viable_leader(raft_state(), request_votes()) -> {boolean(), atom()}.
is_viable_leader(Data = #raft{current_term=CurrentTerm}, RV = #rv{candidates_term=Term}) ->
    if
        Term < CurrentTerm ->
            {false, deny_vote_stale_term};
        Term > CurrentTerm ->
            PLastLogTerm = Data#raft.last_log_term,
            PLastLogIdx = Data#raft.last_log_idx,
            CLastLogTerm = RV#rv.last_log_term,
            CLastLogIdx = RV#rv.last_log_idx,
            case is_log_up_to_date(PLastLogTerm, PLastLogIdx, CLastLogTerm, CLastLogIdx) of
                true -> {true, cast_vote};
                false -> {false, deny_vote_log_not_up_to_date}
            end;
        Term =:= CurrentTerm ->
            % NOTE: We can only vote for the future terms except for
            %       when we receive a retry request votes from a
            %       candidate in current term that we already voted for
            % Grant vote if we had already done so
            case Data#raft.voted_for =:= RV#rv.candidate_id of
                true -> {true, cast_vote_idempotent_request};
                false -> {true, deny_vote_already_voted}
            end
    end.


-spec cast_vote(raft_state(), request_votes()) ->
    {reply_request_votes(), raft_peer_id(), raft_state()}.
cast_vote(Data, #rv{candidate_id=From, candidates_term=Term}) ->
    % Update to candidate's term
    nilva_replication_log:set_current_term(Term),
    nilva_replication_log:vote(From),
    NewData = Data#raft{voted_for=From, current_term=Term},
    RRV = #rrv{
               peers_current_term = Term,
               peer_id = node(),
               vote_granted = true
              },
    {RRV, From, NewData}.


-spec deny_vote(raft_state(), request_votes()) ->
    {reply_request_votes(), raft_peer_id()}.
deny_vote(#raft{current_term=CurrentTerm}, #rv{candidate_id=From}) ->
    RRV = #rrv{
               peers_current_term = CurrentTerm,
               peer_id = node(),
               vote_granted = false
              },
    {RRV, From}.


-spec send_heart_beats(raft_state()) ->
    append_entries().
send_heart_beats(R = #raft{current_term=Term}) ->
    AE = #ae {
             leaders_term = Term,
             leader_id = node(),
             prev_log_idx = R#raft.last_log_idx,
             prev_log_term = R#raft.last_log_term,
             entries = [],
             leaders_commit_idx = R#raft.commit_idx
             },
    AE.


-spec is_log_up_to_date(raft_term(), raft_log_idx(),
                        raft_term(), raft_log_idx()) ->
    boolean().
is_log_up_to_date(PLastLogTerm, PLastLogIdx, CLastLogTerm, CLastLogIdx) ->
    if
        PLastLogTerm > CLastLogTerm ->
            % Peer has log entries from higher term
            false;
        PLastLogTerm < CLastLogTerm ->
            % Candidate has log entries from higher term
            true;
        PLastLogTerm == CLastLogTerm ->
            % See which of them have the longest log
            PLastLogIdx =< CLastLogIdx
    end.


%% =========================================================================
%% Unit Tests
%% =========================================================================

get_election_timeout_test_() ->
    % 1. Election Timeout must lie between min & max
    % 2. Only those two in the config should affect it, i.e.,
    %    setting peers etc., to different values should not affect
    %    the election timeout as long as min & max are the same
    Config = #raft_config{peers = [],
                          heart_beat_interval = infinity,
                          client_request_timeout = infinity,
                          election_timeout_max=200,
                          election_timeout_min=100},
    InvalidConfig = #raft_config{
                        peers = [],
                        heart_beat_interval = infinity,
                        client_request_timeout = infinity,
                        election_timeout_max=200,
                        election_timeout_min=300},
    ET = get_election_timeout(Config),
    [?_assert((ET >= 100) and (ET =< 200)),
    ?_assertError(function_clause, get_election_timeout(InvalidConfig))].

% Make sure we are getting a series of random numbers
% Make this a property based test
