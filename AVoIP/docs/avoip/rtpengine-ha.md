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

The chart creates a one-shard, two-replica `ValkeyCluster` through the
[Valkey operator](https://github.com/valkey-io/valkey-operator/tree/v0.7.0)
installed by the [Backplane Valkey operator ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Valkey/Operator.yaml).
External Secrets generates the Valkey ACL password in the operator namespace,
pushes it to the site Vault path, and mirrors it into
`valkey-operator-system` and `core-prod`. The source Secret is retained across
routine chart updates. The flow uses the
[Password generator](https://external-secrets.io/latest/api/generator/password/)
and [PushSecret](https://external-secrets.io/latest/api/pushsecret/).

Two internal [HAProxy](https://www.haproxy.org/) replicas use an authenticated
[Redis TCP health check](https://docs.haproxy.org/3.2/configuration.html#5.2-tcp-check)
with `INFO replication`. New connections go only to the node reporting
`role:master`; existing sessions close when a node loses primary status.
This adapts the operator's all-node headless Service for RTPEngine's direct
Redis client, which does not follow Redis Cluster redirects. Call-state
restoration and switchover still require live validation.

Test pod deletion, process kill, node drain, Valkey primary restart, HAProxy
master selection failure, and rolling updates. Record existing-call survival,
one-way audio, RTP gap, DTMF, fax, new-call admission, and RTCP continuity.
Do not claim zero packet loss without measurements.
