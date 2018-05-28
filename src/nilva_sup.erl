-module(nilva_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    ChildSpecList = [child(nilva_raft_fsm), child(nilva_log_server)],
    {ok, {one_for_all, 2, 3600}, ChildSpecList}.

child(Module) ->
    {Module, {Module, start_link, []}, permanent, 2000, worker, [Module]}.
