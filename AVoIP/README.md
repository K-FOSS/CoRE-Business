# AVoIP

This chart is the site-specific desired state for the AVoIP stack in `core-prod`.
The [SIP, identity, and RTC architecture plan](docs/SIP-STATEFUL-HA.md) and its
[phased TODO tracker](TODO.md) describe proposed stateful routing, web phone,
directory switchboard, MatrixRTC and native calling work, with evidence gates
and rollback. They do not change the deployed call path.
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
deploys it to the DC1 hub, Home1, and the `dc1-k3s-node1` spoke. DC1 and Home1
enable the telephony workloads; `dc1-k3s-node1` does not enable Asterisk
or FreeSWITCH. Speech recognition and synthesis are provided by the existing
[CoRE AI stack](https://github.com/K-FOSS/CoRE-Business/tree/main/AI), not by
workloads duplicated in this chart. Homer has an Authentik-protected web route
where enabled.

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
  LiveKit is enabled for Home1/YVR; DC1/YXL and `dc1-k3s-node1` stay
  disabled. LiveKit uses pod networking; its UDP and TCP media ports are
  exposed only through the site media LoadBalancer.
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

Home1/YVR fax reception has been reported working over G.711. The owning
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
sets `freeswitch.fax.g711Only.enabled: true` for that site, which disables
T.38 negotiation on its dedicated `fax.did` route and selects PCMU. T.38 has
not worked in YVR; DC1/YXL retains the chart's T.38-capable default. The
reported result does not establish SIP ACK delivery, fax page count, or TIFF
retention without a call-specific trace. See the [current fax call path](docs/PHONE-TREE.md).

## Components and security

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

| Component | Current role | More detail |
| --- | --- | --- |
| Asterisk | Private voice PBX; authenticates to FreeSWITCH over TLS with Secret-backed SIP Digest credentials, records CDRs in site-local PostgreSQL, and transfers extension 66 to FreeSWITCH's `gg-audio` dialplan user. | [Call path](docs/PHONE-TREE.md), [Home Assistant SIP Core and GG audio](docs/SIPCORE-HASS.md), [internal TLS check](#internal-asterisk-sip-identity) |
| Kamailio | Public carrier SIP border and private TLS relay with TOPOS. | [Values](docs/KAMAILIO-VALUES.md), [SIP identity](docs/SIP-IDENTITY.md) |
| FreeSWITCH | Private call control, voice DID, fax `rxfax`, and Secret-backed configuration. | [Call path](docs/PHONE-TREE.md), [fax verification](docs/SIP-IDENTITY.md) |
| RTPEngine | Public media anchor with private NG control and Valkey recovery state. | [RTPEngine HA](docs/avoip/rtpengine-ha.md) |
| Homer 11 | Internal HEP capture and Authentik-protected UI where enabled. | [Homer](docs/HOMER.md), [audio playback](docs/HOMER-AUDIO.md) |
| LiveKit | Independent WebRTC signaling and media stack on Home1/YVR. | [LiveKit deployment](docs/LIVEKIT.md) |
| Speech | External dependency from the AI stack; no local Vosk or Mycroft workload. | [Speech architecture](#speech-architecture-and-todos) |
| Jitsi Meet | Pinned dependency, disabled by default. | [Upstream chart](https://github.com/jitsi-contrib/jitsi-helm) |

The Asterisk and FreeSWITCH `User` claims set `spec.name`, `spec.groups`,
`spec.serviceAccount`, and `spec.writeConnectionSecretToRef`. Review the
[User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
and [Composition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserComposition.yaml)
together before changing identity or database behavior; this chart also uses
the supported PostgreSQL claim fields.

The application `User` claims remain responsible for their existing
application identity and database connection needs. FreeSWITCH SIP peer Digest
credentials use a separate random External Secrets generated password, mounted
as a Secret to Asterisk and FreeSWITCH; it is not sourced from a User resource,
ConfigMap, or Helm value. FreeSWITCH keeps Flowroute inbound traffic on its
separate source-ACL-protected external profile, so carrier ingress does not
bypass application authentication. See [PHONE-TREE.md](docs/PHONE-TREE.md)
for the call paths and verification checks. The LDAP-backed FreeSWITCH
directory is temporarily disabled by default with `freeswitch.ldap.enabled`;
dynamic directory users are unavailable until it is re-enabled after the
authentication lookup failure is resolved.

The Asterisk `freeswitch` endpoint is identified by its SIP username and
authenticates inbound requests with SIP Digest. An External Secrets Password
generator creates a random peer password in an immutable, retained Secret
referenced by both Asterisk and FreeSWITCH; no internal pod IP or cluster CIDR
is used as identity. Asterisk's existing outbound auth remains configured.
Raw SIP packet traces are suppressed on the authenticated peer path so Digest
Authorization headers are not written to logs. See
[SIPCORE-HASS.md](docs/SIPCORE-HASS.md) for endpoint identification and the
WebSocket transport boundary.

## SIP signaling and media

The deployed FreeSWITCH image comes from the site-local
[Core-Docker image definition](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker/src/branch/main/Images/FreeSwitch)
and is pinned to an immutable Forgejo build tag. The carrier border uses the
[Kamailio SIP server](https://www.kamailio.org/) from its
[official container images](https://github.com/kamailio/kamailio-docker).
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
sets the site identity, carrier transport exposure, and media address.

Public TLS/5061 passes through Envoy Gateway to Kamailio's native TLS socket;
Envoy adds PROXY protocol v2 so Kamailio can enforce the Flowroute source ACL.
Home1 also exposes direct UDP/5060 through kube-vip. DC1 exposes direct
UDP/5060 and TCP/5060 through PureLB. The direct Service preserves the source
address with `externalTrafficPolicy: Local`. Kamailio's private listener is
TLS/5062; it sends accepted calls to FreeSWITCH over TLS/5061 and uses TOPOS
state in Dragonfly database `51`. Its carrier-facing Contact and route set retain
the original public transport; the private backend address is hidden.
A 2xx ACK follows the restored dialog route, including when it reaches a
different Kamailio replica. This routing still needs live verification.

The public TLS gateway depends on the
[Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml).
Its SIPS fallback supports clients without SNI. New outbound carrier requests
use the site's VyOS NAT egress. See [SIP identity and call verification](docs/SIP-IDENTITY.md)
for the exact Contact, Record-Route, ACK, TLS, Gateway, and egress behavior.
The [Kamailio values reference](docs/KAMAILIO-VALUES.md) explains listener,
Service, TOPOS, and logging options. The
[boundary architecture](docs/avoip/architecture.md) separates current
site-local dialogs from proposed cross-site failover.

The [Sipwise RTPEngine](https://github.com/sipwise/rtpengine) anchors public
RTP independently of SIP signaling. Its
[RTPEngine configuration](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md)
uses the site-specific media address and UDP range supplied by the owning
ApplicationSet. Kamailio fails closed if RTPEngine cannot handle a media-bearing
request or SDP reply; it does not expose private FreeSWITCH SDP as a fallback.
The public media LoadBalancer uses the site's provider settings under
`serviceOptions`. FreeSWITCH's own public RTP Service is omitted when both
Kamailio and RTPEngine are enabled. The chart's one-shard Valkey store and
primary-aware HAProxy endpoint support RTPEngine state recovery, but live
switchover and existing-call media continuity remain unverified. See
[RTPEngine HA and recovery](docs/avoip/rtpengine-ha.md) and the
[reply regression scenarios](tests/README.md).

The opt-in [K8GB](https://www.k8gb.io/) mode uses a global TLSRoute for
`sip.resolvemy.host` to select a site for new calls. It is disabled until
Backplane's public DNS delegation and authoritative provider path are ready.
Established dialogs keep the accepting site's Contact and route set; UDP/TCP
signaling continues through the site's direct Service.

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

## Named Kamailio instances

The [Kamailio values reference](docs/KAMAILIO-VALUES.md) lists every supported
option, default, role constraint, and site override. The active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
provides a complete `kamailio.instances` array at each site. The three
sites retain the named `carrier` instance with three replicas. YVR also enables
one `internal` instance with the `private-sbc` role; DC1 configurations remain
carrier-only. An instance receives `defaults`, then its role defaults, then its
own overrides. Site Helm values replace the entire instances array.

The `carrier-sbc` role preserves the existing public SIP border and private
TLS backend. An opt-in `private-sbc` instance now has its own TLS/5062 Service,
Deployment, certificate, TOPOS Secret, Cilium policy, and routing script. It
requires a verified client certificate and an explicitly listed peer address
and certificate DNS SAN. Exact extension rules select probed dispatcher
destinations; unmatched requests and, by default, `REGISTER` fail closed. It does not load
RTPEngine or forward to Flowroute. Unlike the carrier role, direct private
connections do not require an Envoy PROXY header. The private role is limited
to one replica until dialog affinity is tested. See the [Kamailio values](docs/KAMAILIO-VALUES.md).

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
now enables one `private-sbc` instance in YVR beside the existing carrier
instance; the operator reports that the first pieces are live. Its rollout and
SIP behavior have not yet been independently verified here. The carrier's
existing private listener still uses its current CIDR guard for dialog
traffic; new calls from that listener receive 403. An
[opt-in outbound service-peer pilot](docs/OUTBOUND-PILOT.md) now uses the
existing Gateway and a dedicated SNI/mTLS profile, exact test extension and
destination, fixed caller ID, carrier-owned RTPEngine path, and shared
rate/concurrency quotas. It is disabled at both sites and has not passed a
live carrier call. No registrar, WSS endpoint or OIDC webphone is deployed.

The [internal registrar integration contract](docs/INTERNAL-REGISTRAR.md)
records an opt-in private registrar implementation: a dedicated PostgreSQL
`User` claim and migration Job, Digest-checked REGISTER and initial INVITE,
and exact pilot AoR policy. The database filters expired/disabled verifiers
and purges contacts on revocation or HA1 rotation. It has passed render,
isolated database and Kamailio syntax checks, not live registration.
Credential issuance and Authentik-driven revocation, NAT/WSS connection
ownership, and the browser phone are still pending. The registrar remains
disabled in the YVR configuration. Enabling the private SBC does not enable
registration, create SIP subscribers, or prove that its database claim has
been provisioned.

The chart also includes a disabled-by-default SIP Core WebRTC path for the
[SIP Core Home Assistant integration](https://github.com/TECH7Fox/sipcore-hass-integration).
It provisions static PJSIP extensions from External Secrets, serves WSS through
Envoy to the selected private Kamailio instance, and allows only exact
configured internal destinations. Carrier and FreeSWITCH fax signaling stays
on the separate carrier instance. The private instance relays signaling to
Asterisk over TLS and controls the existing RTPEngine for the Home Assistant
media leg. The enabled pilot is site-specific; inspect the owning ApplicationSet
before changing its rollout values. See
[SIPCORE-HASS.md](docs/SIPCORE-HASS.md).

Run `tests/kamailio-instances.sh`, `tests/sip-registrar-render.sh`, `tests/sip-outbound-render.sh`, and
`tests/sip-security-render.sh` before
publishing a change. Review the rendered carrier selector, public Contact,
source ACL, and private target before scoped Argo CD reconciliation. For live
acceptance, correlate one Call-ID across both Kamailio legs and FreeSWITCH:
require the 2xx ACK at FreeSWITCH, a call lasting beyond 60 seconds, and
BYE/200 completion. Check fax completion separately. Roll back both the chart
and owning ApplicationSet values if a site instance change must be reverted.

## LiveKit Server

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
enables LiveKit for Home1/YVR. It has its own HTTPS signaling route and
public UDP/TCP media Service; it does not share Kamailio or RTPEngine media.
The rendered configuration uses site-local TLS Dragonfly, Secret-backed API
keys, and a separate public address. External media reachability still needs
verification after reconciliation. See [LiveKit deployment, prerequisites,
verification, and recovery](docs/LIVEKIT.md).

## Asterisk WebRTC media relay candidates

The [Asterisk RTP/ICE configuration](https://docs.asterisk.org/Configuration/Miscellaneous/Interactive-Connectivity-Establishment-ICE-in-Asterisk/)
uses the existing [CoTURN](https://github.com/coturn/coturn) service at
`nat.mylogin.space:3478` for STUN discovery and TURN relay candidates. Its
[REST shared secret](https://github.com/coturn/coturn/blob/master/README.turnserver)
is mounted directly from the existing `matrix-turn-auth` Secret created by
Social/Matrix. Asterisk derives a time-limited TURN username/password at
startup and stores the generated include only in its runtime `/tmp`; no
credential is rendered into a ConfigMap or Helm values. The credential lifetime
is configurable up to one year, so restart Asterisk before the expiry.

This provides ICE candidates for Asterisk's media socket. The Home Assistant
signaling path remains WSS through Envoy and Kamailio, and browser media remains
relayed through the existing RTPEngine. CoTURN does not replace RTPEngine or
provide credentials to the browser. See
[the SIP Core media notes](docs/SIPCORE-HASS.md#media-reachability) before
diagnosing two-way audio.

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

## Internal Asterisk SIP identity

The internal Asterisk PJSIP TLS transport sets the generated Asterisk Service
FQDN from `avoip.sip.serviceHost` as
[`external_signaling_address`](https://docs.asterisk.org/Latest_API/API_Documentation/Module_Configuration/res_pjsip/);
its cert-manager Certificate uses the same hostname as a DNS SAN. FreeSWITCH
continues to target that Service identity on TLS/5061. The pod template hashes the rendered PJSIP ConfigMap and
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
kubectl -n core-prod exec deploy/<freeswitch-deployment> -c netshoot -- \
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

## Historical `dc1-k3s` state

A 2026-06-11 inventory showed scaled-to-zero Vosk and Mycroft resources from
an older [legacy AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml).
That inventory predates the active multi-cluster
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
and must not be treated as current controller state. The current chart does not
render those speech workloads; check Argo CD before making deletion or
recovery decisions about any remnants.

## Verification and activation

The chart is deployed. YVR G.711 fax reception is reported working, while
the end-to-end voice and failover paths still need live verification:

1. Confirm an inbound Flowroute INVITE receives an ACK at FreeSWITCH and stays
   up for at least 60 seconds. The prior approximately 32-second `ACK Timeout`
   is reported resolved; one [operator-correlated 129-second call](docs/SIP-IDENTITY.md)
   had a complete recording. Retain a Call-ID-correlated ACK and clean BYE/200
   trace as acceptance evidence. See [SIP identity and call verification](docs/SIP-IDENTITY.md).
2. Verify an ordinary voice call bridges to Asterisk. For YVR fax, capture
   the `rxfax` result, TIFF, G.711 mode, and ACK on both SIP hops. Test T.38
   separately before enabling it there. Verify YXL fax independently.
3. Exercise site failover and the RTPEngine/Valkey recovery path before treating
   either as production verified.

Changes flow through Git and Argo CD; Reloader restarts workloads when their
watched configuration changes.

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

## Upstream projects

- [Asterisk](https://www.asterisk.org/) and its
  [documentation](https://docs.asterisk.org/)
- The deployed Asterisk image is currently `core-docker/asterisk:20.20.1` from
  the `core-docker/asterisk:20` tag, from the site-local
  [Core-Docker project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker),
  built from the upstream [andrius/asterisk image source](https://github.com/andrius/asterisk).
  It uses PJSIP's compatible `external_signaling_address` option;
  `external_signaling_hostname` is introduced in
  [Asterisk 20.21.0](https://downloads.asterisk.org/pub/telephony/asterisk/ChangeLog-20.21.0.html).
  Backups are maintained at
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
