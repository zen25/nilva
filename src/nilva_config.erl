% Helper module to handle cluster configuration changes
%
-module(nilva_config).

-export([read_config/1,
        num_required_for_quorum/1
        ]).
% TODO: Split the header file. Having a single header seems like a bad idea
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
% NOTE: If we have 2f+1 servers, we need (f + 1) servers
%       to handle 'f' failures
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
-spec validate_timeouts(any(), any(), any(), any()) -> boolean().
validate_timeouts(H, Emin, Emax, CRT)
    when is_integer(H), is_integer(Emin), is_integer(Emax), is_integer(CRT) ->
        L = [H > 0, Emin > 0, Emax > 0, CRT > 0, Emin < Emax, H < Emin, CRT < Emin],
        lists:all(fun(X) -> X and true end, L).


