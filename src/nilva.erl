-module(nilva).

% For testing & debugging
-export([set_test_proxy_all/2]).
-export([echo_log/1, echo_fsm/1, echo_fsm_all/2, echo_log_all/2]).
-export([get_state/0, get_state/1]).

% Note: All the echo functions are synchronous
echo_log(Msg) ->
    nilva_log_server:echo(Msg).

echo_fsm(Msg) ->
    nilva_raft_fsm:echo(Msg).

-spec echo_fsm_all(string(), list()) -> list().
echo_fsm_all(Msg, Nodes) ->
    [nilva_raft_fsm:echo(Msg, N) || N <- Nodes].

echo_log_all(Msg, Nodes) ->
    [nilva_log_server:echo(Msg, N) || N <- Nodes].

-spec set_test_proxy_all(any(), list()) -> list().
set_test_proxy_all(Msg, Nodes) ->
    [nilva_test_proxy:set(Msg, N) || N <- Nodes].

% Returns the Raft FSM state of the current node
get_state() ->
    gen_statem:call(nilva_raft_fsm, get_state).

get_state(Node) ->
    gen_statem:call({nilva_raft_fsm, Node}, get_state).
