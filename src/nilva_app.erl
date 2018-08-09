-module(nilva_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    nilva_rest:init_cowboy(),
    nilva_sup:start_link().

stop(_State) ->
    ok.

