% Helper module to handle cluster configuration changes
%
-module(nilva_config).

-export([read_config/1]).
% TODO: Split the header file. Having a single header seems like a bad idea
-include("nilva_types.hrl").


-spec read_config(file:filename()) -> raft_config() | {error, term()}.
read_config(FileName) ->
    case file:consult(FileName) of
        {ok, PropList} -> convertToConfigRecord(PropList);
        {error, Error} -> {error, Error}
    end.

% private
-spec convertToConfigRecord(list(proplists:property())) -> raft_config().
convertToConfigRecord(List) ->
    #raft_config{
                peers = proplists:get_value(peers, List),
                heart_beat_interval = proplists:get_value(heart_beat_interval, List),
                election_timeout_min = proplists:get_value(election_timeout_min, List),
                election_timeout_max = proplists:get_value(election_timeout_max, List),
                client_request_timeout = proplists:get_value(client_request_timeout, List),

                % Need to be calculated for each new term
                election_timeout = infinity,
                old_config = undefined
                }.

