% Provides REST API for the clients
%
-module(nilva_rest).

-behaviour(cowboy_rest).

-export([init_cowboy/0]).
-export([init/2,
         allowed_methods/2,
         content_types_provided/2]).
-export([reply_in_html/2, reply_in_json/2, reply_in_text/2]).

%% =========================================================================
%% Public Functions
%% =========================================================================

-spec init_cowboy() -> no_return().
init_cowboy() ->
    Dispatch = cowboy_router:compile([
        {'_', [{"/", ?MODULE, []}]}
    ]),
    {ok, _} = cowboy:start_clear(my_http_listener,
        % TODO: Host & Port should be set in nilva_config file for each peer
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ).


-spec init(cowboy_req:req(), any()) ->
    {cowboy_rest, cowboy_req:req(), any()}.
init(Req, State) ->
    Method = cowboy_req:method(Req),
    Version = cowboy_req:version(Req),
    erlang:display(Method),
    erlang:display(Version),
    {cowboy_rest, Req, State}.


allowed_methods(Req, State) ->
    % TODO: How do I support transactions using HTTP verbs?
    %       They are most likely not sufficient.
    % The prime reason for implementing a rest api so that I can make
    % from other programming languages like clojure & python.
    %
    % Another way to achieve this would be to expose functionality via C
    % and then build a client library based on it for each desired language
    % This gets around the hacks I would require to support transactions via rest
    %
    % See Hashicorp's Consul for how they support transactions via http
    Methods = [<<"GET">>, <<"POST">>, <<"DELETE">>],
    {Methods, Req, State}.


content_types_provided(Req, State) ->
    {[
        {<<"text/html">>, reply_in_html},
        {<<"application/json">>, reply_in_json},
        {<<"text/plain">>, reply_in_text}
    ], Req, State}.


reply_in_html(Req, State) ->
    Body = <<"<html>
<head>
    <meta charset=\"utf-8\">
    <title>REST Hello World!</title>
</head>
<body>
    <p>REST Hello World as HTML!</p>
</body>
</html>">>,
    {Body, Req, State}.

reply_in_json(Req, State) ->
    Body = <<"{\"rest\": \"Hello World!\"}">>,
    {Body, Req, State}.

reply_in_text(Req, State) ->
    {<<"REST Hello World as text!">>, Req, State}.
