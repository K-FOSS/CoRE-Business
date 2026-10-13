# YXL to YVR inbound voice transfer

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
routes the YXL voice DID over the existing carrier Kamailio inter-site SIPS
link to YVR. YVR FreeSWITCH passes only extension `7101` to the existing
Asterisk SIP Core gateway. The general outbound pilot remains disabled. The
route uses the ordinary YVR carrier ClusterIP Service at `10.44.7.136:5061`;
it does not depend on the direct public SIP Service.

## Trust and call flow

1. Flowroute's configured source CIDR reaches YXL carrier Kamailio, which
   matches the exact voice DID and selects the YVR peer.
2. YXL carrier Kamailio connects to the YVR carrier ClusterIP over TLS. It
   presents its existing Vault-issued client certificate and uses the YVR
   TLSRoute SNI. The [Kamailio TLS module](https://www.kamailio.org/docs/modules/stable/modules/tls.html)
   selects the peer-specific client profile.
3. YVR carrier Kamailio requires the client certificate to verify, then checks
   both its SAN and the YXL carrier pod CIDR. It accepts a new INVITE only when
   the destination is `7101`; that route adds an internal marker and sends the
   call through YVR's existing FreeSWITCH backend.
4. FreeSWITCH's public context bridges `7101` only when the expected marker is
   present, using its existing authenticated Asterisk gateway. The
   [FreeSWITCH XML dialplan](https://developer.signalwire.com/freeswitch/dialplan/xml/)
   reads the inbound header as `sip_h_X-Core-InterSite`.
5. Asterisk's `from-external` context maps that exact number to its PJSIP
   extension `7101`, where the registered SIP Core endpoint rings.

In-dialog requests retain their originating or terminating site direction:
YVR returns YXL-originated dialog requests to the original Flowroute route;
YXL routes YVR-originated dialog requests to its local FreeSWITCH backend.
Kamailio's TOPOS route sets conceal the opposite-side targets. RTPEngine handles
SDP when enabled by the site's existing media values.

## Configuration and ownership

The Backplane ApplicationSet provides the peer data for the carrier instance
at each site. Its `interSite.peers` entry identifies the remote pod CIDR,
client-certificate SAN, service ClusterIP, service host, TLS server name, and
allowed extensions. YXL also has one `interSite.transfers` entry using the
secret-backed `avoipDID` and destination extension `7101`. YVR permits only
`7101` from YXL and enables its exact FreeSWITCH inter-site dialplan route.
The existing Vault mTLS `clientIdentity` configuration supplies both
certificates; no new key or secret is added.

Deployment ownership, cluster selection, namespace and Lovely value merge are
defined by the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The chart defaults leave inter-site routing disabled with empty peer and
transfer lists. Keep the route values at the owning ApplicationSet layer.

## Verification and rollback

Before reconciliation, render the chart with the YXL and YVR Lovely value
layers and check that the YXL transfer resolves to the YVR peer ClusterIP and
the secret-backed DID placeholder, while YVR accepts only extension `7101`.
Check that the rendered YVR public context requires the marker and the Asterisk
context contains only the exact configured extension route. Never print or
commit the resolved DID or TLS private key.

After scoped Argo CD reconciliation, verify both child Applications are
Synced/Healthy, the carrier and FreeSWITCH pods are ready, and the generated
Kamailio and FreeSWITCH configuration contains the expected peer, SNI,
certificate SAN, CIDR, exact DID and extension. Confirm the TLS connection
from YXL carrier pods to `10.44.7.136:5061` validates the server certificate
and presents the mounted Vault identity. A successful render or TLS handshake
does not prove that a voice call rings; the deployment operator should verify
the user-facing call path separately.

To roll back, remove the YXL `interSite.transfers` entry, remove the paired
peer entries, and disable the YVR FreeSWITCH inter-site route in the owning
ApplicationSet, then reconcile the same scoped Applications. This removes the
cross-site DID path while leaving each site's existing carrier TLS listener,
Vault certificate, and direct Service setting unchanged.

The [Asterisk PJSIP dialplan documentation](https://docs.asterisk.org/Configuration/Dialplan/)
describes extension routing used by the final hop.
