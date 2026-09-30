# RTPEngine HA

RTPEngine remains the exclusive media anchor. Initial SDP failure is fail
closed: Kamailio does not expose backend SDP and returns an appropriate 503;
dialog SDP failure returns 488 where applicable. Early CANCEL explicitly calls
`rtpengine_manage()` before the transaction is relayed, preventing stale
media sessions.

The current chart uses site-local Valkey state, keyspace subscription,
`--redis-resolve-on-reconnect`, and `--active-switchover`. This is recovery
state, not proof that a second pod owns the same UDP socket, public address,
or port. Before increasing replicas, choose deterministic public media
ownership (unique addresses, node-bound addresses, proven ECMP, or controlled
active/standby takeover).

Test pod deletion, process kill, node drain, Valkey primary restart, HAProxy
master selection failure, and rolling updates. Record existing-call survival,
one-way audio, RTP gap, DTMF, fax, new-call admission, and RTCP continuity.
Do not claim zero packet loss without measurements.
