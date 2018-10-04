% Helper module to handle cluster configuration changes
%
-module(nilva_config).
-include_lib("eunit/include/eunit.hrl").

-export([read_config/1,
        num_required_for_quorum/1
        ]).
-include("nilva_types.hrl").


-spec read_config(file:filename()) -> raft_config() | {error, term()}.
read_config(FileName) ->
    case file:consult(FileName) of
        {ok, PropList} ->
            case convertToConfigRecord(PropList) of
                {error, Error} -> {error, Error};
                ValidConfig -> ValidConfig
            end;
        {error, Error} -> {error, Error}
    end.


-spec num_required_for_quorum(raft_state()) -> pos_integer().
% NOTE: If we have 2f+1 servers, we can handle f failures
num_required_for_quorum(#raft{config=Config}) ->
    Peers = Config#raft_config.peers,
    floor(length(Peers)/2) + 1.



% private
-spec convertToConfigRecord(list(proplists:property())) ->
    raft_config() | {error, term()}.
convertToConfigRecord(List) ->
    Peers = proplists:get_value(peers, List),
    HeartBeatInterval = proplists:get_value(heart_beat_interval, List),
    ElectionTimeOutMin = proplists:get_value(election_timeout_min, List),
    ElectionTimeOutMax = proplists:get_value(election_timeout_max, List),
    ClientRequestTimeOut = proplists:get_value(client_request_timeout, List),

    % Validate the config data
    VP = validate_peers(Peers),
    VT = validate_timeouts(HeartBeatInterval, ElectionTimeOutMin, ElectionTimeOutMax,
                           ClientRequestTimeOut),

    case VP of
        true ->
            case VT of
                true ->
                    #raft_config
                        {
                        peers = Peers,
                        heart_beat_interval = HeartBeatInterval,
                        election_timeout_min = ElectionTimeOutMin,
                        election_timeout_max = ElectionTimeOutMax,
                        client_request_timeout = ClientRequestTimeOut
                        };
                false ->
                    {error, "Invalid config for timeouts"}
            end;
        false ->
            {error, "Invalid config for peers"}
    end.

% private
-spec validate_peers(any()) -> boolean().
validate_peers(Peers) when is_list(Peers) ->
    lists:all(fun(P) -> is_atom(P) end, Peers).

% private
-spec validate_timeouts(timeout(), timeout(), timeout(), timeout()) -> boolean().
validate_timeouts(H, Emin, Emax, CRT)
    when is_integer(H), is_integer(Emin), is_integer(Emax), is_integer(CRT) ->
        % TODO: Is there any relationship between CRT and election timeouts?
        %       Is CRT < EMin or CRT > EMax? Which makes sense, if any?
        %
        % TODO: Should we enforce Heartbeat << Emin?
        L = [H > 0, Emin > 0, Emax > 0, CRT > 0, Emin < Emax, H < Emin],
        lists:all(fun(X) -> X and true end, L).


%% =========================================================================
%% Unit Tests
%% =========================================================================

% TODO: Setup a test for read_config/1


num_required_for_quorum_test_() ->
    EvenPeers = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6'],
    OddPeers = EvenPeers ++ ['p7'],
    NQuorum = 4,
    EvenConfig = #raft_config{
        peers = EvenPeers,
        heart_beat_interval = 10,
        election_timeout_min = 100,
        election_timeout_max = 300,
        client_request_timeout = 5000
    },
    OddConfig = EvenConfig#raft_config{peers = OddPeers},
    RandET = 167,
    EvenRaft = #raft{
        config = EvenConfig,
        votes_received = [],
        votes_rejected = [],
        next_idx = [],
        match_idx = [],
        election_timeout = RandET
    },
    OddRaft = EvenRaft#raft{config = OddConfig},
    % Check quorum calculation when cluster has even peers
    [?_assertEqual(NQuorum, num_required_for_quorum(EvenRaft)),
    % Check quorum calculation when cluster has odd peers
    ?_assertEqual(NQuorum, num_required_for_quorum(OddRaft))].


convertToConfigRecord_test_() ->
    ValidProps = [
        {peers, ['p1', 'p2', 'p3']},
        {heart_beat_interval, 10},
        {election_timeout_min, 500},
        {election_timeout_max, 1000},
        {client_request_timeout, 250}
    ],
    InvalidPropsTimeouts = [
        {peers, ['p1', 'p2', 'p3']},
        {heart_beat_interval, 10000000000},
        {election_timeout_min, 500},
        {election_timeout_max, 1000},
        {client_request_timeout, 250}
    ],
    InvalidPropsPeers = [
        {peers, ["p1", "p2", "p3"]},
        {heart_beat_interval, 10},
        {election_timeout_min, 500},
        {election_timeout_max, 1000},
        {client_request_timeout, 250}
    ],
    [?_assert(is_record(convertToConfigRecord(ValidProps), raft_config)),
    ?_assertNot(is_record(convertToConfigRecord(InvalidPropsPeers), raft_config)),
    ?_assertNot(is_record(convertToConfigRecord(InvalidPropsTimeouts), raft_config))].


validate_peers_test_() ->
    ValidPeers = ['p1', 'p2', 'p3'],
    InvalidPeers = ['p1', "p2", "p3"],
    % InvalidPeers2 = {'p1', 'p2', 'p3'},
    % Check if all the peers are atoms in a list
    [?_assert(validate_peers(ValidPeers)),
    ?_assertNot(validate_peers(InvalidPeers))].
    % TODO: Dialyzer is not accepting this case
    % ?_assertError(function_clause, validate_peers(InvalidPeers2))].


validate_timeouts_test_() ->
    % All timeouts are valid
    {H, EMin, EMax, CRT} = {10, 100, 300, 3000},
    % Heartbeat is not valid
    InvalidH = 190,
    % EMin > EMax
    {InvalidEMin, InvalidEMax} = {1000, 300},
    [?_assert(validate_timeouts(H, EMin, EMax, CRT)),
    ?_assertNot(validate_timeouts(InvalidH, EMin, EMax, CRT)),
    ?_assertNot(validate_timeouts(H, InvalidEMin, InvalidEMax, CRT))].
