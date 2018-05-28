Using Erlang's OTP to build the Nilva.

By design, RAFT requires consensus for writes. But reads can be served by the leader immediately.
Followers cannot serve the reads as their logs might be inconsistent with the leader. Additional
work may be needed to enable serving reads by the follower.

Hmm, maybe even the leader cannot serve the reads before a quorum of peers have applied
that log entry.

---

Annoying Errors and Their Fixes:
================================

**Error**:

===> Invalid /Users/eswarpaladugu/code/nilva/_build/default/lib/nilva/ebin/..app: name of application (nilva) must match filename.

**Fix**:

You most likely have "..app.src" instead of "<appname>.app.src"


---

References:
----------
1. Designing for Scalability with Erlang/OTP by Francesco Cesarini & Steve Vinoski
2. Learn You Some Erlang for Great Good! A Beginner's Guide by Fred Hébert
3. [A Concise Guide to Erlang by David Matuszek](http://www.cis.upenn.edu/~matuszek/General/ConciseGuides/concise-erlang.html)
4. (https://www.erlang-in-anger.com/)
