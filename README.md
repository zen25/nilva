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
 - [ ] Linearizability from client perspective
 - [ ] Sharding of keys
 - [ ] Property Based tests to verify the Raft safety properties
 - [ ] WAL for making logs of replicated state machines durable
 - [ ] Optimizations
    - [ ] Log Compaction
    - [ ] Pipelining


See implementation_notes.md for comments on the implementation choices.

