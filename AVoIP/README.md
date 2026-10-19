# AVoIP

[AVoIP administration](docs/ADMIN.md) provides group-aware SMS administration,
multiple messaging accounts and a managed SIP provider/DID/caller-ID catalog.
Its Extensions screen controls outbound enablement, verified caller ID, provider,
and egress site; disabled decisions are sent to Homer. Routing activation is
independent of UI enablement. Both interfaces follow the
[shared Material Design 2 specification](docs/UI-DESIGN.md).

The proposed [CoRE Caller Intelligence & Call Protection](docs/caller-intelligence/README.md)
package documents number/business policies, reputation, lookup budgets, APIs and
a future Kamailio bridge. It adds no running service or telephony configuration.

YXL voice/IVR calls ring and immediately enter the answering IVR
on their authenticated YVR ingress. See the [phone tree](docs/PHONE-TREE.md)
for the scoped timing value and verification procedure.

SIP Core relays SIP INFO DTMF to Asterisk through the validated dialog path;
only an exact trickle ICE media type enters RTPEngine's fragment handler. See
[DTMF routing, regression checks and ACK verification](docs/SIPCORE-DTMF.md)
for the Kamailio MIME parser caveat and live acceptance procedure.

Inbound Flowroute SMS has its own Go HTTP receiver, PostgreSQL-backed message
and MMS image storage, and public callback route. An optional Authentik proxy
inbox filters messages by user and group number attributes. The primary-region
Authentik workspace also manages the `AVoIP Users` and `AVoIP Admins` groups;
assign people to those groups in Authentik. `AVoIP Admins` is an application
access group and does not grant Authentik superuser privileges. The inbox
allows either group. See the
[Flowroute SMS guide](docs/FLOWROUTE-SMS.md) for scaling, data handling,
deployment inputs and verification.
The `AVoIP Admins` desired state declares `voip@snd.fyi`,
`voip@resolvemy.host` and `voip@writemy.codes` as separate values in its
`mailacceptinggeneralid` LDAP attribute for Postfix group alias expansion.
Runtime alias resolution still requires LDAP-backed verification. Its existing
attributes, including shared `sms_numbers`, are retained when these values are
reconciled.
For inbound-call ACKs or remote BYEs rejected after a retransmitted answer,
see the [SIP Core Contact alias repair](docs/SIPCORE-REMOTE-HANGUP.md).

The current Home1 SIP Core Gateway contract and its one-hour connection
duration constraint are documented in the
[SIP HA integration baseline](docs/SIP-STATEFUL-HA.md#sip-core-wss-integration-baseline-observed-2026-10-09).
The chart supports a separate `internal-wss` Kamailio instance for the opt-in
three-replica WSS edge. The ordinary `internal` private-SBC remains its own
one-replica Deployment. Home1's active ApplicationSet uses the instance name
`internal-websocket` for its three-replica WSS edge and retains `internal` as
the one-replica private-SBC. See the
[HA rollout guide](docs/SIP-STATEFUL-HA.md#implemented-wss-edge-mode) for the
current topology and connection-owner behavior.

This chart is the site-specific desired state for the AVoIP stack in `core-prod`.
The [SIP, identity, and RTC architecture plan](docs/SIP-STATEFUL-HA.md) and its
[phased TODO tracker](TODO.md) describe proposed stateful routing, web phone,
directory switchboard, MatrixRTC and native calling work, with evidence gates
and rollback. They do not change the deployed call path.
The active [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
deploys it to the DC1 hub, Home1, and the `dc1-k3s-node1` spoke. DC1 and Home1
enable the telephony workloads; `dc1-k3s-node1` does not enable Asterisk
or FreeSWITCH. Speech recognition and synthesis are provided by the existing
[CoRE AI stack](https://github.com/K-FOSS/CoRE-Business/tree/main/AI), not by
workloads duplicated in this chart. Homer has an Authentik-protected web route
where enabled.

Enabled Asterisk and FreeSWITCH stacks share a retained `ReadWriteMany` sound
library on the existing `avoip-homer-rwx` Longhorn class. The recorder/editor
is available at `/audio-library/` on Homer's hostname behind the existing
Authentik `Home Users` authorization. Each cluster has its own volume. See the
[sound library guide](docs/avoip/sound-library.md) for formats, PBX paths,
retention and verification.

The dedicated WSS edge has an opt-in, exact LF/LF heartbeat compatibility
patch for Home Assistant SIP Core. It is disabled by default; Home1 enables it
on `internal-websocket` using a separately built, digest-pinned Kamailio 6.1.4
image. The
[Forgejo workflow](../.forgejo/workflows/kamailio-lf-heartbeat.yaml) tests an
amd64 build and publishes an amd64 image on `main`; its successful run
reports the immutable digest. Home1 is running tag
`6.1.4-lf-heartbeat-5264324a63deaa38db2d0bba0d973d8296683899` at digest
`sha256:5eb5f47706f13edd4a9db90b1670c12c2354476d7eff8c08e748876cadec3545`.
See the [SIP Core
compatibility notes](docs/SIPCORE-HASS.md#home-assistant-lf-only-heartbeat-compatibility)
and [test instructions](tests/README.md#home-assistant-lf-only-heartbeat-regression).

The private Kamailio registrar supports a database-only provisioning mode.
The Home1 [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
now selects its PostgreSQL role, database, schema and stable connection Secret
without enabling SIP registration; live provisioning is pending reconciliation. See the
[registrar integration contract](docs/INTERNAL-REGISTRAR.md#database-only-provisioning)
for ordering, access boundaries, and the separate prerequisites for enabling
REGISTER handling.

YXL's and YVR's `internal` and `carrier` Kamailio instances are configured
for a mutual-TLS SIPS transport through the existing Envoy Gateway. The
client identities use each site's existing Vault backed `core-tls-vault`
ClusterIssuer. The desired YVR configuration enables Asterisk SIP Core account
`7101` to place standard NANP calls through the managed extension route. The
AVoIP Admin database supplies that extension's caller ID, and the provider's
`caller_ids` policy must authorize it. The chart retains the older
Asterisk-to-FreeSWITCH route only when Admin routing is disabled.
YXL PSTN call origination remains disabled. YXL's direct public SIP
Service remains disabled, so public TCP SIP is disabled there while the
outbound SIPS TLSRoute stays enabled. The Admin catalog currently sends both
sites' inbound DIDs to YVR: the voice DID to extension `67` and the other DID
to extension `66`. YXL uses the existing authenticated carrier inter-site link
for that handoff. Admin can instead select the silent YVR FreeSWITCH IVR or
another configured destination. See the [outbound runbook](docs/OUTBOUND-PILOT.md)
for the Asterisk-to-FreeSWITCH-to-Flowroute path, codec negotiation, trust
boundaries, destination filters and quotas, and the
[inter-site voice guide](docs/INTERSITE-VOICE.md) for transfer and rollout
verification. The [Flowroute teardown runbook](docs/avoip/runbooks/outbound-flowroute-teardown.md)
covers the internal Kamailio BYE route, replica-safe TOPOS restoration,
render regression and live SIP/media acceptance.
Confirm the deployed catalog and snapshots before changing an inbound route.

## Deployment ownership

Optional interface profiles for every enabled workload and the named YAML
`functions` array are documented in [NETWORKING.md](docs/NETWORKING.md).
They support Multus/CNI configuration, placement, DNS, and NIC init containers.

The owner is the [AVoIP ApplicationSet in CoRE-Backplane](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).
Its current desired state uses a merged generator for three production
clusters: `core-dc1-talos-prod`, `core-home1-talos-prod`, and
`dc1-k3s-node1`. It deploys the `AVoIP` path from the
[CoRE-Business source repository](https://slop.writemy.codes/CoRE/CoRE-Business), targets
`core-prod`, and renders through the
[Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin).

The [owning ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
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

The ordinary `internal` private-SBC remains limited to one replica. The separate
`internal-wss` instance can opt into three StatefulSet replicas with owner Path
routing, while Asterisk retains registration and authentication authority.
Kamailio processes do not share live WebSocket connections or transaction
state. Kubernetes client-IP affinity cannot identify the owner because Envoy
and Asterisk are different clients. See the
[WSS edge rollout guide](docs/SIP-STATEFUL-HA.md#implemented-wss-edge-mode)
before enabling the additional instance. Inbound fan-out uses Asterisk's
per-contact dial list; the HA edge accepts an initial INVITE without a usable
Path Route only when its Contact Request-URI names the exact receiving owner
pod, then resolves the local WebSocket alias. Requests for another owner and
other owner-routed methods still require a valid Path Route.

The SIP Core callback targets the authenticated source extension and rings all
of its registered contacts in parallel, like inbound DID fan-out. When one
contact answers, Asterisk cancels the other attempts. See the
[SIP Core configuration and behavior](docs/SIPCORE-HASS.md).
The public-IVR callback is a separate, opt-in route. When enabled, it returns
the call to an exact configured internal account identity or a valid NANP
caller identity received over the authenticated FreeSWITCH-to-Asterisk leg.
Internal accounts ring all of their registered contacts; external callbacks
use the configured main voice DID as outbound caller ID and connect the
answered caller to the existing GG audio service.
The callback selection is a control handoff: Asterisk closes the original
FreeSWITCH bridge after accepting it, so that normal teardown bypasses the
generic inbound GG error-audio fallback.
FreeSWITCH still originates the carrier leg through the existing Flowroute
gateway. The authenticated callback route accepts valid NANP destinations in
E.164, country-code digits without a leading plus, or national form with an
optional plus, and normalizes them to E.164 for the carrier gateway. The caller
identity is not independently verified by this route, so carrier-side ANI
validation remains an operational trust assumption.
The YVR opt-in is owned by the [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).

Routr Connect 2.13.6 is integrated as optional workloads in this chart's
BJW-S common-library render, based on the [upstream Connect chart](https://github.com/fonoster/routr/tree/v2.13.6/ops/charts/connect)
and [Routr documentation](https://routr.io/docs/2.11.5/connect/concepts/). It is
disabled by default; Asterisk remains the active registrar and authentication
authority. Routr uses the shared site PostgreSQL service and Dragonfly logical
databases 155 (Location) and 156 (Registry). Location and Registry require
patched images built from the pinned Routr source to select those databases.
See [Routr pilot notes](docs/ROUTR.md) before enabling it.

The Admin catalog currently routes the voice DID to YVR extension `67` and
the other DID to YVR extension `66` at both sites. It can select the silent
FreeSWITCH IVR instead; that IVR accepts configured Asterisk destinations and
voicemail access. Managed inbound calls preserve the post-answer fax detector
when the DID's **Detect fax after answer** switch and the site-wide fax settings
are enabled. Detected faxes enter the existing `fax-receive` path. SpanDSP
color fax negotiation remains enabled through `freeswitch.fax.colour.enabled`. See the
[current inbound call path](docs/PHONE-TREE.md).

Inter-site voice uses the carrier Service on TLS/5061 and its public TLS
listener, with a site-specific optional-client-certificate TLS profile. The
request is authorized by the configured peer CIDR, verified client certificate
SAN, and exact extension allowlist. The private Service on TLS/5062 remains for
same-site application traffic. See the [inter-site voice guide](docs/INTERSITE-VOICE.md)
for listener, network policy, trust and dialog behavior, including the
2026-10-17 CANCEL and FreeSWITCH dialplan findings. An answered inter-site
call remains to be verified after rollout.

Codec preferences are configurable under the top-level `codecs` values. Opus
is enabled by default on the Asterisk-to-FreeSWITCH peer, SIP Core endpoints,
and the FreeSWITCH-to-Asterisk profile; FreeSWITCH global preferences already
include Opus. These lists are independent for Asterisk's FreeSWITCH peer,
SIP Core endpoints, FreeSWITCH global inbound/outbound negotiation, and the
dedicated FreeSWITCH-to-Asterisk profile. For example, set
`codecs.freeswitch.outbound: ['G722', 'PCMU']` in a Helm values layer to
change the global outbound preference order. A site can provide these keys in
the `LOVELY_HELM_MERGE` values of the owning
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).
The Flowroute outbound bridge has a separate `freeswitch.flowrouteOutbound.codecs`
policy, defaulting to `['PCMU', 'PCMA']`; it requires PCMU and only changes the
FreeSWITCH-to-carrier B-leg. Internal and WebRTC codec preferences remain
unchanged. Flowroute's supported voice codecs are documented on its
[voice service page](https://flowroute.com/voice/).
Use Asterisk's lowercase codec names and FreeSWITCH's uppercase names. The
fax receive dialplan keeps its separately scoped G.711 selection because fax
modem audio and T.38 negotiation have different requirements.

## Components and security

The complete current DID flow, SIP messaging path, registration behavior, and
operational caveats are documented in [docs/PHONE-TREE.md](docs/PHONE-TREE.md).
The optional direct-extension voicemail path, including voicemail-only sites
without SIP Core, its shared external PIN secret, changeable PostgreSQL-backed
mailbox PIN, PostgreSQL audio storage, retained legacy audio volume, image
prerequisites, and verification steps are documented in
[docs/VOICEMAIL.md](docs/VOICEMAIL.md).
Inbound external SIP is restricted by the Flowroute signaling CIDRs configured
under `flowroute.signalingCIDRs`; the public DID route does not
accept arbitrary Internet SIP sources.
The [SIP security probes](tests/README.md#authorization-and-outbound-call-probes)
exercise denied sources, registration, unmatched outbound destinations, and
bad private-peer credentials on an isolated deployment. Carrier DID calls use
the source ACL rather than SIP digest authentication.
FreeSWITCH public inbound DID routing is selected by Admin through Kamailio. YVR's managed
Asterisk NANP route sends calls directly through private Kamailio using the
SIP Core `carrier-outbound` PJSIP endpoint. The Admin database maps each
permitted extension to its caller ID and provider route; the carrier verifies
the caller ID against that provider's allowlist. YXL keeps PSTN origination
disabled. The former Asterisk-to-FreeSWITCH route remains available only while
Admin routing is disabled. FreeSWITCH still registers to the regional
Flowroute SIP endpoint using the existing Vault record
`AVoIP/SIP/FlowRoute` (`Username` and `Password`) for its separate inbound
role. The managed DID catalog supports IVR and direct extension destinations
for each number; see the [Admin configuration steps](docs/ADMIN.md#configure-the-current-inbound-numbers-in-admin).
YXL uses the US-East-VA PoP and YVR uses US-West-OR. The existing
carrier path and RTPEngine continue to handle signaling and media. The legacy
Flowroute gateway uses its `outbound-proxy` for the Kamailio INVITE hop,
following the
[FreeSWITCH gateway configuration](https://developer.signalwire.com/freeswitch/users-and-endpoints/gateways/)
and [Flowroute regional PoP configuration](https://developer.flowroute.com/docs/inbound-and-outbound-calling-with-flowroute-new-pops/).
The outbound `flowroute-tls` gateway sets `from-domain` to the configured or
derived site SIP hostname (`sip.siteHost`); `caller-id-in-from` retains the
authorized caller number as the From URI user. Thus the carrier sees the
site-local SIP route identity as the From host rather than a FreeSWITCH pod
address. This is set when FreeSWITCH creates the dialog, so subsequent
in-dialog requests retain the same dialog identity without a Kamailio header
rewrite.
When Admin routing is disabled, carrier Kamailio prefixes the Flowroute
registration username and `*` to the outbound E.164 Request-URI from a
username-only ExternalSecret. This provides Flowroute's IP-auth Tech Prefix
format; it does not disable the existing SIP registration credentials.
Admin-managed outbound calls instead use the selected provider's host and
verified caller ID. Flowroute IP authentication also requires a static public
egress IP and account-side allowlisting; see its
[IP-auth setup](https://support.bcmone.com/flowroute-support/docs/set-up-ip-based-authentication-for-outbound-calls).
YVR also provisions the `twilio-west` FreeSWITCH gateway for
[Twilio Elastic SIP Trunking](https://www.twilio.com/docs/sip-trunking) using
IP ACL authentication and no registration. The Admin provider and extension
assignment determine whether a call uses it; see the
[upstream configuration](docs/ADMIN.md).
The ApplicationSet enables two FreeSWITCH replicas at both sites and disables
the direct SIP Service. The configured Asterisk SIP Core NANP caller remains
YVR extension `7101`; YXL has no SIP Core caller configured. This provides
new-call availability after a pod failure;
an active FreeSWITCH call is not replicated to another pod. The existing fax
spool claim remains retained; the HA workload uses a separate RWX claim, and
the old fax data is not copied automatically.
For carrier dialogs, Kamailio routes established requests to the FreeSWITCH
pod IP and Flowroute Sofia TLS port (5081) restored from the TOPOS record. The
Flowroute profile advertises that pod-local listener; port 5061 belongs to the
separate Kamailio-facing FreeSWITCH profile. New calls still use the shared
Service; using that round-robin Service for an established dialog can send its
BYE to a replica that does not own the call. TOPOS hides the pod address from
Flowroute.
The legacy FreeSWITCH SMS module configuration still follows
`freeswitch.sms.enabled`, but the deployed image contains `mod_sms` and lacks
`mod_sms_flowroute.so`; it does not provide a working Flowroute SMS service.
The standalone `flowrouteSMS` receiver described in the
[SMS guide](docs/FLOWROUTE-SMS.md) is independent of this legacy FreeSWITCH
configuration and is disabled until its callback inputs are provisioned.

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
Asterisk uses `asterisk.timeZone` (Home1/YVR: `America/Vancouver`) for local
time. A startup init container copies that zoneinfo file from the pinned
Asterisk image to an ephemeral volume mounted read-only at `/etc/localtime`;
this is the timezone file Asterisk 20 loads for its local-time functions
([upstream implementation](https://github.com/asterisk/asterisk/blob/20/main/stdtime/localtime.c)).
The container also receives the matching `TZ` value for its utilities. Set
`asterisk.timeZone` in the site values layer when deploying Asterisk in another
timezone.

Component behavior is controlled by chart values and the ApplicationSet merge:

| Component | Current role | More detail |
| --- | --- | --- |
| Asterisk | Private voice PBX; authenticates to FreeSWITCH over TLS with Secret-backed SIP Digest credentials, offers Opus then G.722 with PCMU fallback on the FreeSWITCH peer, records CDRs in site-local PostgreSQL, and transfers extension 66 to FreeSWITCH's `gg-audio` dialplan user. The SIP Core callback test adds a configurable 100 ms RTP silence lead-in and correlated media logs. | [Call path](docs/PHONE-TREE.md), [Home Assistant SIP Core and GG audio](docs/SIPCORE-HASS.md), [internal TLS check](#internal-asterisk-sip-identity) |
| Kamailio | Public carrier SIP border and private TLS relay with TOPOS. | [Values](docs/KAMAILIO-VALUES.md), [SIP identity](docs/SIP-IDENTITY.md) |
| FreeSWITCH | Private call control, voice DID, fax `rxfax`, and Secret-backed configuration. | [Call path](docs/PHONE-TREE.md), [fax verification](docs/SIP-IDENTITY.md) |
| RTPEngine | Public media anchor with private NG control and Valkey recovery state. | [RTPEngine HA](docs/avoip/rtpengine-ha.md) |
| Homer 11 | Internal HEP capture and Authentik-protected UI where enabled; the same hostname also serves the shared Asterisk/FreeSWITCH prompt editor. | [Homer](docs/HOMER.md), [call recordings](docs/HOMER-AUDIO.md), [shared sound library](docs/avoip/sound-library.md) |
| LiveKit | Independent WebRTC signaling and media stack on Home1/YVR. | [LiveKit deployment](docs/LIVEKIT.md) |
| Speech | External dependency from the AI stack; no local Vosk or Mycroft workload. | [Speech architecture](#speech-architecture-and-todos) |
| Jitsi Meet | Pinned dependency, disabled by default. | [Upstream chart](https://github.com/jitsi-contrib/jitsi-helm) |

The Asterisk and FreeSWITCH `User` claims set `spec.name`, `spec.groups`,
`spec.serviceAccount`, and `spec.writeConnectionSecretToRef`. Review the
[User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
and [Composition](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserComposition.yaml)
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
The active [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
sets the site identity, carrier transport exposure, and media address.

Public TLS/5061 passes through Envoy Gateway to Kamailio's native TLS socket;
Envoy adds PROXY protocol v2 so Kamailio can enforce the Flowroute source ACL.
Home1 also exposes direct UDP/5060 through kube-vip. DC1 exposes direct
UDP/5060 and TCP/5060 through PureLB. The direct Service preserves the source
address with `externalTrafficPolicy: Local`. Kamailio's private listener is
TLS/5062; it sends accepted calls to FreeSWITCH over TLS/5061 and uses TOPOS
state in Dragonfly database `51`. Its carrier-facing Contact and route set retain
the original public transport; the private backend address is hidden.
The local HAProxy TLS bridge runs as a native sidecar init container, so
Kubernetes waits for its readiness probe before starting Kamailio's TOPOS
clients.
A 2xx ACK follows the restored dialog route, including when it reaches a
different Kamailio replica. This routing still needs live verification.

The public TLS gateway depends on the
[Ingress ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Network/Ingress.yaml).
Its SIPS fallback supports clients without SNI. New outbound carrier requests
use the site's VyOS NAT egress. See [SIP identity and call verification](docs/SIP-IDENTITY.md)
for the exact Contact, Record-Route, ACK, TLS, Gateway, and egress behavior.
The [Kamailio values reference](docs/KAMAILIO-VALUES.md) explains listener,
Service, TOPOS, and logging options. The
[boundary architecture](docs/avoip/architecture.md) separates current
site-local dialogs from proposed cross-site failover.

The [Sipwise RTPEngine](https://github.com/sipwise/rtpengine) anchors public
RTP independently of SIP signaling. Kamailio sends NG control over the private
UDP control Service; its explicit timeout/retry, short disable interval, and
periodic redetection settings recover the node after transient control errors.
Its media inactivity, muted-stream, unanswered-offer, and total-call timers are
explicitly set to 120, 3600, 120, and 300 seconds respectively, limiting each
call to five minutes in RTPEngine.
The separate RTPEngine WebSocket control path remains disabled following the
observed process crash during an offer. Its
[RTPEngine configuration](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md)
uses the site-specific media address and UDP range supplied by the owning
ApplicationSet. Kamailio fails closed if RTPEngine cannot handle a media-bearing
request or SDP reply; it does not expose private FreeSWITCH SDP as a fallback.
The public media LoadBalancer exposes the configured UDP range and uses the
site's provider settings under
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
[CoRE-Backplane PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
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

When `flowrouteSMS.enabled` is true, the chart creates a
`User.mylogin.space/v1alpha1` claim named `core-voice-<cluster>-<region>` with
`spec.name: CoRE-Voice` and no fixed username. The current Backplane User
Composition generates that service identity and provisions it through the
global PostgreSQL providers `psql` and `psql-main`; its connection Secret is
used by the standalone SMS persistence service. The same claim is retained
while the legacy `freeswitch.sms.enabled` path remains active.

The [Flowroute SMS messaging stack](docs/FLOWROUTE-SMS.md) now runs separate
web, API, and webhook Deployments and Services in `core-prod` on the primary
YVR cluster. The web route serves the responsive conversation UI, the API
checks Authentik number entitlements for reads and sends, and the public
`/flowroute/` route remains callback-token protected. The API receives Flowroute
send keys from an ExternalSecret backed by the existing SMS Vault record.
Twilio provider accounts can also send MMS from the inbox using publicly
reachable HTTPS media URLs; the service does not retain those outbound files.
Signed inbound Twilio MMS callbacks download and store image attachments under
the same size cap as the Flowroute inbox; video and other non-image media are
rejected.
See the [SMS provider and MMS guide](docs/FLOWROUTE-SMS.md#groups-administrative-access-and-providers)
for provider limits and the current inbound MMS support boundary.
The web response allows framing only by `https://office.mylogin.space` and
itself; configure `flowrouteSMS.inbox.frameAncestor` for another trusted
Nextcloud origin. The [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
injects the YVR site values.

Sofia raw SIP tracing is enabled by default on the managed Asterisk, external,
and Kamailio-facing profiles for troubleshooting; it records SIP signaling and
SDP metadata in the FreeSWITCH logs, so disable `freeswitch.sipLogging.enabled`
when that exposure or log volume is not appropriate.

Failed inbound Asterisk handoffs in FreeSWITCH answer the caller, play
the existing GG asset, and hang up normally by default; see the
[inbound failure policy](docs/PHONE-TREE.md#configured-did).

Each Kamailio-enabled cluster can deploy the internal [Homer 11 SIP monitoring](docs/HOMER.md)
stack. Kamailio forwards HEPv3 signaling directly to the Homer 11 ingest
listener, while RTPEngine forwards RTCP/NG diagnostics. The Homer UI is
protected by Authentik OIDC and Gateway Forward Auth; its HEP ports are not
publicly exposed.

Cross-dialog call linking preserves each SIP Call-ID and uses the originating
SIP Core dialog Call-ID as the shared Homer HEP correlation ID. Homer 11's
seeded `1_call` correlation script still requires one-time activation in
Settings → Scripts; see [Homer correlation](docs/HOMER.md#capture-and-access).

Kamailio's default SIP listeners and RTPEngine's control listeners bind to each
pod's Downward API address so locally emitted HEP traces identify the source pod.
Received SIP traces retain their peer addresses; see [Homer capture verification](docs/HOMER.md#verification).

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
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
provides a complete `kamailio.instances` array at each site. The three
sites retain the named `carrier` instance with three replicas. This is the
current public SIP service and provides same-site Kamailio pod redundancy;
Home1's carrier Deployment currently reports three desired and three ready
replicas. Public SIP traffic attaches to this carrier instance. YVR also
enables one `internal` instance with the `private-sbc` role. YXL's desired
values now add the same private role for the Vault-backed mTLS transport; its
certificate rollout is pending reconciliation. The internal instance
handles private application signaling such as Asterisk/SIP Core and is
separate from public carrier SIP.
An instance receives `defaults`, then its role defaults, then its own
overrides. Site Helm values replace the entire instances array.

Three carrier replicas provide same-site availability for new SIP requests
when a pod fails. They do not move an active WebSocket/TLS connection or
in-flight transaction to another pod, and they do not establish cross-site
active-call failover. See [SIP availability options](docs/SIP-HA-OPTIONS.md)
for the tested and unverified failure boundaries.

The `carrier-sbc` role preserves the existing public SIP border and private
TLS backend. An opt-in `private-sbc` instance now has its own TLS/5062 Service,
Deployment, certificate, TOPOS Secret, Cilium policy, and routing script. It
requires a verified client certificate and an explicitly listed peer address
and certificate DNS SAN. Exact extension rules select probed dispatcher
destinations; unmatched requests and, by default, `REGISTER` fail closed. It does not load
RTPEngine or forward to Flowroute. Unlike the carrier role, direct private
connections do not require an Envoy PROXY header. The ordinary `internal`
private-SBC remains one replica; SIP Core HA uses the distinct `internal-wss`
instance and Path-based ownership described in the [Kamailio values](docs/KAMAILIO-VALUES.md).

The [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
now enables one `private-sbc` instance in YVR beside the existing carrier
instance; the operator reports that the first pieces are live. Its rollout and
SIP behavior have not yet been independently verified here. The carrier's
existing private listener still uses its current CIDR guard for dialog
traffic; new calls from that listener receive 403. The existing Home Assistant
SIP Core route uses `internal`; HA adds a separate `internal-wss` instance for
staged route and Asterisk Path cutover. An
[outbound service-peer route](docs/OUTBOUND-PILOT.md) uses Vault mTLS
over the existing SIPS Gateway path and site SNI between internal and carrier
Kamailio. It reuses the current Flowroute trunk and adds no Gateway route,
SNI, or Service. YVR enables account `7101` for standard NANP calls with
the configured Asterisk DID as caller ID, carrier-owned RTPEngine media anchoring, and shared
rate/concurrency quotas. YXL call origination remains disabled. No live carrier
call has been made. The chart does not
enable the Kamailio registrar pilot or an OIDC webphone; its current SIP Core
path uses Asterisk's PJSIP registrar
and the existing Envoy WSS route.

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
The currently running Home Assistant integration version is **v5.1.2**
(operator-confirmed on 2026-10-18).
It provisions static PJSIP extensions from External Secrets, serves WSS through
Envoy to a separate named Kamailio WSS instance, and allows only exact
configured internal destinations. Carrier and FreeSWITCH fax signaling stays
on the separate carrier instance. The WSS instance relays signaling to
Asterisk over TLS and controls the existing RTPEngine for the Home Assistant
media leg, separately from the ordinary `internal` private-SBC instance. The
YVR currently runs three `internal-websocket` replicas behind its WSS Service
while retaining the one-replica `internal` return instance. Home Assistant has
confirmed that the extension rings and plays audio, and that its registration
and WSS connection now remain live over time. The Gateway still imposes a
3600-second maximum connection duration. Inspect the owning ApplicationSet
before changing its rollout values. See
[SIPCORE-HASS.md](docs/SIPCORE-HASS.md) and the
[three-replica WSS edge guide](docs/SIP-STATEFUL-HA.md#implemented-wss-edge-mode).

The HA mode keeps Asterisk as registrar and Digest authority. SIP Path targets
the exact StatefulSet replica with the registered WebSocket, and a separate
headless owner Service provides private TLS addressing. The WSS Service selects
only the edge instance on port 8088; YVR's live HTTPRoute targets that Service.
When ingress and legacy return instances differ, Asterisk must route by each
contact's stored Path and must not retain the shared legacy proxy for OPTIONS.
If an owner no longer has the contact's WebSocket, Kamailio returns `430 Flow
Failed`; Asterisk treats non-2xx OPTIONS results as unavailable and prioritizes
unavailable contacts when replacing registrations at the configured contact
limit. A disconnected contact otherwise remains until expiry or replacement.
This is signaling availability only: an unexpected owner loss interrupts that
connection's dialogs and media until Home Assistant reconnects and registers.
The CoRE-Backplane Gateway policy still imposes a one-hour maximum connection
duration and needs a separate future policy change for longer sessions.
Current YVR route idle/duration policies do not explain a reported 30-second
disconnect; SIP Core flow and WebSocket-close markers help correlate the next
disconnect without logging SIP bodies or Digest credentials.

Run `helm lint AVoIP` and `AVoIP/tests/wss-ha-render.sh` for the WSS edge
rendering checks. The working tree does not include the older Kamailio,
registrar, outbound or SIP-security shell tests referenced by earlier docs;
see [test notes](tests/README.md). Review the rendered carrier selector,
public Contact, source ACL, and private target before scoped Argo CD
reconciliation. For live acceptance, correlate one Call-ID across both Kamailio legs and FreeSWITCH:
require the 2xx ACK at FreeSWITCH, a call lasting beyond 60 seconds, and
BYE/200 completion. Check fax completion separately. Roll back both the chart
and owning ApplicationSet values if a site instance change must be reverted.

## LiveKit Server

The active [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
enables LiveKit for Home1/YVR. It has its own HTTPS signaling route and
public UDP/TCP media Service; it does not share Kamailio or RTPEngine media.
The rendered configuration uses site-local TLS Dragonfly, Secret-backed API
keys, and a separate public address. External media reachability still needs
verification after reconciliation. See [LiveKit deployment, prerequisites,
verification, and recovery](docs/LIVEKIT.md).

## Asterisk WebRTC media relay candidates

The [Asterisk RTP/ICE configuration](https://docs.asterisk.org/Configuration/Miscellaneous/Interactive-Connectivity-Establishment-ICE-in-Asterisk/)
loads `res_rtp_asterisk.so` and uses configurable
`asterisk.rtp.stunAddress` (default `nat.mylogin.space:3478`) for STUN address
discovery independently of TURN. The Asterisk image build verifies that RTP
module is present, and `modules.conf` requires it at startup. Optional TURN
relay candidates use the existing [CoTURN](https://github.com/coturn/coturn)
service. Its
[REST shared secret](https://github.com/coturn/coturn/blob/master/README.turnserver)
is mounted directly from the existing `matrix-turn-auth` Secret created by
Social/Matrix. Asterisk derives a time-limited TURN username/password at
startup and stores the generated include only in its runtime `/tmp`; no
credential is rendered into a ConfigMap or Helm values. The Asterisk runtime
image includes the OpenSSL CLI needed for HMAC derivation. The chart pins the
newly built image digest and enables TURN for sites where Asterisk SIP Core is
enabled; verify the Matrix-managed Secret is Ready before rollout. The
credential lifetime is configurable up to one year, so restart Asterisk
before the expiry.

Asterisk's `stunaddr` is a single server setting, not a multi-server list. The
operator confirms that both `nat-home1.mylogin.space` and `nat.mylogin.space`
work as STUN endpoints. The chart selects the site-local endpoint by region:
Home1/YVR uses `nat-home1.mylogin.space:3478`, while DC1/YXL uses
`nat.mylogin.space:3478`. Home1/YVR CoTURN is enabled; see the [site and TURN
notes](docs/SIP-STATEFUL-HA.md#existing-turn-dependency-and-consumer-integration).

This provides server-reflexive ICE candidates for Asterisk's media socket;
STUN does not provide a TURN relay. The Home Assistant
signaling path remains WSS through Envoy and Kamailio, and browser media remains
relayed through the existing RTPEngine. CoTURN does not replace RTPEngine or
provide credentials to the browser. See
[the SIP Core media notes](docs/SIPCORE-HASS.md#media-reachability) before
diagnosing two-way audio.

The server-side SIP/RTP call path is configured IPv4-only: Asterisk PJSIP
endpoints disable IPv6 RTP, Kamailio resolves SIP destinations using IPv4 DNS,
and its RTPEngine SDP operations request `IP4`. FreeSWITCH's SIP/RTP profiles
bind to `local_ip_v4`, with the image's IPv6 profiles disabled. This controls
the server-side call path; it does not prevent browsers from gathering IPv6
host candidates locally.

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
[NATPuncher Vault path](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Network/NATPuncher.yaml).
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

After the [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
reconciles, verify both public DNS records, the Home1 Gateway route, the media
LoadBalancer address, ExternalSecret readiness, and the HPB health check. In
Nextcloud, confirm the HPB check is green and test a multi-participant call from
outside the Home1 network. A rollout restarts signaling, Janus and eturnal and
will end active calls. Roll back by disabling `talkHpb.enabled`; remove the
Nextcloud Talk configuration separately only if the backend is being retired.

## Internal Asterisk SIP identity

The SIP Core Kamailio routes handle WebRTC trickle ICE fragments separately
from session SDP. A fragment with content type
`application/trickle-ice-sdpfrag` is accepted only on SIP INFO and updates
RTPEngine through `rtpengine_info()`; incomplete `application/sdp` bodies are
rejected before they reach RTPEngine. This prevents fragment or empty SDP
bodies from being processed as a new media offer and restarting the relay.
When the trickle handler fails, Kamailio logs only the parsed Content-Type and
body length in addition to the dialog correlation ID; it does not log the
fragment body. RTPEngine parser failures are distinct from NG-control timeout
and redetection events.
See the [Kamailio RTPengine module documentation](https://www.kamailio.org/docs/modules/6.1.x/modules/rtpengine.html)
and the [RTPEngine NG protocol documentation](https://github.com/sipwise/rtpengine/blob/master/docs/ng_protocol.md).

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

- The [AI ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Tools/AI.yaml)
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

The silent DTMF extension collector remains available as an Admin-selected
IVR destination; it does not use the shared prompt library or a speech bridge.
If voice TTS/STT is needed later, the
existing Wyoming endpoint or an OpenAI-compatible speech bridge can be
integrated without recreating Vosk or Mycroft resources.

## Historical `dc1-k3s` state

A 2026-06-11 inventory showed scaled-to-zero Vosk and Mycroft resources from
an older [legacy AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Legacy/AVoIP.yaml).
That inventory predates the active multi-cluster
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
and must not be treated as current controller state. The current chart does not
render those speech workloads; check Argo CD before making deletion or
recovery decisions about any remnants.

## Verification and activation

The chart is deployed. The Admin catalog currently sends the voice and other
DIDs to YVR extensions `67` and `66`, respectively. The
five-second audio relay interruption is also reported resolved after the
FreeSWITCH SIP profile RTP timer changes. Call-correlated traces and the
end-to-end failover paths still need live verification; see
[SIP identity and call verification](docs/SIP-IDENTITY.md):

1. Confirm an inbound Flowroute INVITE receives an ACK at FreeSWITCH and stays
   up for at least 60 seconds. The prior approximately 32-second `ACK Timeout`
   is reported resolved; one [operator-correlated 129-second call](docs/SIP-IDENTITY.md)
   had a complete recording. Retain a Call-ID-correlated ACK and clean BYE/200
   trace as acceptance evidence. See [SIP identity and call verification](docs/SIP-IDENTITY.md).
2. Verify each DID reaches its Admin destination at both sites. Where a DID is
   configured for the IVR, verify its allowed DTMF choices. Verify fax detection
   and `fax-receive` on a DID with its switch enabled; confirm a disabled DID
   skips detection.
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
for this workflow: [User platform APIs](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/README.md).

## Upstream projects

- [Asterisk](https://www.asterisk.org/) and its
  [documentation](https://docs.asterisk.org/)
- The chart-local [Asterisk image build](image/asterisk/Containerfile) extends
  the pinned-version upstream
  [andrius/asterisk image](https://hub.docker.com/r/andrius/asterisk) and adds
  the Asterisk PostgreSQL and ODBC modules, unixODBC, and the PostgreSQL ODBC
  driver required for voicemail. It retains the existing ALSA, English sounds,
  music-on-hold, Speex, and SRTP modules. The
  [Forgejo workflow](../.forgejo/workflows/asterisk.yaml) publishes the
  `linux/amd64` image only to this repository's Forgejo registry. Asterisk uses
  PJSIP's compatible `external_signaling_address` option;
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

AVoIP administration is enabled by the Backplane owner on YVR and YXL, with
SMS hosted in YVR and managed SIP routing enabled. DNS-only admin aliases
use the existing site HTTPS gateway names; the routes require Authentik. See
[deployment and rollback](docs/ADMIN.md).
