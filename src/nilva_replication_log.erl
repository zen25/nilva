%% Implements the replication log for Raft
%%
%%
-module(nilva_replication_log).
-include("nilva_types.hrl").

-export([get_current_term/0,
         voted_for/0,
         voted_for/1
         ]).
-export([is_log_complete/1,
         check_for_conflicting_entries/1,
         erase_conflicting_entries/1,
         write_entries/1
         ]).
-export([init_log/0, check_for_existing_log/0, load_log/0]).


%% =========================================================================
%% Public API
%% =========================================================================

-spec get_current_term() -> raft_term().
get_current_term() ->
    1.

-spec voted_for() -> raft_peer_id().
voted_for() ->
    voted_for(get_current_term()).

-spec voted_for(raft_term()) -> raft_peer_id().
voted_for(_Term) ->
    node().

-spec is_log_complete({raft_term(), raft_log_idx()}) -> boolean().
is_log_complete({_TermOfPrevEntry, _IdxOfPrevEntry}) ->
    false.

-spec check_for_conflicting_entries(append_entries()) -> list({raft_term(), raft_log_idx()}).
check_for_conflicting_entries(_AE) ->
    [].

-spec erase_conflicting_entries({raft_term(), raft_log_idx()}) -> boolean().
erase_conflicting_entries(_) ->
    true.

-spec write_entries(append_entries()) -> boolean().
write_entries(_AE) ->
    true.

-spec init_log() -> boolean().
init_log() ->
    true.

-spec check_for_existing_log() -> boolean().
check_for_existing_log() ->
    false.

-spec load_log() -> boolean().
load_log() ->
    true.

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

