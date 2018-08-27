%% Implements the replication log for Raft
%%
%%
-module(nilva_replication_log).
-include("nilva_types.hrl").

-export([get_current_term/0,
         set_current_term/1,
         voted_for/0,
         vote/1
         ]).
-export([get_log_entry/1,
         get_log_entries/1,
         erase_log_entries/1,
         append_entries/1
         ]).
-export([check_log_completeness/2, get_last_log_idx_and_term/0]).
-export([init/0]).


%% =========================================================================
%% Public API
%% =========================================================================

-spec get_current_term() -> raft_term().
get_current_term() ->
    nilva_mnesia:get_current_term().

-spec set_current_term(raft_term()) -> no_return().
set_current_term(Term) ->
    nilva_mnesia:set_current_term(Term).

-spec voted_for() -> raft_peer_id().
voted_for() ->
    nilva_mnesia:get_voted_for().

-spec vote(raft_peer_id()) -> no_return().
vote(Peer) ->
    nilva_mnesia:set_voted_for(Peer).


-spec check_log_completeness(append_entries(), raft_state()) -> boolean().
% TODO: Do we need to distinguish between simply append, reject, overwrite & append
%       Seems like the result should be tri-state to me
check_log_completeness(AE=#ae{prev_log_idx=LIdx}, State=#raft{last_log_idx=FIdx})
    when LIdx == FIdx ->
        % Follower is supposed to be up to date with the leader
        AE#ae.prev_log_term == State#raft.last_log_term;
check_log_completeness(_AE=#ae{prev_log_idx=LIdx}, _State=#raft{last_log_idx=FIdx})
    when LIdx > FIdx ->
        % Follower is not up to date with the leader
        % The logs should not have any holes
        false;
check_log_completeness(AE=#ae{prev_log_idx=LIdx}, _State=#raft{last_log_idx=FIdx})
    when LIdx < FIdx ->
        % Follower has excess entries
        LE = get_log_entry(LIdx),
        case LE of
            {error, _Error} ->
                % NOTE: Should not be possible.
                %       There should not be holes in the log
                false;
            _ ->
                LE#log_entry.term == AE#ae.prev_log_term
        end.


-spec get_log_entry(raft_log_idx()) -> log_entry() | {error, any()}.
get_log_entry(Idx) ->
    nilva_mnesia:get_log_entry(Idx).

-spec get_log_entries(raft_log_idx()) -> list(log_entry()).
% Returns log entries starting from given term & idx
% Useful for when the leader needs to overwrite it's peer's log
get_log_entries(Idx) ->
    nilva_mnesia:get_log_entries_starting_from(Idx).

-spec erase_log_entries(raft_log_idx()) -> no_return().
erase_log_entries(Idx) ->
    nilva_mnesia:del_log_entries_starting_from(Idx).

-spec append_entries(list(log_entry())) -> ok | {error, any()}.
append_entries([LogEntry]) ->
    nilva_mnesia:write_entry(LogEntry);
append_entries(LogEntries) ->
    nilva_mnesia:write_entries(LogEntries).


-spec get_last_log_idx_and_term() -> {raft_log_idx(), raft_term()}.
get_last_log_idx_and_term() ->
    case nilva_mnesia:get_last_log_idx_and_term() of
        {error, _} -> {0, 0};
        Res -> Res
    end.


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

