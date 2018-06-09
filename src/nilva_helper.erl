-module(nilva_helper).

-export([getUniformRand/2, getUniformRandInt/2]).


-spec getUniformRand(number(), number()) -> number().
getUniformRand(Min, Max) ->
    Min + (Max - Min) * rand:uniform().


-spec getUniformRandInt(integer(), integer()) -> integer().
getUniformRandInt(Min, Max) ->
    round(getUniformRand(Min, Max)).
