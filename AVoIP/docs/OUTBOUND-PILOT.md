# Opt-in carrier outbound pilot

This records the chart's service-peer pilot. It does not authorize a billable
call. The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
configures Vault-backed mTLS identities at YXL and YVR, while
`carrierOutbound.calls.enabled` remains `false`.

## Signaling path

An authorized Asterisk-originated call reaches the internal Kamailio. The
internal Kamailio connects to the carrier through the existing SIPS Gateway
path and site SNI using its Vault-issued client identity. The carrier
validates the source range and client certificate SAN, then uses its existing
Flowroute trunk and carrier-owned RTPEngine path. Carrier-to-FreeSWITCH traffic
continues to use its existing private Service listener. The public site TLSRoute,
global SIP identity, public ACME certificate and its Secret path do not change;
there is no additional TLSRoute, SNI hostname, or Service. The shared SIPS
listener is owned by Backplane's [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml).

The existing public SIPS listener uses an optional client-certificate TLS
profile for its site SNI. The public ACME certificate and its Secret path stay
unchanged. The Certificate already contains that public site name; no extra
SAN is requested.
The private Kamailio trusts the carrier server certificate and presents its
separate Vault client certificate. The carrier trusts the internal Kamailio
client issuer. The chart's network policies restrict the private Kamailio's
5061 egress to the existing Gateway. Carrier ingress is limited to that
Gateway and the existing FreeSWITCH path; the internal request carries
PROXY v2 and is authenticated by its TLS certificate and source range.

The test pilot still allows only one configured extension, caller ID, and
non-premium NANP destination. Its carrier-wide Dragonfly quota allows one
call per minute and one concurrent call, with a 600-second maximum lifetime.
The ordinary Asterisk user authorization model must be connected before this
fixed pilot can represent general user outbound calling. Registration alone
does not grant PSTN access. New calls remain denied while
`carrierOutbound.calls.enabled` is false.

## Configuration and rollout

The owning [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
supplies site-specific peer service names, pod ranges, controller labels,
identity Secret references, and the existing `core-tls-vault` issuer. The
carrier's `peer` values identify the internal Kamailio client. The internal
instance's `peer` values identify the carrier service and its Vault-issued
identity. Both site role entries remain present because
`kamailio.instances[]` is a replace-only list.

Before enabling the fixed call pilot, verify both Vault certificates and
mounted CA bundles, the carrier's existing SIPS listener, scoped Cilium and
Kubernetes network policy, and the mTLS OPTIONS response. Then verify the
exact caller and destination rejection cases and quotas. A real carrier call
requires a separately reviewed, exact test route and a fresh inbound voice
and fax baseline. No automated check places a public call.

YXL keeps its direct public SIP Service disabled. Do not enable a direct
Service to use this Gateway path. It does not add a public LoadBalancer or
carrier ACL entry.

Rollback is to set `carrierOutbound.enabled: false` on the two Kamailio role
entries and reconcile the reviewed ApplicationSet. That removes the private
peer route and associated mTLS policy while preserving the public SIP route,
public certificate, Flowroute trunk, and existing FreeSWITCH connection.
Existing quota keys expire by the configured maximum duration; do not flush
the shared Dragonfly database.
