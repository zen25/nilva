Using Erlang's OTP to build the Nilva.

By design, RAFT requires consensus for writes. But reads can be served by the leader immediately.
Followers cannot serve the reads as their logs might be inconsistent with the leader. Additional
work may be needed to enable serving reads by the follower.

Hmm, maybe even the leader cannot serve the reads before a quorum of peers have applied
that log entry.

---

## Raft Logs:

Raft logs act as WAL for the RSM. Logs are used to store multiple types of entries:
    - durable raft server state
    - client RSM commands
    - snapshot information
    - response to client RSM commands

Each of these are stored as a json entry in the log file.

Snapshotting is not needed if the RSM is itself durable. For example, if the RSM is sqlite,
once the SQL command is applied, it is durable. We may need to keep the responses still in
the log though to properly handle client requests in case of idempotent client requests.


## Test Infrastructure:

A process that is dropping messages is indistinguishable from a failed process in a distributed
system. Use this to your advantage.

To simulate a peer failure, we can:
    - drop next N messages
    - drop x% of arriving messages randomly based on uniform distribution
    - drop all messages until we decide not to anymore

Dropping messages comes with a caveat though. How should we handle messages from the log
server and self()? We know that log server and raft fsm are under a supervisor with one for
all strategy. Need to figure out what to do in this case.

In addition to that, we can have a peer forcefully start a new election.

---

### Dev Environment

**Q**: What is the erlang's equivalent of `dir()` in Python?

##### Rebar3

Rebar3 comes with lots of features. Some things I was not aware of:
    - "rebar3 shell" launches an interactice shell from which you can compile, run tests & run dialyzer
    - running dialyzer compiles the code. No need to do the compile step as a separate step
    - you can launch an app by " > rebar3 shell --apps nilva"

See: (https://ferd.ca/rebar3-shell.html)

##### Distributed Cluster

We have a registered process, nilva_raft_fsm, on all nodes. So it is enough to store
node ids to fully qualify the process.

---

### Annoying Errors and Their Fixes:

**Error**:

===> Invalid /Users/eswarpaladugu/code/nilva/_build/default/lib/nilva/ebin/..app: name of application (nilva) must match filename.

**Fix**:

You most likely have "..app.src" instead of "appname.app.src"


---

References:
----------
1. Designing for Scalability with Erlang/OTP by Francesco Cesarini & Steve Vinoski
2. Learn You Some Erlang for Great Good! A Beginner's Guide by Fred Hébert
3. [A Concise Guide to Erlang by David Matuszek](http://www.cis.upenn.edu/~matuszek/General/ConciseGuides/concise-erlang.html)
4. (https://www.erlang-in-anger.com/)
