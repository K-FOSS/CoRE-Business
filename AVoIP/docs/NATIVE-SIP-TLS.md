# Native SIP-over-TLS dialog and media troubleshooting

This runbook covers the YVR/Home1 native TLS phone path alongside the
PostgreSQL-backed Kamailio registrar rollout. The owning deployment is the
[AVoIP ApplicationSet](https://slop.writemy.codes/K-FOSS/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).
Its Lovely-injected site values, not chart defaults, select the three-replica
client-facing Kamailio instance, registrar, FreeSWITCH call control, and
Asterisk voicemail. AVoIP Admin remains the operational configuration owner.
The registrar uses the site PostgreSQL `User` claim and libpq's system CA
bundle with `verify-full`; the credential-sync Job and the serving Kamailio
container must both receive that CA path. A missing path prevents pods from
starting even when schema creation succeeds. During the YVR rollout, the
serving pods also logged Kamailio's warning that `tls.so` must be loaded
first, consistent with the [TLS module's ordering requirement](https://www.kamailio.org/docs/modules/6.1.x/modules/tls.html),
then forked registrar workers timed out opening libpq TLS sessions
although `psql` from the same pod succeeded. The module is now loaded before
other modules; verify this removes the warning and startup timeouts. The
warning and timeout were observed together, but loading `tls.so` first did
not remove the timeout. TCP connections reached the PostgreSQL pod and ten
parallel `psql` sessions from a frontend pod succeeded, while the forked
Kamailio workers failed under a five-second libpq deadline. The serving
registrar's connection deadline is now 30 seconds, with `verify-full` and the
site CA unchanged. Two newly rolled frontend pods remained ready for more than
four minutes, but a longer observation is needed before the startup race can
be considered closed. The YVR ApplicationSet now uses preferred pod
anti-affinity and soft topology spreading for both three-replica internal
Kamailio sets because hard pod separation plus available CPU prevented a
third pod from scheduling. This permits co-location and does not guarantee
three-node fault isolation.
The public TLSRoute and Gateway listener pass TLS through Envoy with PROXY v2;
Kamailio presents the dedicated public certificate for
`sipcore.mylogin.space:8443`. Browser WSS signaling keeps its own listener.

## Evidence and cause

The 2026-10-22 capture of Call-ID
`A002F691E1C1085ACFADD25CCB9EE52670F7F711` shows an authenticated INVITE
answered at 19:53:09.998604Z, but the answer delivered to Groundwire carried
the internal owner DNS name and port 5063 in Contact. No client ACK appears in
the supplied trace; Asterisk retransmitted 200 and ended the call about 32
seconds later with a 408 BYE. The Contact was not externally usable. The
missing ACK is consistent with that defect, but the supplied capture does not
prove Groundwire's DNS or connection decision.

Source confirms the old single `record_route_preset()` advertised only the
owner-pod route. [Kamailio TOPOS](https://www.kamailio.org/docs/modules/6.1.x/modules/topos.html)
derives its masked Contact host from that route; its `tps` token carries the
topology lookup, not a usable public network path. The native TLS initial
INVITE now uses a double Record-Route: the private owner on the outbound leg
and the public TLS host/port on the inbound leg. TOPOS retains the token and
stored route set. When a different frontend replica receives a later ACK,
BYE, INFO, UPDATE or re-INVITE, it forwards the restored dialog to the named
owner before that owner resumes client-side routing. The inter-pod marker is
removed from public requests and accepted only on the Cilium-restricted owner
listener. Internal owner DNS remains on the server-facing leg.

The same Call-ID's first client-facing 200 had the RTPEngine media address,
while 200 retransmissions from 19:53:10.500795Z exposed Asterisk's pod SDP,
ICE credentials and DTLS fingerprint. Source confirms TM's named onreply
handler is not used for late 2xx copies, so its prior media rewrite was not
repeatable. The SIPCore client-answer rewrite now runs once per incoming wire
copy in the global reply route on the internal response leg, identified by the
owner Record-Route. The named callback no longer transforms that answer a
second time. [RTPEngine manage](https://www.kamailio.org/docs/modules/6.1.x/modules/rtpengine.html)
selects the existing Call-ID/tag answer operation; it does not create a new
dialog for each 200. WebRTC flags remain on browser offers/answers only;
native TLS offers are not forced from RTP/AVP or RTP/SAVP to DTLS-SRTP by the
frontend. Final SDP must be checked after TOPOS, including all media sections,
ICE candidates/credentials, fingerprints and codecs.

For Call-ID `9A0EECA7BC10B23AD596CBC25841E0779C0C9835`, the supplied
BYE diagnostic selected Envoy peer `172.20.56.242:50726` but Kamailio then
opened a *new* outbound connection to that ephemeral port; Envoy refused it.
The address is the YVR main-Gateway Envoy pod, not Groundwire. PROXY v2 gives
Kamailio the phone's logical address, while `$tcp(c_si):$tcp(c_sp)` gives the
actual accepted Envoy peer. `handle_ruri_alias()` only sets the destination;
the old `onsend_route` `$conid=3` diagnostic referred to the incoming
connection and did not prove the outbound send selected it. The owner now
resolves the alias to a live local connection ID and explicitly sets the
outbound TCP ID before relay. If missing, it returns 430 (or drops an ACK),
never dials Envoy's ephemeral source port. A process-local dialog-to-connection
pin prevents an older dialog from migrating onto an unrelated new flow that
reuses the same peer tuple. Redis-backed TOPOS and PostgreSQL registration do
**not** replicate a live TCP/TLS socket. See
[Kamailio tcpops](https://www.kamailio.org/docs/modules/6.1.x/modules/tcpops.html)
for the connection lookup, liveness and outbound-ID functions.

The reported `automatic string to int conversion for "sipcore" failed`
appeared at changing generated line numbers, including 862 and 889. The
source-side `side` marker is a string, while `==` can infer integer conversion
in a mixed or undefined context. Comparisons in the response/send and relay
paths now use explicit `eq`/`ne` string operators, per the
[Kamailio core expression rules](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/).
This is a source-confirmed type hazard; the exact historical generated line
cannot be reconstructed from the supplied excerpts alone. The render
regression guards the corrected expressions; live logs must confirm the
warning disappears.

At 21:32–21:34 UTC on 2026-10-22, Groundwire's 7101 TLS INVITEs (for example
Call-ID `8F6944329CC684E28908EDCAC2B9D01CFB1291CD`) passed frontend
authentication but FreeSWITCH's `core-managed` listener returned 407. No 200,
ACK or media exchange occurred on these attempts. Source inspection found
that the frontend did not consume the client's `Proxy-Authorization` header
after successful Digest authentication, so it forwarded device credentials
across the separate FreeSWITCH trust boundary. The frontend now consumes the
authorized credential and strips all remaining Authorization headers before
relaying. That credential propagation is source-confirmed, and the next live
call no longer received FreeSWITCH's 407. This supports the fix but does not
prove which of the forwarded headers triggered that challenge. Do not log the
credential or its Digest response.

The later 21:51:39 UTC Groundwire attempt, Call-ID
`D62FB3296823E85460DFB70CF9ADCB04B8A34285`, passed that authentication
handoff; FreeSWITCH instead rejected its initial SDP with `488 Not Acceptable
Here` and Q.850 cause 88 (`INCOMPATIBLE_DESTINATION`). The received offer and
the offer sent to FreeSWITCH both contained two audio sections, `RTP/AVP` and
`RTP/SAVP`, with shared codec IDs. RTPEngine changed the two phone-offered
SDES suites into twelve suites per section on the internal leg. These facts
were checked from the newly captured call by selecting only media transport,
suite **names** and status metadata; no keying material was printed. This
suite expansion is source- and trace-confirmed, but its precise contribution
to FreeSWITCH's 488 is not yet proven. The native-TLS offer now uses
[`SDES-nonew`](https://github.com/sipwise/rtpengine/blob/master/docs/ng_control_protocol.md)
so the internal offer retains only the phone-offered suites. Browser WebRTC
continues to use its separate DTLS/ICE policy. Recheck both `m=` sections and
the answer after this change; do not treat a 488 disappearing as proof that
audio or dialog routing works.

## Signaling and ownership

Groundwire connects to `sipcore.mylogin.space:8443` through the main Gateway
TLSRoute, Envoy, and the TLS 5064 frontend listener. Envoy passes TLS and
PROXY v2 rather than terminating SIP TLS. The frontend authenticates against
the Kamailio PostgreSQL registrar and sends ordinary calls to FreeSWITCH over
the internal TLS 5062 socket. Asterisk remains for voicemail. The per-pod
owner listener is TLS 5063. The external client sees only the public dialog
target; backend Route/Contact and registrar Path may contain the owner DNS.
TOPOS tokens restore signaling state across replicas, then the owner uses its
own established Envoy connection for client-bound requests. The public
certificate remains separate from the internal certificate; neither client
DNS access to Kubernetes nor certificate exceptions are expected.

## Reproduce and verify

Run `AVoIP/tests/sipcore-native-tls-render.py --runtime-image
ghcr.io/kamailio/kamailio:6.1.4-bookworm` and
`AVoIP/tests/sipcore-contact-retransmission.py --runtime --runtime-image
ghcr.io/kamailio/kamailio:6.1.4-bookworm`, and
`AVoIP/tests/sipcore-sdp-retransmission.py --runtime-image
ghcr.io/kamailio/kamailio:6.1.4-bookworm` where Podman is available, plus Helm lint/template
with the [AVoIP ApplicationSet](https://slop.writemy.codes/K-FOSS/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
`LOVELY_HELM_MERGE` values. The contact harness inspects the **received**
post-TOPOS response; a pre-TOPOS dump is insufficient. Validate the generated
Kamailio config with the pinned 6.1.4 parser. Keep raw SIP/SDP dumps disabled
in routine logs: Authorization, ICE passwords and keying material are secret.

After scoped Argo reconciliation, confirm the registrar credential-sync Job
completes, all three frontend pods are ready, and registrations remain on
their owner. Place authenticated Groundwire calls to internal 66/67 and
voicemail `*97`. Correlate Call-ID and CSeq across frontend, FreeSWITCH,
Asterisk where relevant, and RTPEngine. Confirm INVITE → 200 → ACK reaches
call control; the call lasts beyond 32 seconds; both audio directions work;
both BYE directions receive 200; INFO/DTMF, UPDATE and re-INVITE route
correctly. Repeat with a fresh connection, reused connection, different
frontend replica, and browser WSS registration/calling. Inspect final
client-facing Contact/SDP and actual selected outbound connection, not just
alias creation or pod readiness. Check that no new connect targets an Envoy
ephemeral port, no FreeSWITCH 407 recurs after frontend authentication, and no
`sipcore` integer-conversion warning recurs.

## Recovery and limits

If the owner pod restarts, its TLS socket and local connection pin disappear.
Existing dialogs cannot be transferred by Redis or PostgreSQL and should fail
explicitly; the phone must reconnect/re-register and start a new dialog.
Do not redirect an old call to a newly accepted connection. For a failed
rollout, use a new, reviewed Git commit restoring the previous AVoIP chart
behavior and scoped Argo reconciliation; avoid direct workload edits. Recheck
registration ownership and browser WSS calls during rollback. The remaining
runtime assumptions—Envoy connection lifetime, TOPOS route restoration on a
different replica, final Contact/SDP, and RTPEngine's exact native-SRTP
negotiation—require the live checks above; static rendering does not prove a
successful call.
