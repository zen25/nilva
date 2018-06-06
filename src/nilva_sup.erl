-module(nilva_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupFlags = {one_for_all, 0, 10},
    Children = [child(nilva_raft_fsm), child(nilva_log_server)],
    {ok, {SupFlags, Children}}.

child(Module) ->
    {Module, {Module, start_link, []}, permanent, 10000, worker, [Module]}.
