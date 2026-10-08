# Opt-in carrier outbound pilot

This is an implementation and validation record, not permission to place a
billable call. The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
does **not** enable `carrierOutbound` at either site. The production inbound
Flowroute, RTPEngine, FreeSWITCH, Asterisk and fax path remains separate.

## Ownership and trust path

The private SBC accepts a test INVITE only from its configured mutual-TLS
service peer when the exact `testRoute.extension` and `From` caller ID match.
It replaces the requested destination with one configured E.164 number,
removes any incoming P-Asserted-Identity, and sets the permitted caller ID.
The request goes to the existing Envoy SIPS Gateway Service with a dedicated
SNI. The current [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml)
has a single SIPS TLSRoute and a no-SNI fallback filter chain that forwards
the TLS stream while adding PROXY v2. No new public LoadBalancer or Flowroute
ACL entry is introduced. Kamailio's global `tcp_accept_haproxy=yes` remains
necessary on the carrier pod; the private pod uses `no` for direct peers.

The carrier's separate [Kamailio TLS](https://www.kamailio.org/docs/modules/6.1.x/modules/tls.html)
SNI profile requires a verified client certificate. Carrier routing then
checks that certificate's DNS SAN and the PROXY-reported source range, the
fixed caller identity, and the one permitted NANP destination. Ten- and
eleven-digit NANP input normalizes to `+1` E.164; malformed, premium `900`
and `976`, international, and all other numbers are rejected. A registration
alone never creates this service-peer entitlement. The preexisting
FreeSWITCH private listener still rejects new outbound INVITEs.

The carrier invokes [RTPEngine](https://www.kamailio.org/docs/modules/6.1.x/modules/rtpengine.html)
once for the internal-to-external offer; the private SBC does not anchor it a
second time. The existing carrier reply route processes the SDP answer and
in-dialog offers. The [dialog module](https://www.kamailio.org/docs/modules/6.1.x/modules/dialog.html)
caps the pilot call lifetime, while an atomic [Dragonfly](https://www.dragonflydb.io/docs)
Lua script limits calls per minute and concurrent calls across all carrier
replicas. These quota keys use the carrier's existing site-local Dragonfly
connection with a distinct `avoip:out:quota:` prefix; they are not registrar
credentials or RTPEngine state. BYE, CANCEL and negative INVITE replies release
the active slot; the configured maximum lifetime bounds a missed release.

TOPOS and the private role's Record-Route retain each selected SIP path.
Carrier-to-private in-dialog traffic is directed only to the configured
internal service. Private-to-carrier dialog traffic returns via the Gateway
so the carrier continues to receive PROXY v2. A `carrier` mTLS peer on the
private role has no `allowedUsers`, preventing it from starting a new call
that loops back toward Flowroute.

## Configuration and rollout

`kamailio.instances[]` is a replace-only list. A site override must retain
the existing `carrier` entry while adding an `internal` entry. Both roles
must explicitly enable `carrierOutbound` and supply the same
`gatewayServiceHost`, `sniHost`, `testRoute.extension`,
`testRoute.destination`, `testRoute.callerId`, and quota limits. The carrier
entry additionally sets `peer.cidr`, `peer.sanHostname`,
`peer.serviceHost`, and `peer.controller`; the private entry sets
`testRoute.peerName` and lists both the test origin and `carrier` in
`privateRouting.peers`. The carrier peer's `allowedUsers` must be empty.
Its `peer.cidr`/SAN on the private side identifies the carrier pod. Give the
private role its own TOPOS database and Secret, and confirm the
[Dragonfly allocation registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md)
before choosing the database number.

The private Cilium policy permits only named peer controllers on TLS/5062
and egress to the existing Gateway proxy on TLS/5061. The carrier policy
adds egress only to the named internal controller when enabled. The dedicated
SNI is added to the carrier cert-manager Certificate only when enabled;
verify the Secret and issuing CA before opening the route. Enabling this
capability changes the carrier certificate and TLS server profile, so stage
it at Home1, inspect the rendered complete Lovely output, and take a fresh
inbound voice/fax baseline before any call. Do not enable it at DC1 by
copying Home1's instance list or network identity.

## Evidence and remaining gate

`helm lint AVoIP`, `tests/kamailio-instances.sh`, and
`tests/sip-outbound-render.sh` validate the default-disabled configuration
and opt-in policy shape. Both outbound-enabled Kamailio roles passed the
pinned 6.1.4 parser check offline. The quota admission script was executed
against an isolated Dragonfly v1.39.0: first call `1`, retransmit `1`,
second call `-2` at concurrency one; release `1`, then the next call `-1`
under the per-minute rate cap. These checks do not prove Gateway routing,
TLS client-certificate negotiation, Flowroute acceptance, RTP, or dialog
teardown in a real call. The optional Flowroute SIP Digest trunk mode is not
implemented; the pilot assumes the existing IP-authorized trunk. A full
user-level PSTN entitlement path depends on the later registrar and broker.

An operator must first observe an inbound multi-minute voice call and the
separate fax baseline after rollout. For the outbound pilot, verify the
Gateway SNI and PROXY header, mTLS SAN, test-peer denial cases, quota
rejections, exact caller ID, and serialized offer/answer in a SIP trace.
Only then may an operator deliberately originate the exact configured
test extension, monitor charges, verify bidirectional audio, ACK/BYE and
RTPEngine cleanup, and disable the test route when done. No automated test
places a public call.

Rollback is to set `carrierOutbound.enabled: false` on both instances and
reconcile the reviewed ApplicationSet. This removes the added SNI TLS
profile, caller route, cert SAN, Gateway egress rule and quota invocation;
it does not remove the carrier's existing public SIP identity or inbound
route. Disable the private instance separately if the internal routing pilot
must also be removed. Existing quota keys expire by the configured maximum
duration; do not flush the shared Dragonfly database.
