# SIP Core remote hangup and retransmitted answers

The Home1 path is owned by the
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
It selects Lovely, the `AVoIP` chart, namespace `core-prod`, the legacy
`internal` SBC and three `internal-websocket` connection owners. This repair
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

## Source repair

[Kamailio](https://www.kamailio.org/)'s
[core reply route](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#reply_route)
runs for network responses before TM's named handler. Browser Contact aliasing
now runs there, including on retransmitted answers. It is limited to the
existing SIP Core WebSocket listener and excludes REGISTER replies so AOR
contact lists remain intact. The named reply handlers retain their SDP and
response diagnostics. An explicit `return` leaves core response processing
successful; no local BYE acknowledgment is introduced.

The [6.1.4 TOPOS implementation](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/topos/tps_msg.c)
still stores and restores the aliased Contact. The existing
[nathelper alias handler](https://www.kamailio.org/docs/modules/6.1.x/modules/nathelper.html#nathelper.f.handle_ruri_alias)
and owning-pod/flow-token validation remain authoritative for subsequent
requests. The repair adds no fallback to a shared Service, no destination cache,
and no permission to relay an unvalidated request. RTPEngine offer/answer,
DTMF classification, session identifiers and BYE cleanup are unchanged.

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

The regression extracts the actual rendered core reply route. Only its WS
listener guard is adapted to an ephemeral UDP loopback listener; the test
uses actual Kamailio TM, TOPOS and nathelper with a temporary SQLite database.
Its negative control reproduces alias loss by putting the same handler in
TM's named reply route. The fixed case verifies the persisted alias survives
the repeated 200, both ACKs and the remote BYE reach the synthetic browser
with original Call-ID/tags/CSeq, and the browser's BYE 200 returns to the
synthetic Asterisk endpoint. It does not itself prove WebSocket delivery or
production Redis behavior.

Render the actual Application value layer through Lovely and check both
affected configurations with the deployed Kamailio 6.1.4 checker. Reconcile
only the reviewed Home1 Kamailio ConfigMaps; the existing Reloader performs
the owner rollout. Schema hooks and database provisioning do not need replay.
Wait for all owners to load the new core reply route, reconnect clients, then
test both an inbound and an outbound answered call with the remote party
hanging up. Correlate carrier/PBX teardown, Asterisk's BYE, owner ingress and
WebSocket egress, and the browser's BYE 200. Also confirm local hangup and INFO
DTMF. Log only dialog metadata, never SIP credentials, DTMF bodies or PINs.

Rollback is a scoped corrective/revert commit and the same reconciliation;
it returns the alias-loss defect but requires no persistent data rollback.
