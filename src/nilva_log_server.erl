-module(nilva_log_server).

-behaviour(gen_server).
-include("nilva_types.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

% For testing & debugging
-export([echo/1]).


%% =========================================================================
%% Public API
%% =========================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

echo(Msg) ->
    gen_server:call(?MODULE, {echo, Msg}).


%% =========================================================================
%% Callbacks (gen_server)
%% =========================================================================
init(_Args) ->
    {ok, []}.

handle_call({echo, Msg}, _From, LoopData) ->
    {reply, Msg, LoopData}.

handle_cast({echo, Msg}, LoopData) ->
    io:format("handle_cast recieved: ~w", [Msg]),
    {noreply, LoopData, LoopData}.


