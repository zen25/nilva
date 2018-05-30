Nilva
=====

KV Store implementation based on Raft.

TODO:
 - [ ] Raft Consensus algorithm
    - [ ] Leader Election
    - [ ] Log Replication
    - [ ] Membership changes
    - [ ] Others like client sequence numbers, sessions etc.
 - [ ] Rest API for clients (Put, Get, Delete only)
 - [ ] Durable Raft Logs
 - [ ] Linearizability from client perspective
 - [ ] Sharding of keys
 - [ ] Property Based tests to verify the Raft safety properties
 - [ ] Optimizations
    - [ ] Log Compaction
    - [ ] Pipelining
    - [ ] Serving Reads from Followers
 - [ ] Implement Test Infrastructure
    - [ ] Drop N messages
    - [ ] Drop x% of messages
    - [ ] Drop all messages until told otherwise
    - [ ] Force re-election


See implementation_notes.md for comments on the implementation choices.

