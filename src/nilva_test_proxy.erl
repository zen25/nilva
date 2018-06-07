% Implements a proxy server for nilva_raft_fsm
%
% The proxy is used to support testing features like dropping/delaying messages etc.
%
% Note that the proxy acts as a combined buffer for both incoming & outgoing messages.
% Hence, do NOT use the proxy when benchmarking or performance testing
%
-module(nilva_test_proxy).
-behaviour(gen_server).

% Types
-type msg_type() :: 'incoming' | 'outgoing'.
-type proxy_mode() :: 'pass_all' | 'drop' | 'delay'.
-type drop_proxy_action(N) :: {'n_consecutive', N}
                            % Drop N randomly from the stream
                            | {'uniform', N}.
-type delay_proxy_action(T) :: {'fixed', T}
                             % Add delay based on uniform distribution
                             | {'uniform', T}.


% Public API
-export([start_link/0]).
% -export([proxyIn/1, proxyOut/1]).
% -export([drop_messages/0, delay_messages/0]).

% Callbacks
-export([init/1, handle_call/3, handle_cast/2]).


%% =========================================================================
%% Public API
%% =========================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% =========================================================================
%% Callbacks (gen_server)
%% =========================================================================
init(_Args) ->
    {ok, []}.

handle_call({echo, Msg}, _From, LoopData) ->
    {reply, {echo, ?MODULE, node(), Msg}, LoopData}.


% Route outgoing messages
handle_cast({send_to, Node, Msg}, LoopData) ->
    _Ignore = lager:info("Proxy routing message from ~p to ~p",
                         [node(), Node]),
    % Send the message to proxy
    gen_server:cast({?MODULE, Node}, Msg),
    {noreply, LoopData};
% Route incoming messages
handle_cast(Msg, LoopData) ->
    _Ignore = lager:info("Proxy routing incoming message to ~p", [node()]),
    % Note that `From` is embedded in the 4 raft message types
    gen_statem:cast(nilva_raft_fsm, Msg),
    {noreply, LoopData}.


%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_server:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_server:call({?MODULE, Node}, {echo, Msg}).
