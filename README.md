Nilva
=====

KV Store implementation based on Raft.

**TODO**:
 + [ ] Raft Consensus algorithm
    + [X] Leader Election
    + [ ] Log Replication
    + [ ] Snapshotting
    + [ ] Membership changes
    + [ ] RSM
    + [ ] Client Interaction
 + [ ] Other parts of KV store
    + [ ] Rest API for clients (Put, Get, Delete only)
    + [ ] Durable Raft Logs
    + [ ] Linearizability from client perspective
    + [ ] sharding of keys
 + [ ] Optimizations
    + [ ] Log Compaction
    + [ ] Pipelining
    + [ ] Serving (Stale) Reads from Followers
 + [X] Test Infrastructure
     + [ ] Test Proxy
        + [X] Drop N messages
        + [X] Drop x% of messages randomly (uniform distribution)
        + [X] Delay messages by time T
        + [X] Delay messages by ~Uniform(MinT, MaxT)
        + [ ] Force new election
        + [ ] Reorder messages
        + [ ] Better message delay models
    + [ ] Tracing
        + [ ] Internal Events
        + [ ] Trace post-processing
    + [ ] Test harness
        + [ ] Enable setup & tear down of the cluster
        + [ ] Random input generation
        + [ ] Trace collection & processing
+ [ ] Testing
    + [ ] Unit Tests
    + [ ] Property Based Testing
    + [ ] Integration tests
    + [ ] Jepsen Tests


See implementation_notes.md for comments on the implementation choices & ramblings.

