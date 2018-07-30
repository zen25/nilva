%% Implements the replication log for Raft
%%
%%
-module(nilva_replication_log).
-include("nilva_types.hrl").

-export([get_current_term/0,
         voted_for/0
         ]).
-export([get_log_entry/2,
         get_log_entries/2,
         erase_log_entries/2,
         append_entries/1,
         check_log_completeness/1
         ]).
-export([init/0]).


%% =========================================================================
%% Public API
%% =========================================================================

-spec get_current_term() -> raft_term().
get_current_term() ->
    nilva_mnesia:get_current_term().

-spec voted_for() -> raft_peer_id().
voted_for() ->
    nilva_mnesia:get_voted_for().


-spec check_log_completeness(log_entry()) -> boolean().
check_log_completeness(_LogEntry) ->
    % TODO: Get term & idx from log entry & see if the command matches the entry in
    %       in current log
    false.

-spec get_log_entry(raft_term(), raft_log_idx()) -> log_entry().
get_log_entry(Term, Idx) ->
    nilva_mnesia:get_log_entry(Term, Idx).

-spec get_log_entries(raft_term(), raft_log_idx()) -> list(log_entry()).
% Returns log entries starting from given term & idx
% Useful for when the leader needs to overwrite it's peer's log
get_log_entries(Term, Idx) ->
    nilva_mnesia:get_log_entries(Term, Idx).

-spec erase_log_entries(raft_term(), raft_log_idx()) -> no_return().
erase_log_entries(Term, Idx) ->
    nilva_mnesia:erase_log_entries(Term, Idx).

-spec append_entries(list(log_entry())) -> no_return().
append_entries(LogEntries) ->
    nilva_mnesia:append_entries(LogEntries).

init() ->
    nilva_mnesia:init().

%% =========================================================================
%% Private
%% =========================================================================

% Note: Mnesia is used on local nodes as the storage engine for the replication log
%       You can use anything else like sqlite or leveldb etc., as the storage engine
%       as long as it provides atomic writes & reads and durability. We do not care
%       about isolation as we have sequential reads & writes in the current design.
%       To summarize, out of ACID, we only need A (atomicity) & D (durability) from our
%       storage engine
%
%       Mnesia was chosen as it already ships with the Erlang OTP.

