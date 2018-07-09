-module(nilva_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-ifndef(TEST).
init(_Args) ->
    SupFlags = {one_for_all, 0, 10},
    Children = [child(nilva_raft_fsm)],
    {ok, {SupFlags, Children}}.
-else.
init(_Args) ->
    SupFlags = {one_for_all, 0, 10},
    Children = [child(nilva_raft_fsm),
                % Start the proxy server too if testing
                child(nilva_test_proxy)],
    {ok, {SupFlags, Children}}.
-endif.

child(Module) ->
    {Module, {Module, start_link, []}, permanent, 10000, worker, [Module]}.
