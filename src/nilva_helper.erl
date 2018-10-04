% Contains any functions not related to raft or kv store
%
-module(nilva_helper).

-include_lib("eunit/include/eunit.hrl").

-export([getUniformRand/2, getUniformRandInt/2]).
-export([spawn_and_get_result/1]).


%% =========================================================================
%% Public Functions
%% =========================================================================

-spec getUniformRand(number(), number()) -> number().
getUniformRand(Min, Max) when Min < Max ->
    Min + (Max - Min) * rand:uniform().


-spec getUniformRandInt(integer(), integer()) -> integer().
getUniformRandInt(Min, Max) ->
    round(getUniformRand(Min, Max)).


-spec spawn_and_get_result(function()) -> any().
spawn_and_get_result(F) ->
    Self = self(),
    Pid = spawn(fun() -> X = F(), Self ! {self(), X} end),
    Return = receive
                {Pid, Result} ->
                    Result
             end,
    Return.


%% =========================================================================
%% Unit Tests
%% =========================================================================

getUniformRand_test_() ->
    % Valid min & max
    {Min, Max} = {95.8, 209},
    X = getUniformRand(Min, Max),
    % Invalid min & max
    {Min2, Max2} = {209, 95.8},
    % Check if a random number if generated with valid min & max
    [?_assert((X >= Min) and (X =< Max)),
    % Check if an error is thrown when min > max
    ?_assertException(error, function_clause, getUniformRand(Min2, Max2))].

% Also tests spawn_and_get_result
getUniformRand_randomness_test_() ->
    {Min, Max} = {20395, 58649.7},
    F = fun() -> [nilva_helper:getUniformRand(Min, Max) || _ <- lists:seq(1, 10)] end,
    Xs = F(),
    Xs_set = sets:from_list(Xs),
    Xs_different_process = spawn_and_get_result(F),
    % Check if sequence of random numbers generated are different from each other
    [?_assertEqual(length(Xs), sets:size(Xs_set)),
    % Test whether the random number sequences generated in separate processes are
    % different from each other
    ?_assertNotEqual(Xs, Xs_different_process)].

getUniformRandInt_test_() ->
    {Min, Max} = {1890, 2018},
    I = getUniformRandInt(Min, Max),
    [?_assert(is_integer(I)),
    ?_assert((I >= Min) and (I =< Max))].

