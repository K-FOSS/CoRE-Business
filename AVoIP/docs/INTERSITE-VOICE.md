# YXL to YVR inbound voice routing

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
routes both YXL inbound DIDs over the existing carrier Kamailio inter-site
SIPS link to YVR. The voice DID enters YVR's silent FreeSWITCH IVR at internal
extension `7102`; the FaxNumber DID reaches Asterisk SIP Core extension
`7101` directly. YVR Asterisk SIP Core account `7101` can also originate
standard NANP calls through the same internal-to-carrier mTLS connection. The
inter-site route uses the ordinary YVR carrier ClusterIP Service at
`10.44.7.136:5061`; it does not depend on the direct public SIP Service.

## Trust and call flow

1. Flowroute's configured source CIDR reaches YXL carrier Kamailio, which
   matches the called DID in the SIP `To` URI and selects the YVR peer. Flowroute
   may include a leading `+`; Kamailio accepts either form. The Request-URI
   carries Flowroute's rendezvous user, so it is not used for DID matching.
2. YXL carrier Kamailio connects to the YVR carrier ClusterIP at Service port
   `5061`, which maps to Kamailio's `public_tls` container listener on `5061`.
   It presents its existing Vault-issued client certificate and uses YVR's
   configured `carrierOutbound.sniHost` as SNI. The [Kamailio TLS module](https://www.kamailio.org/docs/modules/stable/modules/tls.html)
   selects the peer-specific client profile. Each carrier instance also has a
   server TLS profile for that configured SNI. It verifies a presented client
   certificate against the existing peer CA while leaving the TLS-level
   certificate optional for public carrier traffic; SIP authorization then
   requires successful peer verification, the exact configured SAN and pod
   CIDR, and the exact allowed extension.
3. YVR carrier Kamailio requires the client certificate to verify, then checks
   both its SAN and the YXL carrier pod CIDR. It accepts a new INVITE only for
   `7101` or `7102`; that route adds an internal marker and sends the call to
   YVR's existing FreeSWITCH backend.
4. FreeSWITCH requires the marker. Extension `7101` bridges to the existing
   authenticated Asterisk gateway. Extension `7102` enters the silent digit
   collector. YVR's local voice DID enters that same collector directly.
   Callers can type only `7101`, `9090`, `66`, or `1234`; FreeSWITCH validates
   the exact allowlist before passing the selected destination through its
   local Asterisk gateway. The
   [FreeSWITCH XML dialplan](https://developer.signalwire.com/freeswitch/dialplan/xml/)
   reads the inter-site identity from `sip_h_X-Core-InterSite`.
5. YXL and YVR FaxNumber DIDs bridge to YVR Asterisk extension `7101`. The
   Asterisk DID route does not send early media before dialing, allowing
   normal ringing when the endpoint is available. An unanswered selected
   endpoint is released after 30 seconds.

In-dialog requests retain their originating or terminating site direction:
YVR returns YXL-originated dialog requests to the original Flowroute route;
YXL routes YVR-originated dialog requests to its local FreeSWITCH backend.
Kamailio's TOPOS route sets conceal the opposite-side targets. RTPEngine handles
SDP when enabled by the site's existing media values. Kamailio loads
`dialog.so` whenever `carrierOutbound` is enabled or a private instance has
inter-site peers or transfers; `dlg_manage()` and `$dlg_var()` store the
direction metadata used for those in-dialog routes.

## Configuration and ownership

The Backplane ApplicationSet provides the peer data for the carrier instance
at each site. Its `interSite.peers` entry identifies the remote pod CIDR,
client-certificate SAN, service ClusterIP, service host, TLS server name, and
allowed ingress extensions. YXL's `interSite.transfers` entries select peer
`yvr`, sending `avoip.did` to `7102` and `fax.did` to `7101`. The DID values
come from existing secret-backed references; they are not duplicated in the
peer configuration. YVR permits only those two ingress extensions from YXL.
The IVR's Asterisk destination allowlist is a separate local FreeSWITCH value
and does not widen the inter-site peer authorization.

The existing Vault mTLS `clientIdentity` configuration supplies both
certificates; no new key or Secret is added. Deployment ownership, cluster
selection, namespace and Lovely value merge are defined by the
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The chart defaults leave inter-site routing and the IVR disabled with empty
peer and transfer lists. Keep the route values at the owning ApplicationSet
layer.

The public carrier listener and the private application listener have distinct
roles. The carrier Service maps `5061` to `tls-public`/container `5061`, and
the private service port `5062` maps to `tls-private`/container `5062`. New
intersite INVITEs intentionally use Service port `5061` and enter `public_tls`
so they follow the carrier routing and extension authorization path. The
carrier NetworkPolicy permits only the configured intersite peer CIDRs on
`5061` and only the configured remote peer Service IP on egress `5061`; public
carrier CIDRs and Envoy remain separately configured. The
`Contact` value on an INVITE is not what selects that receiving listener. In
the generated carrier routing, the local/private URI on `5062` is part of the
paired Record-Route topology used by TOPOS and the backend-facing dialog leg;
the intersite next hop remains the peer Service on `5061`. A `5062` Contact
alone therefore does not explain a rejection on the initial INVITE. Verify
subsequent ACK, CANCEL, BYE and response routing from a live ladder before
claiming dialog health.

For the reported rejection, Home1's logs showed the transport peer addresses
inside YXL's configured `172.20.48.0/22`; the presented client certificate SAN
matched the configured YXL service identity. The failing predicate was
`$tls_peer_verified`: the intersite client sent
`sip-outbound.core-home1-talos-prod.home1.yvr.resolvemy.host` as SNI, while the
server verification profile had been selected only for the public
`sip.core-home1-talos-prod.home1.yvr.resolvemy.host` SNI. The default TLS
profile did not verify client certificates, so the SIP source guard returned
`403 Source Not Authorized`. The chart now configures the same optional-client
certificate verification profile for the site's existing outbound SNI in both
directions. The SIP source, SAN, and extension checks remain in force.

## Verification and rollback

Before reconciliation, render the chart with the YXL and YVR Lovely value
layers. Check that the two YXL transfers resolve to the YVR peer ClusterIP and
secret-backed DID placeholders, while YVR accepts only ingress extensions
`7101` and `7102`. Confirm the rendered YVR public context requires the
inter-site marker, the IVR has no prompt assets, and the Asterisk context
contains only its configured DID and IVR destination routes. Never print or
commit resolved DIDs or TLS private keys.

After scoped Argo CD reconciliation, verify the affected child Applications
are Synced/Healthy, the carrier and FreeSWITCH pods are ready, and the
generated Kamailio and FreeSWITCH configuration contains the expected peer,
SNI, certificate SAN, CIDR, DID match and ingress extension. Confirm the TLS
connection from YXL carrier pods to `10.44.7.136:5061` validates the server
certificate and presents the mounted Vault identity. A successful render or
TLS handshake does not prove that a voice call rings; verify the user-facing
call paths separately.

To roll back, remove both YXL `interSite.transfers` entries, remove ingress
extension `7102` from the YVR peer allowlist, and disable the YVR FreeSWITCH
IVR and inter-site routes in the owning ApplicationSet, then reconcile the
same scoped Applications. This removes the cross-site DID routes while
leaving each site's carrier TLS listener, Vault certificate, and direct
Service settings in place.

The [Asterisk PJSIP dialplan documentation](https://docs.asterisk.org/Configuration/Dialplan/)
describes extension routing used by the final hop.
