-module(nilva_types).

-type raft_request() :: append_entries
                      | request_votes.
-type raft_response() :: reply_append_entries
                       | reply_request_votes.


% -type client_rsm_command(Command) :: {client_rsm_command, Command}.
% -type config_change(Config) :: {config_change, Config}.

% -type command(Command) :: config_change(Command)
%                   | heart_beat_no_op
%                   | client_rsm_command(Command).

% -type log_entry(Term, Index, command(Command), ClientSeqNum) ::
%     {log_entry, Term, Index, Command, ClientSeqNum}.


% ae => Append Entries
% rv => Request Votes
%
