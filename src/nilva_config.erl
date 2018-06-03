% Helper module to handle cluster configuration changes
%
-module(nilva_config).

-export([read_config/1]).
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

    case VP and VT of
        true ->
            #raft_config
                {
                peers = proplists:get_value(peers, List),
                heart_beat_interval = proplists:get_value(heart_beat_interval, List),
                election_timeout_min = proplists:get_value(election_timeout_min, List),
                election_timeout_max = proplists:get_value(election_timeout_max, List),
                client_request_timeout = proplists:get_value(client_request_timeout, List)
                };
        false ->
            {error, "Invalid Config"}
    end.


% private
-spec validate_peers(any()) -> boolean().
validate_peers(Peers) when is_list(Peers) ->
    lists:all(fun(P) -> is_atom(P) end, Peers).

% private
-spec validate_timeouts(any(), any(), any(), any()) -> boolean().
validate_timeouts(H, Emin, Emax, CRT)
    when is_integer(H), is_integer(Emin), is_integer(Emax), is_integer(CRT) ->
        L = [H > 0, Emin > 0, Emax > 0, CRT > 0, Emax < Emin, H < Emin, CRT < Emin],
        lists:all(fun(X) -> X and true end, L).


