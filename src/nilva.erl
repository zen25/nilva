-module(nilva).

% For testing & debugging
-export([set_test_proxy_all/2]).
-export([echo_fsm/1, echo_fsm_all/2]).
-export([get_state/0, get_state/1]).

% Note: All the echo functions are synchronous
echo_fsm(Msg) ->
    nilva_raft_fsm:echo(Msg).

-spec echo_fsm_all(string(), list()) -> list().
echo_fsm_all(Msg, Nodes) ->
    [nilva_raft_fsm:echo(Msg, N) || N <- Nodes].

-spec set_test_proxy_all(any(), list()) -> list().
set_test_proxy_all(Msg, Nodes) ->
    [nilva_test_proxy:set(Msg, N) || N <- Nodes].

% Returns the Raft FSM state of the current node
get_state() ->
    gen_statem:call(nilva_raft_fsm, get_state).

get_state(Node) ->
    gen_statem:call({nilva_raft_fsm, Node}, get_state).


-spec leader() -> node().
leader() ->
    node().


get(Key) ->
    % TODO
    Key.


set(Key, Value) ->
    % TODO
    ok.


del(Key) ->
    % TODO
    ok.


% Is CAS enough to support transactions?
% I know you can implement mutexes with it so may be we can implement
% a lock service?
% Raft ensures the transaction order in all nodes is the same
cas(Key, ExpectedValue, NewValue) ->
    % TODO
    ok.
