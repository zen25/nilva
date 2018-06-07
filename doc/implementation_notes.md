Using Erlang's OTP to build the Nilva.

By design, RAFT requires consensus for writes. But reads can be served by the
leader immediately. Followers cannot serve the reads as their logs might be
inconsistent with the leader. Additional work may be needed to enable serving
reads by the follower.

Hmm, maybe even the leader cannot serve the reads before a quorum of peers have
applied that log entry.


## Raft Logs:

Raft logs act as WAL for the RSM. Logs are used to store multiple types of
entries:

    * durable raft server state
    * client RSM commands
    * snapshot information
    * response to client RSM commands

Each of these are stored as a json entry in the log file. The json was simply
chosen as it is human readable. Any other format would work.

Each log entry stored on a disk should also include a checksum to guard against
corruption.

Snapshotting is not needed if the RSM is itself durable. For example, if the RSM
is sqlite, once the SQL command is applied, it is durable. We may need to keep
the responses still in the log though to properly handle client requests in case
of idempotent client requests.

---

## Testing

See (https://asatarin.github.io/testing-distributed-systems/) for some ideas.

### Infrastructure:

#### Simulating Process Failure

A process that is dropping messages is indistinguishable from a failed process
in a distributed system. Let's use this to our advantage.

To simulate a peer failure, we can:

+ drop next N messages
+ drop x% of arriving messages randomly based on uniform distribution
+ drop all messages until we decide not to anymore

##### Test Proxy (nilva_test_proxy)

To accomplish the above, I decided to route the messages to & fro `nilva_raft_fsm` through a proxy. This separates the test infrastructure code from the raft code. This also makes it easier to test the test infrastructure code.

Note that while the proxy can simulate node failure from peer's perspective, it
cannot do that from node's perspective. You still need to find a way to test
Raft log's durability and things like restoring from snapshot etc., that occur
when a node recovers using some other method.

**Caveat**
Proxy server acts as a combined buffer for both incoming & outgoing messages.
This is going to impact benchmarking & performance data but should not impact
the correctness of the implementation. So do not use test configuration for
performance testing.

#### Other

In addition to that, we can have a peer forcefully start a new
election.

During the initial implementation of leader election, it was necessary to
implement the send heartbeats for leader and broadcasting the append entries to
followers to maintain its authority. Without this, every node timed out and the
number of elections that were held quickly got out of hand. It was not possible
to even easily verify that there was at most one leader in the term. This was
exacerbated by the fact that all the nodes write to the same log file as I had
not setup separate log files for each node in lager's config during initial
implementation.

### Methods:

Trace messages from the logs can be used to write tests. You can process the
logs from each peer, extract the relevant data and run the tests on that data.
These tests can ensure that we do not violate some properties like single leader
etc., but are not sufficient by themselves. Tracing assumes that a peer's log
records everything necessary and there are no missed events.

Linearizability needs to be tested w.r.t the clients. See if it is easy to use
jepsen for this. The whole point of REST api for clients was to make this
easier.

Aside, I should probably use a known language for processing logs like Python. I
am not familiar with Erlang's string processing capabilities and they almost
always are PITA in any language in my experience.

#### TODO: How to test the following?

- How do you test the supervisor and restarts? How do you test the process
- skeleton at each node? How do you test the communication between nodes? How do
- you test the configuration changes?

### What to test?

1. Term & Log Idx are monotonically increasing
2. A Leader can have only 1 term. No consecutive terms are possible
3. A Candidate can have multiple consecutive terms
   (1 for each election cycle during split votes).
4. A Follower can have multiple consecutive terms
5. There can be at most 1 Leader per term. Multiple candidates are possible
6. There can be at most N candidates during election where N is number of nodes
   in the cluster. This can happen when each node is isolated from the rest.

---

### Dev Environment

**Q**: What is the Erlang's equivalent of `dir()` in Python?

##### Rebar3

Rebar3 comes with lots of features. Some things I was not aware of:

+ "rebar3 shell" launches an interactive shell from which you can compile,
  run tests & run dialyzer
+ running dialyzer compiles the code. No need to do the compile step as a
  separate step
+ you can launch an app by:
    > rebar3 shell --apps nilva
+ you can run in test configuration by running:
    > rebar3 as test shell --apps nilva

See: (https://ferd.ca/rebar3-shell.html)

##### Distributed Cluster

We have a registered process, nilva_raft_fsm, on all nodes. So it is enough to
store node ids to fully qualify the process.


##### Tidbits

`random:uniform()` gives the same sequence of random numbers irrespective of the
process. Use `rand:uniform()` instead if you do not want to set the seed. While
rand's documentation do not recommend it for cryptographic applications, this
should not matter much in this project as we are primarily using it to calculate
election timeouts.

In Erlang's `gen_statem`, if the `next_state` is the same as the current state,
it is not considered a state change. Hence, the timers are not reset here. We
need to do explicitly reset the election timeout timer in such cases.

Less than or equal to is "=<" in Erlang.

---

### Annoying Errors and Their Fixes:

**Error**:

===> Invalid /Users/eswarpaladugu/code/nilva/_build/default/lib/nilva/ebin/..app: name of application (nilva) must match filename.

**Fix**:

You most likely have "..app.src" instead of "appname.app.src"

**Error**:

** exception error: undefined function lager:error/1

**FIX**:

Move deps line rebar.config before erl_opts line. See
(http://lists.basho.com/pipermail/riak-users_lists.basho.com/2013-January/010732.html)

---

References:
----------
1. Designing for Scalability with Erlang/OTP by Francesco Cesarini & Steve Vinoski
2. Learn You Some Erlang for Great Good! A Beginner's Guide by Fred Hébert
3. [A Concise Guide to Erlang by David Matuszek](http://www.cis.upenn.edu/~matuszek/General/ConciseGuides/concise-erlang.html)
4. (https://www.erlang-in-anger.com/)
5. (https://asatarin.github.io/testing-distributed-systems/)
6. (https://www.youtube.com/watch?v=f_jl6MR3kXQ)
