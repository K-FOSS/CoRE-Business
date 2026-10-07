# AVoIP

This chart is the site-specific desired state for the AVoIP stack in `core-prod`.
The [SIP, identity, and RTC architecture plan](docs/SIP-STATEFUL-HA.md) and its
[phased TODO tracker](TODO.md) describe proposed stateful routing, web phone,
directory switchboard, MatrixRTC and native calling work, with evidence gates
and rollback. They do not change the deployed call path.
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
deploys it to the DC1 hub, Home1, and the `dc1-k3s` spoke. DC1 and Home1
enable the telephony workloads; the `dc1-k3s` spoke does not enable Asterisk
or FreeSWITCH. Speech recognition and synthesis are provided by the existing
[CoRE AI stack](https://github.com/K-FOSS/CoRE-Business/tree/main/AI), not by
workloads duplicated in this chart. Homer has an Authentik-protected web route
where enabled.

## Validation status

The chart is deployed, but the end-to-end call and failover paths still need
live verification:

1. Confirm an inbound Flowroute INVITE receives an ACK at FreeSWITCH and stays
   up for at least 60 seconds. Calls observed on 2026-09-30 ended after about
   32 seconds with `ACK Timeout`; see [SIP identity and call verification](docs/SIP-IDENTITY.md).
2. Verify an ordinary voice call bridges to Asterisk and a fax call reaches
   `rxfax`, writes a TIFF, and completes with the configured T.38/G.711 mode.
3. Exercise site failover and the RTPEngine/Valkey recovery path before treating
   either as production verified.

Changes flow through Git and Argo CD; Reloader restarts workloads when their
watched configuration changes.

## Named Kamailio instances

See the [Kamailio values reference](docs/KAMAILIO-VALUES.md) for every
supported instance option, default, role constraint, and site override.

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
supplies a complete `kamailio.instances` array for DC1, Home1, and
`dc1-k3s-node1`. Site Helm values **replace the whole array**; include every
desired instance at each site. The chart merges maps in this order:
`kamailio.defaults` → `kamailio.roleDefaults[role]` → the named instance.
Lists, including `instances`, `extraEnv`, scheduling tolerations, and any
future listener or destination lists, replace rather than append. The template
deep copies each layer before merging it. An instance name is a stable DNS
label; never rename it to reorder the array.

The current `carrier-sbc` profile owns the existing `carrier` instance, its
three replicas, public UDP/TCP/TLS and private TLS listeners, carrier CIDR ACL,
TOPOS state, and RTPEngine behavior. The `private-sbc` profile provides a
private TLS Service with the same request, authorization, dialog, and backend
routing functions and no public Service or Gateway route. Its media integration
is off by default. Registration and LDAP/RADIUS authentication are not
implemented; `REGISTER` remains rejected. The role validator rejects disabled
core routing functions, invalid roles/names, duplicate names, and TOPOS
database or Secret reuse between enabled instances.

For an isolated test values file, add a second entry alongside the complete
carrier entry:

```yaml
kamailio:
  instances:
    - name: 'carrier'
      enabled: true
      role: 'carrier-sbc'
      replicas: 3
    - name: 'internal'
      enabled: true
      role: 'private-sbc'
      replicas: 1
      topology:
        redis:
          database: 52
          secretName: 'avoip-kamailio-internal-topos'
```

Each enabled instance gets its own Deployment, ConfigMap, private Service,
certificate, TOPOS Secret reference, and applicable NetworkPolicy, disruption
budget, and public routes. Resources use the name, never its array position.
The carrier's existing names and immutable Deployment selector remain intact;
new roles use their own controller and instance selector labels. Per-instance
settings include image, replicas, resources, pod and container security,
scheduling, annotations, extra environment entries, Service options,
listener bind address and transport enablement, advertised SIP identity,
backend destination, and TOPOS configuration. Keep credential values in the
existing External Secret integration; `extraEnv` must use Secret references
for credentials.

Run `tests/kamailio-instances.sh` and `tests/sip-security-render.sh` before
publishing. To roll out this refactor, publish the chart and its owning
ApplicationSet values, review the rendered carrier resource names/selectors
and source ACL, then reconcile only the affected AVoIP child Applications.
The changed ConfigMap and added pod instance label cause a carrier Deployment
rollout, but do not replace the Deployment or its Service. Watch each pod
become ready and correlate a test Call-ID across the public Kamailio leg,
private Kamailio leg, and FreeSWITCH; require a 2xx ACK at FreeSWITCH and
BYE/200 completion after more than 60 seconds. Fax completion is a separate
check. For rollback, revert both the chart and ApplicationSet commits and
reconcile the same child Applications. Do not enable the example internal
instance in production until its destination, ACL, identity, and TOPOS store
have been reviewed.

## Deployment ownership

Optional interface profiles for every enabled workload and the named YAML
`functions` array are documented in [NETWORKING.md](docs/NETWORKING.md).
They support Multus/CNI configuration, placement, DNS, and NIC init containers.

The owner is the [AVoIP ApplicationSet in CoRE-Backplane](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
Its current desired state uses a merged generator for three production
clusters: `core-dc1-talos-prod`, `core-home1-talos-prod`, and
`dc1-k3s-node1`. It deploys the `AVoIP` path from the
[CoRE-Business source repository](https://slop.writemy.codes/CoRE/CoRE-Business), targets
`core-prod`, and renders through the
[Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin).

The [owning ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
uses `targetRevision: HEAD`, enables `CreateNamespace=true` and
`ServerSideApply=true`, and injects the following Helm merge values:

- `env`, `datacenter`, `region`, and `cluster` identity/type/domain metadata.
- `asterisk.enabled`, `kamailio.instances`, `freeswitch.enabled`,
  `rtpengine.enabled`, and public exposure settings per cluster. RTPEngine is
  independently deployable; media integration is conditional on the relevant
  SIP workloads also being enabled.
- `livekit.enabled` and the per-site LiveKit public media Service provider.
  LiveKit is enabled for the DC1 hub and Home1; the legacy `dc1-k3s` site stays
  disabled.
- `hub` metadata for spoke clusters.
- `gateway.name`, `gateway.namespace`, and `gateway.sectionName`.
- `jitsi.domain` and `jitsi.tls.secretName`.

The component selection in the ApplicationSet's Git desired state is:

| Cluster | Role | Asterisk | FreeSWITCH | LiveKit |
| --- | --- | --- | --- | --- |
| `core-dc1-talos-prod` | Hub | Enabled | Enabled | Enabled |
| `core-home1-talos-prod` | Spoke | Enabled | Enabled | Enabled |
| `dc1-k3s-node1` | Spoke | Disabled | Disabled | Disabled |

The chart’s top-level `values.yaml` supplies standalone defaults. The
ApplicationSet's Lovely-injected values select each site's actual components,
hostnames, media addresses, and DIDs. Inspect both layers before changing a
site deployment.

## LiveKit Server

This section documents the intended rendered configuration. It does not claim
that Argo CD has reconciled the changes or that external WebRTC media has been
verified.

The [official LiveKit Server Helm chart](https://github.com/livekit/livekit-helm/tree/master/livekit-server)
is pinned to chart `1.9.0` from the [official `helm.livekit.io` chart repository](https://helm.livekit.io).
It is enabled for the DC1 hub and Home1 by the active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The chart is configured for one
[official `livekit/livekit-server` image](https://hub.docker.com/r/livekit/livekit-server)
replica per enabled site, pinned to multi-platform image digest
`sha256:3602a85840d51981808d0519aefca170a3dbe3dec7bc8c5b87cbd52a503ea89f`, with host networking,
required hostname anti-affinity, `Recreate` deployment strategy, and `2` CPU / `2Gi`
requests (`4` CPU / `4Gi` limits). The separate media LoadBalancer uses the
site's existing public-service allocation mechanism: PureLB `core-public` in
YXL and kube-vip with UPnP forwarding in YVR. It receives its address from the
site pool rather than reusing the AVoIP RTPEngine address. LiveKit uses STUN
external-address discovery; after allocation, verify that its advertised
candidate matches the address and inbound NAT path of this Service.

Configured signaling/WebSocket endpoints are `livekit-yxl.mylogin.space` and
`livekit-yvr.mylogin.space`, HTTPS through the
existing `main-gw` / `https-myloginspace` listener and its configured certificate.
The gateway HTTPRoute carries signaling only. Media uses UDP `7882` (LiveKit UDP
mux) and ICE/TCP fallback `7881` on the separate public LoadBalancer; TCP `7880`
is the in-cluster HTTP/signaling backend. The UDP mux avoids using LiveKit's
default UDP range, and both media ports are distinct from the AVoIP RTP ranges.
The chart uses host networking and required pod anti-affinity so the bound ports
cannot collide with another LiveKit replica on the same node.

Redis is configured to use the site's TLS Dragonfly endpoint on `6379`,
database `155`, allocated
in the [Dragonfly logical database registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md).
The password comes from the existing site Vault path
`Storage/DragonFly/CoRE/<region>/<datacenter>/<cluster>/Creds`; it is injected
through `LIVEKIT_REDIS_PASSWORD`. ESO creates an API key and secret, persists
them to `AVoIP/LiveKit/<region>/<datacenter>/<cluster>/Creds`, and syncs the
key file into the workload Secret. The Kustomize patch fixes the upstream
chart's absolute key-file mount/Secret subPath mismatch and injects the Redis
environment variable without rendering its value into a ConfigMap.

RTPEngine, Kamailio, and FreeSWITCH are not reused. RTPEngine handles SIP/SDP
media anchoring and does not implement LiveKit's ICE candidate negotiation,
WebRTC transport, or SFU forwarding. Kamailio handles SIP signaling, not
LiveKit's HTTP/WebSocket signaling protocol. FreeSWITCH is the AVoIP PBX/SIP
media endpoint and is not a LiveKit SFU. Nextcloud Talk's Janus/eturnal backend
is also a separate signaling/media stack. These components and AVoIP routes
remain unchanged; LiveKit has its own service and public media ports.

Required site prerequisites are the ESO/CoreVault ClusterSecretStore, the
site-local authenticated TLS Dragonfly endpoint, a public DNS record for each
signaling hostname, a valid certificate on the existing Gateway listener, and
an available public address in each site's PureLB or kube-vip pool. Firewalls
and NAT must permit inbound UDP `7882` and TCP `7881` to the media Service and
the provider must route those ports to its local host-network endpoint. Clients
need outbound access to STUN for external-address discovery. TURN is disabled;
clients behind restrictive NATs may require an independently operated TURN
service, which is not part of this LiveKit Server-only deployment.

The Helm/Lovely render configures one replica, Service/Route resources, TLS
Redis, credentials by secret reference, and media ports. It does not prove the
site load balancer allocated an address, that STUN advertises that address, or
that UDP/TCP media is reachable externally. After reconciliation, check the
Service address, LiveKit ICE candidate logs, Gateway route/certificate status,
Redis ExternalSecret readiness, and a WebRTC call from outside each site.
LiveKit credentials are retained in Vault if the deployment is removed; rotate
or delete them only as a coordinated API-client lifecycle change.

Upstream references: [LiveKit website](https://livekit.io/),
[self-hosting documentation](https://docs.livekit.io/transport/self-hosting/),
[configuration reference](https://docs.livekit.io/transport/self-hosting/deployment/),
[official Helm charts](https://github.com/livekit/livekit-helm/tree/master/livekit-server),
[LiveKit Server source](https://github.com/livekit/livekit).

The deployed FreeSWITCH image is built by the site-local
[Core-Docker Forgejo project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker)
from its [FreeSWITCH image definition](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker/src/branch/main/Images/FreeSwitch)
and consumed from the Forgejo container registry. The chart pins an immutable
Forgejo build tag rather than the moving Docker Hub `latest` image.

When Kamailio is enabled, the chart deploys the official
[Kamailio SIP server](https://www.kamailio.org/) from its
[official container images](https://github.com/kamailio/kamailio-docker),
configured for SIP TLS passthrough on port 5061 through the `main-gw`
`sips-tls` listener to Kamailio's native TLS socket. Envoy Gateway normally
selects the TLSRoute by SNI; an EnvoyPatchPolicy removes the SNI match from
the single SIPS filter chain so clients that omit SNI still reach Kamailio.
Kamailio presents the public certificate and terminates TLS. This takes effect
after the active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
and [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml)
reconcile.
Envoy Gateway's
[BackendTrafficPolicy](https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/backend-traffic-policy/)
sends PROXY protocol v2 to Kamailio, and Kamailio's
[HAProxy PROXY-protocol support](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#tcp_accept_haproxy)
verifies the original Flowroute source before forwarding SIP to the configured
private backend. The chart configures
[symmetric response routing](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#force_rport)
to Flowroute requests so answers use the received TLS source port even when
the carrier's Via advertises 5061. Kamailio and FreeSWITCH can be enabled independently; when
both are enabled, the default Kamailio backend is FreeSWITCH's private TLS-only
SIP profile on port 5061. Kamailio uses TOPOS-backed two-sided topology state
for the asymmetric edge: the internal route is Kamailio's private TLS Service
on port 5062. It selects the public route from the carrier's initial transport:
UDP dialogs use `kamailio-pub.<cluster>.<datacenter>.<region>.resolvemy.host:5060`
over UDP; TCP dialogs use that host and port over TCP; TLS dialogs use the site's
`sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061` identity over TLS. TOPOS hides
the private route and backend Contact from Flowroute without a second manual
header-rewrite layer. Both sites can use the same DIDs through separate
site-local value/secret injection; the site-specific dialog route keeps each
call's signaling anchored to the site that accepted it. This supports YVR
primary/YXL failover for new calls, while established dialogs remain local to
their original site. After `loose_route_mode("1")` handles the public route,
carrier-originated in-dialog requests are sent to FreeSWITCH over the private
TLS service. Public 180, 183, and successful INVITE 2xx Contacts preserve their
called user, public port, and transport: UDP/TCP uses the direct Service host
on 5060, and TLS uses the site's SIPS host on 5061. FreeSWITCH's backend-facing
SIP profile remains private TLS; TOPOS removes that Contact before it reaches
the carrier.
Every in-dialog request, including 2xx ACK, follows the dialog Route set;
Kamailio drops an ACK with an invalid route instead of guessing a backend.

The `kamailio-pub` direct Service is required when public UDP or TCP dialogs are
enabled; rendering fails if those transports are enabled without it. Its
`external-dns.kubernetes.io/hostname` and legacy
`external-dns.alpha.kubernetes.io/hostname` annotations both use
`kamailio.instances[].publicExposure.sip.directService.hostname`, or derive
`kamailio-pub.<cluster>.<datacenter>.<region>.resolvemy.host`. The direct
UDP/TCP sockets and TOPOS Contacts advertise this identity, while TLS continues
to use the Gateway TLSRoute identity.
Its ports
follow `sip.enabled` (TLS/5061), `sip.tcpEnabled` (TCP/5060), and
`sip.udpEnabled` (UDP/5060); it never exposes private TLS/5062. Configure its
type, labels, annotations, and LoadBalancer class under
`serviceOptions.kamailio-pub`. UDP and TCP/5060 are supported only through
this direct Service; there is no Gateway UDPRoute.
The direct Service uses `externalTrafficPolicy: Local` to preserve the
carrier's source address for the ACL. Gateway TLS traffic carries the source
in PROXY protocol v2. Use the Gateway path when a direct LoadBalancer cannot
preserve the source address.

New outbound Flowroute connections are source NATed by the site's VyOS
WAN-GW/NAT VRRP pair. The hub's observed signaling source was
`66.165.222.97`; RTPEngine separately advertises `66.165.222.103` for RTP.
See [SIP identity and egress](docs/SIP-IDENTITY.md) for the distinct paths.

The shared SIP hostname remains available as a DNS alias. This prevents wildcard
bind addresses such as `0.0.0.0` from being advertised in dialog routing. Compact
Kamailio request, relay, response, rejection, and loose-route markers are
enabled by default through `kamailio.defaults.sipLogging.enabled`; the logging avoids
full SIP/SDP dumps and can be disabled for quieter production logs.
The private TLS listener/client behavior follows Kamailio's
[TLS module configuration](https://www.kamailio.org/docs/modules/stable/modules/tls.html),
and the FreeSWITCH profile uses Sofia's
[`tls-only` setting](https://developer.signalwire.com/freeswitch/users-and-endpoints/sip-profiles/)
to suppress its plain SIP socket.

RTPEngine has its own enablement toggle and can run independently of Kamailio
and FreeSWITCH. When all three components are enabled, the site-local
[RTPEngine image](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/-/packages/container/core-docker%2Frtpengine/mr13.5.1.27-build-70)
and Kamailio's [RTPEngine module](https://www.kamailio.org/docs/modules/stable/modules/rtpengine.html)
form the carrier-media proxy path. Kamailio rewrites carrier SDP through
RTPEngine's `external` and `internal` interfaces. The chart renders a public
LoadBalancer Service for RTPEngine media on enabled sites; chart users provide
provider-specific allocation and class settings through `serviceOptions`.
Each generated Service supports `serviceOptions.<service>.type`, `labels`, and
`annotations`; LoadBalancer Services also support `loadBalancerClass`. The
per-Service defaults are declared in `values.yaml`, and optional policy labels
and provider annotations remain unset unless supplied by the site values.
The advertised media identity remains `rtpengine.media.address`. The
FreeSWITCH RTP Service is omitted only when both Kamailio and RTPEngine are
enabled.
When Kamailio and RTPEngine are both enabled, their pods can run on separate
Kubernetes nodes. RTPEngine replicas remain spread across nodes by required
pod anti-affinity. The RTPEngine control Service remains cluster-routable; only
the public RTPEngine media Service uses `externalTrafficPolicy: Local`.
Kamailio fails media-bearing requests closed when RTPEngine is unavailable and
drops SDP-bearing FreeSWITCH replies if rewriting fails, so a private
FreeSWITCH pod address is never forwarded to the carrier as a fallback.
SDP reply handling runs in Kamailio's core `reply_route`, before transaction
matching and stateless forwarding. This includes late `200 OK` retransmissions
after their transaction ends. The route applies RTPEngine's body edits before
logging the rewritten SDP; a named `t_on_reply` callback alone misses those
late replies and normally cannot discard final responses. See Kamailio's
[reply routing](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#reply_route)
and [body-edit application](https://www.kamailio.org/docs/modules/6.1.x/modules/textopsx.html#textopsx.f.msg_apply_changes)
documentation. The isolated [reply regression test](tests/README.md) checks
the actual received SIP bodies, including repeated answers and rewrite errors.
With `kamailio.defaults.sipLogging.diagnostics.sdp` enabled, `SIP wire SDP answer`
records the destination and SDP connection/media lines from `$snd(buf)` in
`onsend_route`. This observes the serialized outgoing response for comparison
across retransmissions without logging SIP authentication headers.
The chart currently creates a one-shard, two-replica `ValkeyCluster` through the
[official Valkey operator](https://github.com/valkey-io/valkey-operator/tree/v0.7.0),
which is installed by the [Backplane Valkey operator ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Valkey/Operator.yaml).
External Secrets generates the Valkey ACL password once in the operator
namespace, pushes it to the site-specific Vault path, then mirrors that Vault
value into `valkey-operator-system` and `core-prod`; this keeps Valkey and
RTPEngine on the same credential across reconciliations. The generated source
secret is retained so routine chart updates do not rotate the password. The
flow uses the [External Secrets Password generator](https://external-secrets.io/latest/api/generator/password/)
and [PushSecret](https://external-secrets.io/latest/api/pushsecret/). It also
configures Valkey keyspace notifications. Two internal
[HAProxy](https://www.haproxy.org/) replicas use its
[Redis TCP health-check sequence](https://docs.haproxy.org/3.2/configuration.html#5.2-tcp-check)
to check each Valkey node with authenticated `INFO replication` and route
new Redis connections only to the node reporting `role:master`, and close
existing sessions when a node loses primary status. This adapts the
operator's all-node headless Service for RTPEngine's direct Redis client, which
does not follow Redis Cluster redirects. Call-state restoration and switchover
still require live verification after reconciliation, including RTPEngine and
Valkey node failures.
Public TLS signaling uses the configured
`sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061;transport=tls` site
route. Where enabled, UDP/TCP signaling uses the direct `kamailio-pub` Service
on port 5060 and keeps that original transport for the dialog. The active
AVoIP values enable UDP at Home1 and UDP/TCP at DC1; the private FreeSWITCH
leg remains TLS. The chart also has an
opt-in [K8GB](https://www.k8gb.io/) failover mode that references the existing
Gateway API `TLSRoute` for `sip.resolvemy.host`. The global name supports
new-call discovery; established dialogs retain the accepting site's Contact
and route set. Keep K8GB mode disabled until Backplane has
configured public DNS delegation and its authoritative provider path for the
`sip.resolvemy.host` zone. The Backplane K8GB control plane currently installs
no `Gslb` or `ZoneDelegation` resources. Its TLSRoute only serves TLS calls;
UDP/TCP calls use the direct Service, never a Gateway UDPRoute.

Kamailio is the only public SIP border. The ordinary FreeSWITCH and Asterisk
Services are private ClusterIP Services without `wan-mode: public` or
ExternalDNS records; when Kamailio and RTPEngine are enabled, FreeSWITCH's
public RTP Service is omitted. Kamailio TOPOS state uses site-local
`dragonfly-core` logical database `51` through the generated
`avoip-kamailio-topos` Secret, separate from RTPEngine's Valkey state. See the
[AVoIP boundary and HA architecture](docs/avoip/architecture.md) and
[topology-hiding design](docs/avoip/topology-hiding.md).

FreeSWITCH requests PostgreSQL credentials through its `User` claim. The current
[CoRE-Backplane PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
provisions the service-account role and database; the chart uses the generated
Secret's username and password through
[mod_cdr_pg_csv](https://developer.signalwire.com/freeswitch/module-reference/event-handlers/mod_cdr_pg_csv/)
for call-detail records. The PostgreSQL client init container creates the CDR
table before FreeSWITCH starts. FreeSWITCH operational logs continue to stream
to stdout for Kubernetes log collection.
The User claim derives the site-local Terraform and Crossplane SQL provider
names as `psql-<datacenter>-<region>`, and FreeSWITCH connects to
`psql-local.<cluster>.<datacenter>.<region>.mylogin.space`. The init container is
limited to application-table creation because the pinned SQL provider manages
PostgreSQL roles, databases, and schemas, not tables.
Sofia raw SIP tracing is enabled by default on the managed Asterisk, external,
and Kamailio-facing profiles for troubleshooting; it records SIP signaling and
SDP metadata in the FreeSWITCH logs, so disable `freeswitch.sipLogging.enabled`
when that exposure or log volume is not appropriate.

Each Kamailio-enabled cluster can deploy the internal [Homer 11 SIP monitoring](docs/HOMER.md)
stack. Kamailio forwards HEPv3 signaling directly to the Homer 11 ingest
listener, while RTPEngine forwards RTCP/NG diagnostics. The Homer UI is
protected by Authentik OIDC and Gateway Forward Auth; its HEP ports are not
publicly exposed.
Answered calls can be recorded by FreeSWITCH and played in a Homer dashboard
Iframe panel; see [Homer call audio playback](docs/HOMER-AUDIO.md) for access,
retention, and verification.
Homer uses a dedicated two-replica Longhorn RWX claim on the hub and Home1
clusters; the old RWO claims are retained without copying their traces. See
[Homer storage](docs/HOMER-STORAGE.md) for rollout and recovery details.

The mirrored `gateway` and `jitsi` values document the current merge contract.
The existing SIP routes still use their dedicated SIP Gateway sections, and
the chart’s Jitsi dependency still receives its detailed settings under
`jitsi-meet`; neither path should be assumed to consume the generic merge
metadata until its templates are changed.

## Chart state

The complete current DID flow, SIP messaging path, registration behavior, and
operational caveats are documented in [docs/PHONE-TREE.md](docs/PHONE-TREE.md).
Inbound external SIP is restricted by the Flowroute signaling CIDRs configured
under `flowroute.signalingCIDRs`; the public DID route does not
accept arbitrary Internet SIP sources.
The [SIP security probes](tests/README.md#authorization-and-outbound-call-probes)
exercise denied sources, registration, unmatched outbound destinations, and
bad private-peer credentials on an isolated deployment. Carrier DID calls use
the source ACL rather than SIP digest authentication.
FreeSWITCH voice outbound is disabled: the public context has an explicit
catch-all rejection after the configured DID route. FreeSWITCH does not
register to Flowroute; carrier signaling is accepted through Kamailio.
Flowroute SMS is enabled by default through `mod_sms` and
`mod_sms_flowroute`; its API credentials are sourced from the separate SMS
External Secret and are not stored in chart values.

The Asterisk and FreeSWITCH Deployments and Services are rendered through the
pinned [BJW-S common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
`5.0.1`, following the workload pattern used by the repository's AI stack.
The chart keeps the existing AVoIP resource names and selectors so the
migration does not create a second telephony stack. ConfigMaps, External
Secrets, SSO `User` claims, Cilium egress policy, and Gateway API routes remain
local templates because they are application-specific or operator-specific
resources not provided by the common chart.

Both voice controllers use surge-first `RollingUpdate` settings with one extra
pod allowed and zero unavailable replicas. Asterisk uses its local CLI uptime
check for startup, readiness, and liveness; FreeSWITCH uses a non-network
process/configuration check because its event socket is not enabled. Each
controller must pass startup and readiness before the old replica is removed.

Component behavior is controlled by chart values and the ApplicationSet merge:

| Component | Chart behavior | User/API resources |
| --- | --- | --- |
| Speech recognition/synthesis | External dependency | Use Wyoming from the AI stack as the protocol adapter: TTS is backed by GPUStack and STT by Speaches. |
| Asterisk | Site-controlled | When enabled, creates a rootless UID/GID 1000 workload with a service identity and ConfigMap-backed SIP configuration. Its generated User credentials are mounted only at runtime and used to authenticate the Asterisk peer to FreeSWITCH and its site-local PostgreSQL CDR database. Native `cdr_pgsql` is enabled; local CSV, SQLite, CEL, LDAP/PostgreSQL realtime, phone provisioning, audio hardware, music-on-hold, and IAX2 modules remain disabled. |
| Kamailio | Independently enabled | When enabled on a cluster, TLS SIP reaches the site's `sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061` TLSRoute and UDP/TCP SIP can reach the public direct Service on 5060. The Gateway passes TLS through; its SIPS fallback filter chain handles clients without SNI. Kamailio owns TLS, consumes Envoy PROXY protocol v2 on that path, verifies Flowroute source CIDRs, and forwards accepted SIP over TLS to its private backend. TOPOS builds each dialog Contact and route set from the carrier's initial transport. With FreeSWITCH enabled, the backend is its TLS-only private SIP edge. |
| FreeSWITCH | Site-controlled | When enabled, creates private TLS SIP services and External Secret-backed configuration. The `avoip.did` voice route remains ringing until Asterisk answers. A separate `fax.did` starts SpanDSP `rxfax`, with TIFFs stored on the configured PVC; the DID must be supplied by the site. Public media is proxied by RTPEngine. See [SIP identity and fax routing](docs/SIP-IDENTITY.md). |
| RTPEngine | Site-controlled | Runs one pinned userspace media proxy by default, exposes the configured UDP range through a LoadBalancer Service whose provider settings are supplied by chart users, and receives Kamailio NG control traffic over a private ClusterIP Service. Shared call state uses Valkey through a primary-aware HAProxy endpoint. |
| Homer 11 | Per-cluster opt-in | Runs the official all-in-one Homer 11 HEP ingest/API/UI service with persistent DuckLake/Parquet storage, local Kamailio HEPv3 capture, RTPEngine RTCP/NG capture when local RTPEngine is enabled, and Authentik-protected HTTPS access. See [HOMER.md](docs/HOMER.md). |
| Jitsi Meet | Disabled | Pinned dependency `jitsi-meet` `1.2.2`; no Jitsi resources render by default. |

The Asterisk and FreeSWITCH `User` claims use the current supported claim
shape: `spec.name`, `spec.groups`, `spec.serviceAccount`, and
`spec.writeConnectionSecretToRef`. The explicit `serviceAccount: true` records
the intended service identity, although the current SSO Composition still
hardcodes service-account creation. The current
[User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
also exposes `psql`, `s3`, `mysql`, `mongodb`, `email`, `username`, and
`AVoIP` fields. The current
[User Composition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserComposition.yaml)
does not consume `AVoIP`, `mysql`, or `mongodb`; this chart does not set those
fields.

When both voice services are enabled, FreeSWITCH authenticates the internal
Asterisk peer against the LDAP-backed directory using the username/password
from Asterisk's generated User connection Secret. The Asterisk container
creates its local PJSIP auth object at startup from mounted Secret files; the
credentials are not present in the chart ConfigMap or Helm values. FreeSWITCH
keeps Flowroute inbound traffic on its separate source-ACL-protected external
profile, so carrier ingress does not bypass application authentication. See
[PHONE-TREE.md](docs/PHONE-TREE.md) for the call paths and verification checks.

## Historical `dc1-k3s` state

A 2026-06-11 inventory showed scaled-to-zero Vosk and Mycroft resources from
an older [legacy AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml).
That inventory predates the active multi-cluster
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
and must not be treated as current controller state. The current chart does not
render those speech workloads; check Argo CD before making deletion or
recovery decisions about any remnants.

## Speech architecture and TODOs

The replacement speech path is the deployed AI stack:

- The [AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml)
  renders the shared AI services, including Wyoming, GPUStack, and Speaches.
- Wyoming is the protocol adapter on TCP `10300`. Its TTS OpenAI-compatible
  endpoint is GPUStack at `https://gpustack.mylogin.space/v1`, using
  `CoRE-AI-TTS`.
- Wyoming’s STT OpenAI-compatible endpoint is
  `https://stt.int.mylogin.space/v1`, backed by Speaches with
  `Systran/faster-whisper-small`. Speaches has CPU and CUDA backends in the AI
  chart; AVoIP must not create another Vosk or TTS deployment.
- The [AI chart documentation](https://github.com/K-FOSS/CoRE-Business/blob/main/AI/README.md)
  describes the current GPUStack, Speaches, Gateway, and Wyoming deployment.

Remaining integration work is to connect the minimal FreeSWITCH DID service to
the existing Wyoming endpoint (or an OpenAI-compatible speech bridge) if voice
TTS/STT is needed. This chart does not currently ship an IVR or speech bridge;
its old Vosk and Mycroft resources have been removed.

## Validation and activation notes

Run `helm dependency build .` to resolve the pinned local dependency, then run
`helm lint .`. For representative standalone checks, render once with the
`dc1-k3s-node1` defaults and once with the injected `cluster`, `hub`,
`gateway`, and `jitsi` values. Before activating Jitsi, render through the
same Lovely pipeline used by the owning ApplicationSet.

Before enabling Asterisk or FreeSWITCH, inspect the chart’s External Secret
references and the cluster’s SecretStore configuration. Asterisk's static
PJSIP configuration is a ConfigMap; only its generated `User` connection
Secret contains runtime credentials. Do not put credentials or generated
Secret data in this repository. Verify the resulting `User`, its `XUser`, the
claim connection Secret key names, and downstream provider conditions. The
current SSO platform documentation is the authoritative guide
for this workflow: [User platform APIs](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/README.md).

## Nextcloud Talk high performance backend

The chart runs the versioned
[Nextcloud AIO Talk image](https://github.com/nextcloud/all-in-one/tree/main/Containers/talk)
on `core-home1-talos-prod`, alongside the Office deployment. The image bundles
the standalone [Talk signaling server](https://github.com/strukturag/nextcloud-spreed-signaling),
[Janus](https://github.com/meetecho/janus-gateway), NATS and eturnal. The
public signaling endpoint is `https://talk.mylogin.space` through the
Home1 Gateway. `talk-media.mylogin.space:3478` is a separate public
`kube-vip` LoadBalancer for TCP/UDP TURN media. The latter resolves before the
pod starts so the bundled media services can advertise the public address;
TLS TURN on port 5349 is not exposed.

The backend reads the existing site TURN REST secret from the
[NATPuncher Vault path](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/NATPuncher.yaml).
ESO generates stable signaling and internal secrets in the `avoip-talk-hpb-bootstrap`
Secret; the TURN secret is mirrored into `avoip-talk-hpb-turn`. The credentials
are never rendered into manifests. The Nextcloud Talk admin settings still
need the signaling URL and `SIGNALING_SECRET`, plus TURN at
`talk-media.mylogin.space:3478` over UDP and TCP with shared-secret
authentication using `TURN_SECRET` and the TURN-only mode. Configure
`office.mylogin.space` as the
backend's Nextcloud host. Retrieve secret values through the approved secret
handling workflow; do not print them into logs or shell history.

The signaling and internal credentials are pushed to the Vault key
`AVoIP/Talk/YVR/Home1/Creds` and remain there when the AVoIP release is
removed. Delete or rotate them only after updating the Nextcloud Talk settings;
rotation restarts HPB and ends active calls.

After the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
reconciles, verify both public DNS records, the Home1 Gateway route, the media
LoadBalancer address, ExternalSecret readiness, and the HPB health check. In
Nextcloud, confirm the HPB check is green and test a multi-participant call from
outside the Home1 network. A rollout restarts signaling, Janus and eturnal and
will end active calls. Roll back by disabling `talkHpb.enabled`; remove the
Nextcloud Talk configuration separately only if the backend is being retired.

Principal upstream projects:

- [Asterisk](https://www.asterisk.org/) and its
  [documentation](https://docs.asterisk.org/)
- The deployed Asterisk image is the `core-docker/asterisk:20.21.0` package
  from the site-local [Core-Docker project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker),
  built from the upstream [andrius/asterisk image source](https://github.com/andrius/asterisk).
  This Asterisk 20 release provides PJSIP's `external_signaling_hostname`;
  the upstream [20.21.0 release notes](https://downloads.asterisk.org/pub/telephony/asterisk/ChangeLog-20.21.0.html)
  describe the release. Backups are maintained at
  [GitHub](https://github.com/K-FOSS/Core-Docker) and
  [slop.writemy.codes](https://slop.writemy.codes/CoRE/Core-Docker).

- [FreeSWITCH](https://signalwire.com/freeswitch) and its
  [source repository](https://github.com/signalwire/freeswitch)
- [Sipwise RTPEngine](https://github.com/sipwise/rtpengine) and its
  [configuration documentation](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md)
- [Wyoming OpenAI adapter](https://github.com/roryeckel/wyoming_openai)
- [GPUStack website](https://gpustack.ai/) and
  [documentation](https://docs.gpustack.ai/)
- [Speaches website and documentation](https://speaches.ai/) and
  [source repository](https://github.com/speaches-ai/speaches)
- [Jitsi Meet](https://jitsi.org/) and the
  [Jitsi Helm chart](https://github.com/jitsi-contrib/jitsi-helm)
- [Nextcloud AIO Talk image and deployment](https://github.com/nextcloud/all-in-one/tree/main/Containers/talk)
  and [Nextcloud Talk quick install and administration settings](https://nextcloud-talk.readthedocs.io/en/latest/quick-install/)

### Internal Asterisk SIP identity

The internal Asterisk PJSIP TLS transport advertises the generated Asterisk
Service FQDN from `avoip.sip.serviceHost`; its cert-manager Certificate uses
the same hostname as a DNS SAN. FreeSWITCH continues to target that Service
identity on TLS/5061. The pod template hashes the rendered PJSIP ConfigMap and
also watches it with Stakater Reloader so transport changes restart Asterisk,
which is required to apply PJSIP transport options. The transport does not set
`local_net`: Asterisk otherwise classifies the FreeSWITCH pod as local and
skips external signaling Contact rewriting for that peer. No external media
address is configured, so this identity change does not rewrite SDP.

For a deployed call-path check, inspect Asterisk's version and effective
transport, then verify the certificate from the FreeSWITCH pod's `netshoot`
container (replace the example site name as appropriate):

```sh
kubectl -n core-prod exec deploy/<asterisk-deployment> -c asterisk -- \
  asterisk -rx 'core show version'
kubectl -n core-prod exec deploy/<asterisk-deployment> -c asterisk -- \
  asterisk -rx 'pjsip show transport transport-tls'
kubectl -n core-prod exec deploy/<freeswitch-pod> -c netshoot -- \
  openssl s_client \
    -connect 'core-dc1-talos-prod-business-avoip-prod-avoip-asterisk.core-prod.svc.k3s.dc1.resolvemy.host:5061' \
    -servername 'core-dc1-talos-prod-business-avoip-prod-avoip-asterisk.core-prod.svc.k3s.dc1.resolvemy.host' \
    -verify_return_error
```

With Asterisk PJSIP and FreeSWITCH Sofia SIP tracing enabled for one controlled
internal test call, verify FreeSWITCH's INVITE is followed by Asterisk's 200 OK
with the Asterisk Service FQDN in Contact, then a FreeSWITCH ACK. Repeated 200
OK retransmissions and an approximately 32-second ACK timeout indicate the
dialog still is not established; pod readiness alone is not acceptance.
The chart-level identity assertions can be run with
`bash tests/asterisk-tls-identity.sh`.
