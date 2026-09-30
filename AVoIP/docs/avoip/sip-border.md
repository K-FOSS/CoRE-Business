# SIP border

Kamailio listens on public TLS TCP/5061 and private TLS TCP/5062. Envoy passes
the public encrypted stream and PROXY protocol v2 to Kamailio; the immediate
network peer is Envoy, not Flowroute. Kamailio validates the PROXY-derived
carrier address against `flowroute.signalingCIDRs`.

The site-specific public FQDN is the carrier-facing established-dialog
identity; the private Kamailio Service FQDN is the application-facing
identity. TLS egress to Flowroute is selected by Kamailio using
`flowroute.outboundHost`, not by FreeSWITCH. RR maintains an ordered pair of
public/private socket routes, while TOPOS hides the pair and stores its
replica-independent reconstruction data in site-local Dragonfly database 51.
Do not move established-dialog Contact identities to the global SIP name
until cross-site dialog state and B2BUA recovery are validated.

TOPOS Redis shares dialog topology only; it does not replicate Kamailio TM
transactions. CANCEL and ACK to non-2xx INVITE responses are transaction-scoped
and must reach the replica holding the INVITE transaction. The Envoy SIPS
listener is L4/TLS passthrough, so requests on the same SIP/TLS connection
remain on the same upstream connection and Kamailio pod. A new TLS connection
may select another pod; do not expect that pod to reconstruct TM state from
Dragonfly. In contrast, ACK to a 2xx INVITE is a separate UAC transaction and
must use the normal TOPOS/RR dialog route, so it remains replica-independent.

For temporary carrier-response inspection, set
`kamailio.sipLogging.postToposResponses: true`. The gated
`event_route[topos:msg-sending]` records complete 180–299 INVITE responses
after TOPOS rewriting, immediately before send. This includes SIP identities,
Contact/Route data, SDP, and potentially sensitive body content; disable it
after capturing a controlled call. TOPOS `event_mode: 15` includes bit 2,
which enables this event route. ACK ingress is logged before sanity checks
with `$Rn` (the receiving socket name), source, R-URI, Route, Call-ID, CSeq,
and dialog tags. Confirm ACK absence by searching this ingress marker across
all Kamailio replicas for the exact Call-ID and time window—not by absence of
later route/relay markers.

The private policy admits the FreeSWITCH pods to 5062 and permits Kamailio to
reach FreeSWITCH TLS/5061 and RTPEngine NG UDP/22222. Configure the Envoy
namespace and pod labels in `kamailio.networkPolicy.envoy`; carrier CIDRs do
not belong in that Kubernetes policy.

Kamailio starts only after `kamailio -c -f /etc/kamailio/kamailio.cfg` passes,
uses a 60-second termination grace period, and exposes `tcp_children` through
`kamailio.tcpChildren`. Raw SIP receive logging and diagnostic SDP logging
are independently switchable. Raw logs can contain Authorization headers,
identities, SDP, MESSAGE bodies, PAI, and Contact details; keep them disabled
outside troubleshooting.

The ordinary FreeSWITCH and Asterisk Services are private ClusterIP Services.
Their public ExternalDNS and `wan-mode: public` metadata were removed. The
FreeSWITCH RTP LoadBalancer is rendered only when Kamailio or RTPEngine is not
providing the public media path.
