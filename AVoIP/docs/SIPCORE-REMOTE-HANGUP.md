# SIP Core remote hangup and retransmitted answers

The Home1 path is owned by the
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).
It selects Lovely, the `AVoIP` chart, namespace `core-prod`, the legacy
`internal` SBC and three `internal-websocket` connection owners. The repair
changes their Kamailio source template, not Asterisk, media, identity or storage
configuration.

## Confirmed failure

A 2026-10-18 inbound call answered in Home Assistant exposed this sequence:

1. Asterisk sent INVITE to the registered browser's owning WebSocket pod.
2. The browser's first 200 had a Contact alias added in the transaction-specific
   `SIPCORE_ASTERISK_REPLY` route. Its first ACK reached the browser.
3. The browser retransmitted 200. Kamailio's TM fast path bypassed that named
   reply handler, but TOPOS still stored the retransmission's unaliased Contact.
4. Later ACKs and Asterisk's remote BYE restored the browser's `.invalid`
   Contact without an alias. `check_flow_token()` returned -3 (no token),
   `loose_route()` succeeded, and `handle_ruri_alias()` returned 2 (no alias).
   Kamailio rejected the BYE before the WebSocket relay.
5. The browser remained active. Its later local BYE received 481 because
   Asterisk had already cleared its channel.

The first ACK succeeded; this was not a missing owner Service or a changed
INVITE CSeq. The defect existed before the INFO MIME fix. That fix did not
change Contact aliasing or the return-dialog checks. This failure is also
separate from the previously observed carrier-to-FreeSWITCH teardown delay
documented in [remote hangup latency](../../docs/remote-hangup-latency.md).

## FreeSWITCH profile selection on endpoint-originated sequential requests

The internal registrar-facing Kamailio has two distinct FreeSWITCH TLS
destinations. The `5072` service is the managed call-control handoff used for
new requests from a registered client. The `5061` profile is the FreeSWITCH
side that owns dialogs created when FreeSWITCH sends an INVITE to a registered
endpoint. They are not interchangeable SIP dialog contexts.

The live YVR configuration exposed a second routing defect: after TOPOS and
`loose_route_mode("1")` restored an inbound dialog Contact such as
`sip:...@<freeswitch-pod>:5061`, `route[FROM_SIPCORE]` unconditionally replaced
the destination with the `5072` managed service whenever the remaining route
set referenced the public SIP Core hostname. The SIP Request-URI therefore
still named the `5061` owner while the packet was delivered to `5072`, which
returned `481 Call Does Not Exist`.

The routing branch now preserves a restored target on the configured
FreeSWITCH backend port (`freeswitch.publicExposure.kamailio.backendPort`,
currently `5061`). The `5072` selection remains available for client-originated
dialogs whose restored target is not that backend profile. This applies to all
accepted in-dialog methods handled by `route[FROM_SIPCORE]`—including BYE,
re-INVITE, UPDATE, INFO, REFER, PRACK, and NOTIFY—rather than special-casing
BYE. The diagnostic stages `frontend-dialog-owner-preserved` and
`frontend-dialog-backend-route` make the choice visible without logging SIP
credentials or media keys.

A second failure was reproduced on 2026-10-22 with a native SIP/TLS client
originating a call. Its Contact used the same private IP and port Kamailio saw
as the TLS source. `add_contact_alias()` intentionally adds no alias in that
case; the `FROM_SIPCORE` route therefore forwarded the client Contact to
Asterisk unchanged. On hangup, Asterisk's BYE reached the correct owner pod but
had no alias for the live TLS flow and received `404 Frontend Contact Not
Found`.

After forcing the Contact alias, a subsequent short-call reproduction resolved
the alias but still failed at relay: the stored alias contained the client tuple
reported by PROXY v2, and Kamailio tried to open a new TLS connection to that
tuple. Envoy owns the accepted upstream connection, so Kamailio must route back
over that connection's actual peer tuple instead. The TLS listener now uses
Kamailio's `tcpops` `$tcp(c_si)` / `$tcp(c_sp)` values with the explicit
`add_contact_alias()` parameters for REGISTER and initial INVITE Contacts.
Other transports retain `set_contact_alias("1")`. The `$tcp()` values are the
connection peer tuple rather than the PROXY-advertised SIP source.

## Source repair

[Kamailio](https://www.kamailio.org/)'s
[core reply route](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#reply_route)
runs for network responses before TM's named handler. Browser Contact aliasing
now runs there, including on retransmitted answers. It is limited to the
SIP Core WebSocket and TLS listeners and excludes REGISTER replies so AOR
contact lists remain intact. Client-facing REGISTERs and initial INVITEs also
use a flow alias, replacing a client-supplied alias. On TLS/PROXY traffic the
alias is the actual Envoy peer tuple, so Kamailio can reuse its accepted TLS
connection; on WS and direct transports `set_contact_alias("1")` stores the
received flow address. This lets Asterisk return BYE/OPTIONS traffic through
the owning connection. The behavior relies on Kamailio's
[tcpops connection variables](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/pseudovariables/#tcpops-module-variable)
and [nathelper alias parameters](https://www.kamailio.org/docs/modules/6.1.x/modules/nathelper.html#nathelper.f.add_contact_alias).
The named reply handlers retain their SDP and response diagnostics. An explicit
`return` leaves core response processing successful; no local BYE
acknowledgment is introduced.

The [6.1.4 TOPOS implementation](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/topos/tps_msg.c)
still stores and restores the aliased Contact. The existing
[nathelper alias functions](https://www.kamailio.org/docs/modules/6.1.x/modules/nathelper.html#nathelper.f.handle_ruri_alias)
and owning-pod/flow-token validation remain authoritative for subsequent
requests. The repair adds no fallback to a shared Service, no destination cache,
and no permission to relay an unvalidated request. RTPEngine offer/answer,
DTMF classification, session identifiers and BYE cleanup are unchanged.

The Flowroute FreeSWITCH profile keeps its registration transport explicitly
UDP with `bind-params=transport=udp`, while its carrier-dialog listener remains
TLS on the configured owner port. This prevents Sofia from creating a plain TCP
listener on the TLS owner port during a profile reload. `reuse-connections=true`
also makes the intended FreeSWITCH outbound TCP/TLS connection reuse explicit;
Kamailio still routes restored carrier dialogs to the validated owner pod and
does not copy an ephemeral source port into a Contact or configuration value.

## Carrier BYE-loss fallback

The outbound carrier endpoint also uses Asterisk's PJSIP `rtp_timeout` as a
bounded safety net for a provider leg that stops sending media without sending
its in-dialog BYE. The chart default is 90 seconds. A normal carrier BYE still
clears the call immediately; the timeout applies only when carrier RTP is
absent. This does not repair a missing carrier BYE at the SIP layer, so runtime
validation must still correlate provider signaling, Kamailio relay, and the
Asterisk hangup separately.

## Validation

Run the structural/render regression:

```sh
python3 AVoIP/tests/sipcore-contact-retransmission.py
python3 AVoIP/tests/sipcore-info-routing.py
helm lint AVoIP
AVoIP/tests/wss-ha-render.sh
```

For runtime validation use `--config /path/to/rendered/kamailio.cfg --runtime`
with Kamailio 6.1.4, its matching `db_sqlite.so`, and its shipped SQLite TOPOS
schema. The custom heartbeat image contains a base-image SQLite module that
does not match its rebuilt binary; use the ordinary internal SBC image for
this isolated harness and the actual heartbeat image for configuration checks.
Do not bypass the module version check or use production Redis for the test.

The regression extracts the actual rendered core reply route. It adapts the
listener guard to an ephemeral UDP loopback listener and makes the synthetic
Contact equal the response source, reproducing the condition where
`add_contact_alias()` did nothing. It uses actual Kamailio TM, TOPOS and
nathelper with a temporary SQLite database. Its negative control reproduces
alias loss by putting the same handler in TM's named reply route. The fixed
case verifies the persisted alias survives the repeated 200, both ACKs and the
remote BYE reach the synthetic browser with original Call-ID/tags/CSeq, and the
browser's BYE 200 returns to the synthetic Asterisk endpoint. Static checks
also verify that client REGISTER and initial INVITE routes forcibly set aliases.
It does not itself prove TLS/WebSocket delivery or production Redis behavior.

Render the actual Application value layer through Lovely and check both
affected configurations with the deployed Kamailio 6.1.4 checker. Reconcile
only the reviewed Home1 Kamailio ConfigMaps; the existing Reloader performs
the owner rollout. Schema hooks and database provisioning do not need replay.
Wait for all owners to load the contact alias changes and for clients to
re-register, then test both a native TLS-originated and a WSS-originated
answered call with the remote party hanging up. Correlate Asterisk's BYE,
owner ingress, alias resolution, client delivery, and the BYE 200. Also confirm
local hangup and INFO DTMF. Log only dialog metadata, never SIP credentials,
DTMF bodies or PINs.

Rollback is a scoped corrective/revert commit and the same reconciliation;
it returns the alias-loss defect but requires no persistent data rollback.
