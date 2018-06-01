% Implements the log for Raft
%
% The log acts as a Write Ahead Log (WAL) for Resplicated State Machine (RSM)
%
-module(nilva_log_server).

-behaviour(gen_server).
-include("nilva_types.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

% For testing & debugging
-export([echo/1, echo/2]).


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

handle_cast({echo, Msg}, LoopData) ->
    io:format("handle_cast recieved: ~w", [Msg]),
    {noreply, LoopData, LoopData}.


%% =========================================================================
%% For testing & debugging
%% =========================================================================
echo(Msg) ->
    gen_server:call(?MODULE, {echo, Msg}).

echo(Msg, Node) ->
    gen_server:call({?MODULE, Node}, {echo, Msg}).
