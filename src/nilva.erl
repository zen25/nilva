-module(nilva).

% For testing & debugging
-export([echo_log/1, echo_fsm/1, echo_fsm_all/2, echo_log_all/2]).

% Note: All the echo functions are synchronous
echo_log(Msg) ->
    nilva_log_server:echo(Msg).

echo_fsm(Msg) ->
    nilva_raft_fsm:echo(Msg).

echo_fsm_all(Msg, Nodes) ->
    [nilva_raft_fsm:echo(Msg, N) || N <- Nodes].

echo_log_all(Msg, Nodes) ->
    [nilva_log_server:echo(Msg, N) || N <- Nodes].
