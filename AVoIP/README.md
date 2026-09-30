# AVoIP

This chart is the desired state for the AVoIP stack in `core-prod` while it
moves from legacy ownership toward WIP production status. It is not yet a
production-certified replacement: the live hub is the active validation
environment, and the legacy ApplicationSet remains the deployment owner until
the production-readiness gates below are closed. It
contains optional Asterisk and FreeSWITCH workloads plus an optional Jitsi Meet
dependency. Speech recognition and synthesis are provided by the existing
[CoRE AI stack](https://github.com/K-FOSS/CoRE-Business/tree/main/AI), not by
workloads duplicated in this chart. It does not currently expose a public HTTP
route from this chart.

## Lifecycle status: legacy to WIP production

The stack is in a controlled WIP-production transition. `core-dc1-talos-prod`
is the active hub validation environment; the other ApplicationSet targets are
spokes and do not currently run the telephony components. The deployed owner is
still the [legacy AVoIP ApplicationSet in CoRE-Backplane](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml),
so “WIP production” describes the maturity target, not a completed ownership
migration.

Current transition state:

- Desired voice path: Flowroute → Kamailio → RTPEngine → FreeSWITCH →
  Asterisk for ordinary calls.
- Fax validation is in progress with FreeSWITCH `mod_spandsp`, G.711 fallback,
  T.38 passthrough, and per-cluster Homer capture.
- Configuration changes roll out through Git, Argo CD, and Reloader-backed
  Deployment updates. Direct cluster changes are incident diagnostics only and
  must not become the lasting source of truth.
- The legacy `dc1-k3s` speech remnants are retirement candidates and are not a
  supported telephony backend.

The following gates remain before treating the stack as production-ready:

1. Complete real Flowroute fax tests, including a FreeSWITCH T.38 re-INVITE,
   Flowroute acceptance, a received TIFF, and a successful result.
2. Demonstrate that ordinary inbound voice calls continue to bridge to
   Asterisk during and after fax testing.
3. Resolve the Kamailio UDP worker stability issue. The current evidence shows
   `recvfrom(): [103] Software caused connection abort`, worker exit status 255,
   and parent shutdown. This occurred during a burst of thousands of SIP
   messages and has not been proven to originate from T.38 signaling.
4. Reduce or account for the high-volume internal REGISTER/INVITE traffic and
   verify the node/Cilium/conntrack path during a recurrence.
5. Reconcile the desired multi-cluster ApplicationSet and confirm the rendered
   Lovely output, operator conditions, routes, persistence, and rollback path.

Until these gates are closed, changes should be described as WIP production
validation and not as a stable general-purpose AVoIP release.

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

The [owning ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
uses `targetRevision: HEAD`, enables `CreateNamespace=true` and
`ServerSideApply=true`, and injects the following Helm merge values:

- `env`, `datacenter`, `region`, and `cluster` identity/type/domain metadata.
- `asterisk.enabled`, `kamailio.enabled`, `freeswitch.enabled`,
  `rtpengine.enabled`, and public exposure settings per cluster. RTPEngine is
  independently deployable; media integration is conditional on the relevant
  SIP workloads also being enabled.
- `hub` metadata for spoke clusters.
- `gateway.name`, `gateway.namespace`, and `gateway.sectionName`.
- `jitsi.domain` and `jitsi.tls.secretName`.

The current component matrix is:

| Cluster | Role | Asterisk | FreeSWITCH |
| --- | --- | --- | --- |
| `core-dc1-talos-prod` | Hub | Enabled | Enabled |
| `core-home1-talos-prod` | Spoke | Disabled | Disabled |
| `dc1-k3s-node1` | Spoke | Disabled | Disabled |

The chart’s top-level `values.yaml` contains the same single-cluster defaults
for standalone rendering, with both telephony components disabled. The
current [owning ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
overrides those flags only for the hub. Lovely-injected values take precedence
for each selected cluster. The live `dc1-k3s` controller is stale: it still
has the older single-cluster ApplicationSet and the application was last
observed at revision `f043ea6e783e1655db2a1456ad2a2c5b575479cf`, with Argo
reporting `Synced` and `Healthy` on 2026-06-11. Its old speech resources remain
pending the newer ApplicationSet/chart reconciliation.

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
private backend. Kamailio applies
[symmetric response routing](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#force_rport)
to Flowroute requests so answers use the received TLS source port even when
the carrier's Via advertises 5061. Kamailio and FreeSWITCH can be enabled independently; when
both are enabled, the default Kamailio backend is FreeSWITCH's private TLS-only
SIP profile on port 5061. Kamailio uses an explicit two-sided Record-Route
preset for the asymmetric edge: the internal route is Kamailio's private TLS
Service on port 5062 and the external TLS route is the site's
`sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061` identity. The private
Record-Route remains on the FreeSWITCH leg, while Kamailio removes that private
header from replies toward Flowroute so the carrier receives only the
site-specific public route. Both sites can use the same DIDs through separate
site-local value/secret injection; the site-specific dialog route keeps each
call's signaling anchored to the site that accepted it. This supports YVR
primary/YXL failover for new calls, while established dialogs remain local to
their original site. After `loose_route()` handles the public route,
carrier-originated in-dialog requests are sent to FreeSWITCH over the private
TLS service. Successful public 2xx
Contacts preserve their called user while using the originating site's SIPS
host. FreeSWITCH uses that site host as its external SIP identity as well.
Every in-dialog request, including 2xx ACK, follows `loose_route()`; Kamailio
does not special-case ACK or guess a backend when a dialog Route header is
missing.
The shared SIP hostname remains available as a DNS alias. This prevents wildcard bind
addresses such as `0.0.0.0` from being advertised in dialog routing. Compact
Kamailio request, relay, response, rejection, and loose-route markers are
enabled by default through `kamailio.sipLogging.enabled`; the logging avoids
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
With `kamailio.sipLogging.diagnostics.sdp` enabled, `SIP wire SDP answer`
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
Public signaling is TLS-only. By default, Flowroute targets the configured
`sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061;transport=tls` site
route, and that site hostname remains the dialog identity. The chart now has an
opt-in [K8GB](https://www.k8gb.io/) failover mode that references the existing
Gateway API `TLSRoute` for `sip.resolvemy.host`; when enabled, Kamailio advertises that global name in
the public listener, Record-Route, and Contact while each site continues to
publish its site-local route. Keep K8GB mode disabled until Backplane has
configured public DNS delegation and its authoritative provider path for the
`sip.resolvemy.host` zone. The Backplane K8GB control plane currently installs
no `Gslb` or `ZoneDelegation` resources. Kamailio's UDP listener remains
private for the FreeSWITCH leg and is not exposed through a LoadBalancer or
UDPRoute.

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

The chart defaults are intentionally mostly inactive:

| Component | Chart behavior | User/API resources |
| --- | --- | --- |
| Speech recognition/synthesis | External dependency | Use Wyoming from the AI stack as the protocol adapter: TTS is backed by GPUStack and STT by Speaches. |
| Asterisk | Disabled | When enabled, creates a rootless UID/GID 1000 workload with a service identity and ConfigMap-backed SIP configuration. Its generated User credentials are mounted only at runtime and used to authenticate the Asterisk peer to FreeSWITCH and its site-local PostgreSQL CDR database. Native `cdr_pgsql` is enabled; local CSV, SQLite, CEL, LDAP/PostgreSQL realtime, phone provisioning, audio hardware, music-on-hold, and IAX2 modules remain disabled. |
| Kamailio | Independently enabled | When enabled on a cluster, Kamailio receives public SIP on that site's `sip.<cluster>.<datacenter>.<region>.resolvemy.host:5061` TLSRoute. The Gateway passes TLS through; its SIPS fallback filter chain handles clients without SNI. Kamailio owns TLS, consumes Envoy PROXY protocol v2, verifies Flowroute source CIDRs, and forwards accepted SIP over TLS to its private backend. With FreeSWITCH enabled, that backend defaults to FreeSWITCH's TLS-only private SIP edge. |
| FreeSWITCH | Disabled | When enabled, creates private TLS SIP services and External Secret-backed configuration. The `avoip.did` voice route remains ringing until Asterisk answers and has no fax detector. A separate `fax.did` sends 180 Ringing for 2 seconds before answering and starting SpanDSP `rxfax`, with TIFFs stored on the configured PVC; the DID must be supplied by the site. Public media is proxied by RTPEngine. See [SIP identity and fax routing](docs/SIP-IDENTITY.md) and [RTP-DIAGNOSTICS.md](docs/RTP-DIAGNOSTICS.md). |
| RTPEngine | Hub-only toggle | Runs two pinned userspace media proxies, exposes the configured UDP range through a LoadBalancer Service whose provider settings are supplied by chart users, and receives Kamailio NG control traffic over a private ClusterIP Service. Shared call state uses Valkey through a primary-aware HAProxy endpoint. |
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

## Live `dc1-k3s` snapshot

The following is a non-secret inventory captured from the live cluster. Secret
objects, secret data, environment values sourced from Secrets, and generated
credentials are deliberately excluded.

The active Argo application is
`dc1-k3s-node1-business-avoip` in `argocd`, targeting `core-prod`. Its complete
resource inventory is only:

- Deployment `dc1-k3s-node1-business-avoip-avoip-vosk`, `0` replicas,
  image `alphacep/kaldi-en:latest`, container HTTP port `2700`.
- Service `dc1-k3s-node1-business-avoip-avoip-vosk`, ClusterIP, TCP and UDP
  port `5060`, both targeting the container ports named `tcp-sip` and
  `udp-sip`.
- Deployment `dc1-k3s-node1-business-avoip-avoip-mycroft-mimic`, `0` replicas,
  image `smartgic/ovos-tts-server-bark:alpha`, container HTTP port `9666`, and
  an `emptyDir` mounted at `/home/mimic3/.local`.
- Service `dc1-k3s-node1-business-avoip-avoip-mycroft-mimic`, ClusterIP port
  `80` targeting the `http` port.

No Asterisk, FreeSWITCH, Jitsi, `User`, HTTPRoute, TLSRoute, or UDPRoute
resource is currently part of this Argo application. The live speech
resources are scaled to zero, matching the chart’s replica settings.

These speech resources are legacy remnants. The chart no longer renders them;
the next Argo reconciliation will prune them. Until that reconciliation, they
remain visible in the live snapshot above and must not be treated as supported
speech backends.

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

## Documented chart/live differences

These differences are intentional or unresolved and should be reviewed before
activating a component:

1. The legacy live Vosk Service exposes TCP/UDP SIP port `5060` and targets port
   names that do not exist on the Vosk Deployment. The Deployment exposes only
   HTTP port `2700`. Because replicas are zero and Vosk is being retired, no
   repair is planned; the Service will be pruned on reconciliation.
2. The legacy live Vosk image is the mutable `alphacep/kaldi-en:latest` tag;
   it is being retired rather than pinned or reactivated.
3. The legacy live OVOS TTS Deployment has `imagePullPolicy: Always`; it is
   also being retired rather than reconciled back into this chart.
4. The live application is rendered from an older revision of the [legacy ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml), while the current desired ApplicationSet is multi-cluster and injects Helm values. Compare the rendered Lovely output after every chart change; standalone `helm template` is only a partial check for this deployment.

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

Principal upstream projects:

- [Asterisk](https://www.asterisk.org/) and its
  [documentation](https://docs.asterisk.org/)
- The deployed Asterisk image is the pinned `core-docker/asterisk:20` package
  from the site-local [Core-Docker project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker),
  built from the upstream [andrius/asterisk image source](https://github.com/andrius/asterisk).
  The digest is maintained in `values.yaml`; backups are maintained at
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
