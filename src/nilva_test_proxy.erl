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
-type proxy_action(T) :: 'pass' | 'drop' | {'delay', T}.

-type pass_all() :: 'pass_all'.
-type drop_fixed(N) :: {'drop', 'fixed', N}.
-type drop_uniform(XPercent) :: {'drop', 'uniform', XPercent}.
-type delay_fixed(T) :: {'delay', 'fixed', T}.
-type delay_uniform(MinT, MaxT) :: {'delay', 'uniform', MinT, MaxT}.

-type proxy_mode(N, XPercent, T, MinT, MaxT)
                    :: pass_all()
                    | drop_fixed(N)
                    | drop_uniform(XPercent)
                    | delay_fixed(T)
                    | delay_uniform(MinT, MaxT).

% Public API
-export([start_link/0]).
-export([set/2]).
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
    {ok, pass_all}.

handle_call({echo, Msg}, _From, LoopData) ->
    {reply, {echo, ?MODULE, node(), Msg}, LoopData};
handle_call(pass_all, _, _) ->
    {reply, ok, pass_all};
handle_call({drop, n_consecutive, N}, _From, _) ->
    {reply, ok, {drop, n_consecutive, N}};
handle_call({drop, uniform, X}, _, _) ->
    {reply, ok, {drop, uniform, X}};
handle_call({delay, fixed, T}, _, _) ->
    {reply, ok, {delay, fixed, T}};
handle_call({delay, uniform, T}, _, _) ->
    {reply, ok, {delay, fixed, T}}.



% Route outgoing messages
handle_cast({send_to, Node, Msg}, LoopData) ->
    {NewLoopData, ProxyAction} = filter_message(LoopData),
    case ProxyAction of
        pass->
            _Ignore = lager:info("Proxy routing message from ~p to ~p",
                                [node(), Node]),
            % Send the message to proxy
            gen_server:cast({?MODULE, Node}, Msg),
            {noreply, NewLoopData};
        drop ->
            _Ignore = lager:info("Proxy dropping message from ~p to ~p",
                                [node(), Node]),
            {noreply, NewLoopData};
        {delay, T} ->
            _Ignore = lager:info("Proxy delaying message from ~p to ~p by ~p",
                                [node(), Node, T]),
            timer:sleep(T),
            % Send the message to proxy
            gen_server:cast({?MODULE, Node}, Msg),
            {noreply, NewLoopData}
    end;
% Route incoming messages
handle_cast(Msg, LoopData) ->
    {NewLoopData, ProxyAction} = filter_message(LoopData),
    case ProxyAction of
        pass ->
            _Ignore = lager:info("Proxy routing message to ~p",
                                [node()]),
            % Note that `From` is embedded in the 4 raft message types
            gen_statem:cast(nilva_raft_fsm, Msg),
            {noreply, NewLoopData};
        drop ->
            _Ignore = lager:info("Proxy dropping message to ~p",
                                [node()]),
            {noreply, NewLoopData};
        {delay, T} ->
            _Ignore = lager:info("Proxy delaying message to ~p by ~p",
                                [node(), T]),
            timer:sleep(T),
            gen_statem:cast(nilva_raft_fsm, Msg),
            {noreply, NewLoopData}
    end.


-spec filter_message(proxy_mode(N, XPercent, T, MinT, MaxT)) ->
    {proxy_mode(N, XPercent, T, MinT, MaxT), proxy_action(T)}.
filter_message(pass_all) -> {pass_all, pass};
filter_message({drop, n_consecutive, N}) when N > 1, is_integer(N) ->
    {{drop, n_consecutive, N - 1}, drop};
filter_message({drop, n_consecutive, N}) when N =:= 1, is_integer(N) ->
    {pass_all, drop};
filter_message({drop, uniform, X}) when X > 0, X =< 100 ->
    U = getUniformRand(0, 100),
    case X < U of
        true -> {{drop, uniform, X}, drop};
        false -> {{drop, uniform, X}, pass}
    end;
filter_message({delay, fixed, T}) ->
    {{delay, fixed, T}, {delay, T}};
filter_message({delay, uniform, MinT, MaxT}) ->
    T = getUniformRand(MinT, MaxT),
    {{delay, uniform, MinT, MaxT}, {delay, T}}.


-spec getUniformRand(number(), number()) -> number().
getUniformRand(Min, Max) ->
    Min + (Max - Min) * rand:uniform().


%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_server:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_server:call({?MODULE, Node}, {echo, Msg}).

set(Msg, Node) ->
    gen_server:call({?MODULE, Node}, Msg).

