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

Rolling replacement keeps `maxUnavailable: 0` and permits one surge pod. The
post-Helm Kustomize layer applies `minReadySeconds: 60` to RTPEngine as well as
the SIP workloads. RTPEngine is configured with required Redis persistence
(the chart does not pass `--no-redis-required`); it waits for a Redis primary
and restores stored calls during startup, as described in the upstream
[Redis persistence options](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md#redis).
Its entrypoint forwards RTPEngine output and creates a readiness marker only
after its `Redis restore time = … ms` completion line. If Redis is unavailable
or restore does not complete, the replacement stays unready and the rollout
stalls while the old pod remains. Once the marker makes it Ready,
`minReadySeconds: 60` requires another full minute of Ready status before the
Deployment can advance. This delay does not prove that a second pod can own the
old UDP media socket; avoid scaling RTPEngine beyond its current replica count
until media-address ownership and live-call recovery are separately tested.

Render the post-Helm rollout patch and check the Redis startup requirement with:

```sh
AVoIP/tests/rtpengine-redis-rollout-render.sh
```

This verifies the restore-marker readiness gate, Deployment strategy and
60-second Ready interval. It does not inject a Valkey outage or establish media
continuity for an active call.

Kamailio controls RTPEngine through the stable internal Service DNS name and
UDP NG port; its configuration does not pin a pod IP. The [Kamailio RTPEngine
module](https://kamailio.org/docs/modules/6.1.x/modules/rtpengine.html) is
configured explicitly with `rtpengine_tout_ms=1000`, `rtpengine_retr=5`,
`rtpengine_disable_tout=5`, `aggressive_redetection=1`, `ping_mode=1`, and
`ping_interval=5`. A command timeout is retried; an unavailable node is
periodically probed and becomes eligible again when it responds. This is
control-plane recovery, not active-call migration: a media session pinned to a
failed RTPEngine still requires the Redis-backed restoration/takeover path.
The restore-marker readiness probe keeps a replacement out of Service
endpoints until Redis state restoration completes; the 60-second minimum-ready
interval then retains the previous endpoint while the new pod settles. During
that overlap, either Ready endpoint may receive a control request, so the
Redis-backed active-switchover path and actual call behavior still need a
controlled inbound-call test. The earlier rollout window contained Kamailio
initial-SDP control failures before the restore gate was deployed; after the
gated rollout, the active Kamailio replicas had no recent RTPEngine-control
errors. This is evidence for the startup readiness gap, not proof of audio or
end-to-end call continuity. WebSocket control is temporarily
disabled because the live RTPEngine process exited with signal 11 after its
first offer on that path. The crash cause still needs a core backtrace.
The chart hashes RTPEngine values into Kamailio's pod template so an RTPEngine
configuration change also replaces Kamailio pods and their UDP control
sockets. Recent live errors from `rtpengine_info()` were `invalid type for a
message` / `content type mismatching` while handling trickle-ICE INFO. These
are message-body/content-type parsing failures, not evidence that the NG
control socket disconnected; command retries and endpoint probes cannot fix
those requests. Inspect the Content-Type and body in an access-controlled,
redacted capture when diagnosing this separately; do not copy trickle bodies
to logs or persistent documentation because they can contain ICE passwords
and network candidates. Distinguish these parser errors from control timeout,
no-reply, or `Destination address required` messages. The render regression
checks the recovery parameters, but only an induced endpoint-outage test can
prove recovery on the deployed runtime.
RTPEngine's optional [WebSocket NG interface](https://rtpengine.readthedocs.io/en/latest/http_websocket_support.html)
uses the same NG control commands. The selected control port is reachable
through the cluster-internal Service and the Kamailio egress rules rendered by
this chart. When enabled, RTPEngine's HTTP listener also serves HTTP control
endpoints; the chart's Cilium ingress policy limits NG control to Kamailio pods
and preserves the configured UDP media range for cluster and external traffic.
The control listener does not expose the public media Service or change media
ownership.

When WebSocket control is enabled, the chart sets RTPEngine's HTTP/WS send
buffer to 1024 KiB. RTPEngine documents this size for high WebSocket activity
to improve performance and prevent protocol hiccups
([configuration option](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md#http-buf-sizeint)).
Increasing this buffer did not stop the observed crash after an NG offer.
The retained logs show a process exit with signal 11 after its reply, but do not
establish the faulting code path. Capture a core/backtrace before re-enabling
WebSocket control.

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
