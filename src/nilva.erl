-module(nilva).

% For testing & debugging
-export([echo_log/1, echo_fsm/1]).

echo_log(Msg) ->
    nilva_log_server:echo(Msg).

echo_fsm(Msg) ->
    nilva_raft_fsm:echo(Msg).
