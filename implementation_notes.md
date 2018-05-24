Erlang provides a library to do the RPC. I am not using this and implementing my own. I intend to use this project as a tool to learn erlang beyond beginner level.

By design, RAFT requires consensus for writes. So reads can be served by the leader immediately.
Followers cannot serve the reads as their log might be in an inconsistent state w.r.t the current leader.
