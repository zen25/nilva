Nilva
=====

KV Store implementation based on Raft.

**TODO**:
+ [ ] Raft Consensus algorithm
    + [x] Leader Election
    + [ ] Log Replication
    + [ ] Snapshotting
    + [ ] Membership changes
    + [X] RSM
    + [X] Client Interaction
+ [ ] Other parts of KV store
    + [ ] REST API for clients (Put, Get, Delete only)
    + [X] Durable Raft Logs
    + [ ] Linearizability from client perspective
    + [ ] sharding of keys
+ [ ] Optimizations
    + [ ] Log Compaction
    + [ ] Pipelining
    + [ ] Serving (Stale) Reads from Followers
+ [ ] Test Infrastructure
    + [ ] Test Proxy
        + [x] Drop N messages
        + [x] Drop x% of messages randomly (uniform distribution)
        + [x] Delay messages by time T
        + [x] Delay messages by ~Uniform(MinT, MaxT)
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

