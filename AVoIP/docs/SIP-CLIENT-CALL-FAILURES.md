# Registered-client call failures at FreeSWITCH

## Observed evidence

During the 2026-10-23 YVR monitoring window, the IVR attempted
`sofia/gateway/sipcore-registrar/7101` but FreeSWITCH immediately returned
`NORMAL_TEMPORARY_FAILURE`/SIP 503. The registrar owner pod logged a TLS
certificate verification failure from the FreeSWITCH pod on the private
registrar listener (5062). This proves the call was failing at the
FreeSWITCH-to-Kamailio mutual-TLS handshake, before contact lookup or device
delivery; a successful 7101 registration alone was not sufficient evidence
that the IVR path worked.

On 2026-10-22, FreeSWITCH received INVITEs on its Kamailio-facing TLS profile
from the internal Kamailio pods. Calls for SIP Core user `7101` then ended in
`CS_NEW` with `INCOMPATIBLE_DESTINATION`. The media log also said
`NO candidate ACL defined, Defaulting to wan.auto`. Representative observed
Call-IDs include `BAFE65B791D94CE0F82E2BA9B91434EB5CDA66B8` and
`AD630248CE77178FA23B3967626172FF999004D2`.

The live profile had `apply-inbound-acl=kamailio`; the loaded `kamailio` ACL
allowed the internal pod network, and the observed Kamailio source address
was inside that range. The request reached FreeSWITCH, so this is not evidence
of a source-IP ACL rejection. The candidate warning is a separate media ACL:
FreeSWITCH applies it to SDP ICE candidates, not to SIP request sources.
The captured SDP was not available for this inspection, so the warning alone
does not prove which candidate caused each `INCOMPATIBLE_DESTINATION` result.

## Implemented configuration

The FreeSWITCH profiles that receive the internal Kamailio hop now configure
two repeatable FreeSWITCH
`apply-candidate-acl` entries: `localnet.auto` and `wan.auto`. That preserves
acceptance of public candidates while also allowing private ICE candidates
used by Home Assistant/browser clients. The existing `kamailio`
`apply-inbound-acl` remains unchanged. This includes the operational
`core-managed` profile on port 5072, which is used by the current AVoIP
Admin-managed call path. FreeSWITCH documents these as distinct
controls: [Sofia SIP profile parameters](https://developer.signalwire.com/freeswitch/users-and-endpoints/sip-profiles/)
and [ACL behavior](https://developer.signalwire.com/freeswitch/integration/acls/).

Signaling remains:

```text
WSS or SIP-TLS client
  -> public Kamailio ingress / HA registered-contact owner
  -> private TLS Kamailio-to-FreeSWITCH hop
  -> FreeSWITCH call policy and dialplan
  -> sipcore-registrar TLS gateway for registered destinations
  -> Kamailio contact lookup and owner flow
```

The candidate ACL is evaluated on FreeSWITCH's Kamailio-facing profile. It
does not alter Kamailio registration ownership, SIP peer authorization,
Contact routing, or the public client registration endpoint. FreeSWITCH
source authorization continues to use its `kamailio` ACL.

The private listener also emits a bounded warning when a SIP peer fails the
TLS verification/source-CIDR identity gate. It records only the pod, peer
address, transport, listener port, verified flag, peer SAN, method and Call-ID;
it does not log SIP authorization headers or bodies. This distinguishes a
FreeSWITCH-to-registrar peer-ACL rejection from a later user/contact lookup
failure.

The first trust-bundle correction was not sufficient for the live handoff:
FreeSWITCH was presenting its ordinary SIP server certificate as a client
certificate. That certificate chains correctly, but it is not a client-auth
identity, so Kamailio rejected the mTLS handshake before SIP routing. The
chart now issues a separate `freeswitch-kamailio-client-tls` certificate with
both server-auth and client-auth usage, mounts it only into FreeSWITCH's
Kamailio profile, and pins Kamailio's private peer trust bundle to that
certificate chain. The normal FreeSWITCH SIP server certificate remains the
server certificate for its other profiles; no FreeSWITCH private key is
mounted into Kamailio. Certificate verification, the source CIDR gate, and
the peer SAN checks remain required.

The private listener also shares a Kamailio process with the public TLSRoute.
That process may accept PROXY v2 on the public path, but the FreeSWITCH
gateway connects directly to the Kubernetes Service and cannot emit PROXY
v2. The handoff must therefore be validated as a direct TLS/mTLS connection;
it must not depend on the public Envoy connection or a client ephemeral port.

## Verification and recovery

Render the chart with the HA registrar fixture and run
`bash AVoIP/tests/sip-registrar-ha-render.sh`. The test parses the generated
Sofia XML and asserts the existing inbound ACL plus both candidate ACLs.
It also asserts the dedicated client-auth certificate and FreeSWITCH
`tls-kamailio` material. After deployment, verify the Kamailio 5062 TLS
listener sees the FreeSWITCH peer SAN as verified and logs
`stage=asterisk-ingress` followed by the registrar destination lookup; a
FreeSWITCH `NORMAL_TEMPORARY_FAILURE` with no corresponding Kamailio SIP
request indicates the TLS handshake still failed.
After deployment, inspect the final live `kamailio.xml` ConfigMap and verify
that both candidate ACL parameters are present, then check FreeSWITCH logs for
the disappearance of the missing-candidate-ACL warning. Place calls from both
a WSS client and a native SIP-TLS client to an internal extension, then
verify the outbound INVITE reaches FreeSWITCH, the registrar gateway sends
the call to the correct registered Contact, and an answered dialog completes
ACK and BYE in both directions. Confirm media in both directions and retain
the call for at least 40 seconds.

Rollback by restoring the prior `freeswitch.sipCore.candidateACLs` value or
removing the two rendered parameters and reconciling the owning application.
This restores FreeSWITCH's implicit `wan.auto` candidate behavior. It does not
change registration or SIP routing state.

The source ACL was confirmed permissive for the observed in-cluster Kamailio
source; the exact SDP-level trigger for each historical failure remains
unverified. The change addresses the demonstrated omission of private ICE
candidates, but live calls must confirm that media negotiation was the
remaining blocker. A successful render or a missing warning alone is not
proof that WSS and native TLS calling work end to end.
