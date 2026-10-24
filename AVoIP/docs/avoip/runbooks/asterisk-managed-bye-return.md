# Asterisk managed outbound BYE return routing

> Historical runbook: the current YVR Asterisk role is voicemail-only and it no
> longer originates carrier calls. Use the [managed carrier egress runbook](../../OUTBOUND-PILOT.md)
> for the active FreeSWITCH/Kamailio signaling path. The trace below documents
> the former Asterisk-originated route and is retained for incident history.

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
final response status, and transaction failure. Reply and failure callbacks
now read the selected side, peer, destination, transport and socket from
transaction-scoped XAVPs rather than request-local variables. Failure events
also report the final reply code, whether the branch timed out, and whether it
received an earlier reply, using TM's `t_get_status_code()`,
`t_branch_timeout()` and `t_branch_replied()` functions. This keeps the
diagnosis within the deployed TM module and does not require TMX.
Events retain Call-ID, CSeq and dialog tags, but omit phone numbers, SDP and SIP
credentials. The Admin-generated FreeSWITCH outbound leg also carries the
validated Asterisk linked ID and unique ID over trusted internal hops, allowing
Homer to correlate the Asterisk, FreeSWITCH and Kamailio records. Kamailio
copies those values into its dialog state and removes the CoRE-only identity
headers before the provider-facing INVITE.

The YVR trace at 2026-10-19 21:12 UTC showed both FreeSWITCH call legs ending
with terminal hangup events, while its corresponding Kamailio BYE transaction
timed out without a recorded final response. That confirms teardown at
FreeSWITCH and a signaling response gap on the proxy transaction; it does not
prove that the remote SIP peer received a successful BYE. The richer failure
event distinguishes a timeout from a final rejection on the next teardown.

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
