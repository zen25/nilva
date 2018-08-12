-module(nilva).

% For testing & debugging
-export([set_test_proxy_all/2]).
-export([echo_fsm/1, echo_fsm_all/2]).
-export([get_state/0, get_state/1]).

-export([leader/0, get/2, put/3, delete/2, cas/4]).
-include("nilva_types.hrl").

%% =========================================================================
%% KV Store Public API
%% =========================================================================

-spec leader() -> node().
leader() ->
    % TODO: Get the current leader
    node().


-spec get(csn(), key()) ->
    {value, value()}
    | key_does_not_exist
    | not_a_leader
    | unavailable.
get(CSN, Key) ->
    % TODO
    gen_statem:call(nilva_raft_fsm, {client_request, {CSN, get, Key}}).


-spec put(csn(), key(), value()) ->
    ok
    | not_a_leader
    | unavailable.
put(CSN, Key, Value) ->
    % TODO
    gen_statem:call(nilva_raft_fsm, {client_request, {CSN, put, Key, Value}}).


-spec delete(csn(), key()) ->
    ok
    | not_a_leader
    | unavailable.
delete(CSN, Key) ->
    % TODO
    gen_statem:call(nilva_raft_fsm, {client_request, {CSN, delete, Key}}).


% Is CAS enough to support transactions?
% I know you can implement mutexes with it so may be we can implement
% a lock service?
% Raft ensures the transaction order in all nodes is the same
-spec cas(csn(), key(), value(), value()) ->
    {value, any()}
    | key_does_not_exist
    | not_a_leader
    | unavailable.
cas(CSN, Key, ExpectedValue, NewValue) ->
    gen_statem:call(nilva_raft_fsm, {client_request,
                    {CSN, cas, Key, ExpectedValue, NewValue}}),
    ExpectedValue.


%% =========================================================================
%% Debug Functions
%% =========================================================================

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
