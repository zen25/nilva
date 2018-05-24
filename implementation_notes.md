Using Erlang's OTP to build the Nilva.

By design, RAFT requires consensus for writes. But reads can be served by the leader immediately.
Followers cannot serve the reads as their logs might be inconsistent with the leader. Additional
work may be needed to enable serving reads by the follower.

---

#References:
1. Designing for Scalability with Erlang/OTP by Francesco Cesarini & Steve Vinoski
2. Learn You Some Erlang for Great Good! A Beginner's Guide by Fred Hébert
3. [A Concise Guide to Erlang by David Matuszek](http://www.cis.upenn.edu/~matuszek/General/ConciseGuides/concise-erlang.html)
