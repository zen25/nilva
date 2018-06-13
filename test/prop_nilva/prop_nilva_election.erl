-module(prop_nilva_election).
-include_lib("proper/include/proper.hrl").
-include("nilva_types.hrl").

% ET - Election Timeout
prop_get_election_timeout() ->
    ?FORALL(
        C,
        {raft_config, list(any()), timeout(), non_neg_integer(), non_neg_integer(), timeout()},
        ?IMPLIES(filter_invalid_ET_config(C), valid_ET(C))).

filter_invalid_ET_config(C) ->
    (C#raft_config.election_timeout_min > 0) and
    (C#raft_config.election_timeout_min < C#raft_config.election_timeout_max).


valid_ET(C) ->
    ET = nilva_election:get_election_timeout(C),
    (ET >= C#raft_config.election_timeout_min) and
    (ET =< C#raft_config.election_timeout_max).


