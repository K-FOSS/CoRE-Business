# Carrier outbound calling

The desired YVR configuration allows Asterisk SIP Core account `7101` to
place standard NANP calls through the existing carrier Kamailio and Flowroute
connection. The carrier-facing caller ID is sourced from `avoip.did`, the
configured voice DID. YXL keeps PSTN call
origination disabled. This route has not yet been reconciled or verified with
a live carrier call.
The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
configures this policy and the Vault-backed mTLS identities.

## Signaling path

Account `7101` dials a `+1` E.164 number in Asterisk. Asterisk sends the call
through its dedicated `carrier-outbound` PJSIP endpoint to the existing
internal Kamailio TLS return service on port `5063`. This keeps the browser
contacts' saved WSS Path routing intact. Internal
Kamailio admits only configured SIP Core accounts and sends the call through
the existing SIPS Gateway path and site SNI using its Vault-issued client
identity. Carrier Kamailio validates the source range and client certificate
SAN, applies destination and quota checks, then uses its existing Flowroute
trunk and carrier-owned RTPEngine path. Carrier-to-FreeSWITCH traffic
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

Only standard NANP destinations are routed. `+1900` and `+1` 976 service
numbers are rejected. The internal policy first authenticates account `7101`,
then both Kamailio hops set the carrier-facing From and P-Asserted-Identity
from `avoip.did`. The compatibility value `carrierOutbound.calls.callerId`
does not control NANP caller ID. The carrier Kamailio prepends the Flowroute
registration username and `*` to the called E.164 user part as Flowroute's
IP-auth Tech Prefix. Flowroute accepts the optional leading `+` in the E.164
user part. That username is read from the existing Vault reference
into a separate username-only Secret and injected only into the carrier
Kamailio pod; it is never rendered into a ConfigMap or logged. See Flowroute's
[IP-based authentication format](https://support.bcmone.com/flowroute-support/docs/set-up-ip-based-authentication-for-outbound-calls).
The existing FreeSWITCH SIP registration remains enabled; adding the prefix
does not change the authentication method. Flowroute IP authentication
requires a static public egress IP and account-side allowlisting. Registration
alone does not grant PSTN access. Carrier-wide Dragonfly quota allows one call per minute
and one concurrent call, with a 600-second maximum lifetime.

## Configuration and rollout

The owning [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
supplies site-specific peer service names, pod ranges, controller labels,
identity Secret references, and the existing `core-tls-vault` issuer. The
carrier's `peer` values identify the internal Kamailio client. The internal
instance's `peer` values identify the carrier service and its Vault-issued
identity. Both site role entries remain present because
`kamailio.instances[]` is a replace-only list.

Before rollout, verify both Vault certificates and mounted CA bundles, the
carrier's existing SIPS listener, scoped Cilium and Kubernetes network policy,
and the mTLS OPTIONS response. Then verify the caller and destination rejection
cases and quotas. A real carrier call is billable; no automated check places a
public call.

YXL keeps its direct public SIP Service disabled. Do not enable a direct
Service to use this Gateway path. It does not add a public LoadBalancer or
carrier ACL entry.

Rollback is to set `carrierOutbound.enabled: false` on the two Kamailio role
entries and reconcile the reviewed ApplicationSet. That removes the private
peer route and associated mTLS policy while preserving the public SIP route,
public certificate, Flowroute trunk, and existing FreeSWITCH connection.
Existing quota keys expire by the configured maximum duration; do not flush
the shared Dragonfly database.
