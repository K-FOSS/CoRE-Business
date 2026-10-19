# Asterisk managed outbound BYE return routing

The Asterisk `carrier-outbound` endpoint sends its initial request to the
private Kamailio SIP Core listener. Its in-dialog requests must return through
the dedicated `sipcore-return` Service and port configured by
`asterisk.sipCore.privateEgressPort`.

## Evidence and correction

YVR's Asterisk log recorded answered extension 7101 calls, followed by Asterisk
sending BYE on `carrier-outbound` and receiving `403 Source Not Authorized`.
Kamailio logs also recorded BYE requests arriving at the carrier-facing
`public_tls` listener from an untrusted source and receiving the source/socket
rejection. That is consistent with a dialog Record-Route selected from an
upstream-facing socket rather than Asterisk's private return listener.

The managed-extension route now uses `record_route_preset()` with the
site-local `sipcore-return` Service and dedicated Asterisk TLS port for the
Asterisk SIP Core side. Other private Kamailio peers retain the existing
`record_route()` behavior. This keeps the return route independent of provider
selection and preserves source authentication at both listeners.

Kamailio emits Homer events for the private BYE relay attempt, queued relay,
final response status, and transaction failure. These events retain Call-ID,
CSeq, dialog tags, direction and peer identity, but omit phone numbers, SDP and
SIP credentials.

## Validation and rollout

`AVoIP/tests/managed-outbound-identity-render.sh` verifies the generated
private return route and teardown events. The Admin routing snapshot also
carries optional exact E.164 destination allow and block lists per extension;
empty lists preserve the existing platform NANP policy. Kamailio enforces the
restrictions before provider routing and records denials in Homer.

After the chart and Admin image are published, reconcile only the affected
AVoIP Admin Deployment and internal Kamailio configuration. Verify the
resulting pods load the new image and configuration. A live answered-call
BYE/200 exchange is still required to prove the deployed route end to end; do
not treat successful rendering or pod readiness as that proof. Roll back with a
scoped Git revert and reconcile the same resources if new calls fail.
