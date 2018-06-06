% Implements a proxy server for nilva_raft_fsm
%
% The proxy is used to support testing features like dropping messages etc.
-module(nilva_test_proxy).
-behaviour(gen_server).

