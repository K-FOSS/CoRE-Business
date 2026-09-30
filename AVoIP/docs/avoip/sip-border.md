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
