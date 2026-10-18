# SIP Core INFO routing and ACK verification

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
deploys Home1's `internal-websocket` owners and the legacy `internal` private
SBC into `core-prod`, using Lovely's Helm values layer followed by this
chart's Kustomize patches. Home Assistant reaches the owner over
`wss://sipcore.mylogin.space/ws`; the owner relays SIP to Asterisk over TLS.

## MIME classification

[Kamailio](https://www.kamailio.org/)'s
[6.1.4 textops implementation](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/textops/textops.c)
implements `has_body(type)` by comparing numeric MIME identifiers. Its
[MIME parser](https://github.com/kamailio/kamailio/blob/6.1.4/src/core/parser/parse_content.c)
maps unrecognized application subtypes to the same identifier. Consequently,
`has_body("application/trickle-ice-sdpfrag")` also matched
`application/dtmf-relay` and other unknown application subtypes. RTPEngine
then rejected DTMF as an invalid SDP fragment and the browser received 503.

`SIPCORE_CONTENT_TYPE` reads the parsed Content-Type header through `$cT`,
extracts the media type before MIME parameters, trims whitespace, and folds
case using Kamailio 6.1 string transformations. Both private SIP Core request
routes call it after their existing listener, dialog, Route, and connection
owner checks. There is no early INFO relay or new authorization path.

| Request body | Processing |
| --- | --- |
| Nonempty `application/trickle-ice-sdpfrag` INFO | Existing `rtpengine_info()` handler; local 200 only after a successful media update, otherwise 503 |
| `application/dtmf-relay` INFO | Existing dialog relay to Asterisk; preserve body, Content-Type, Call-ID, tags and CSeq; return Asterisk's response |
| Other INFO | Existing endpoint/dialog policy and relay; never classify as ICE merely because it has an application body |
| `application/sdp` | Existing SDP offer/answer handling |
| BYE/CANCEL | Existing media and transaction cleanup |

The two ICE interception points are in `FROM_SIPCORE` and
`FROM_SIPCORE_ASTERISK`. The other SIP Core request/reply handlers and generic
media routes retain their `application/sdp` guards. No RTPEngine instance/set,
session identifier, WebRTC flags, ICE/DTLS-SRTP, codecs, RTCP multiplexing,
telephone-event negotiation, or deletion behavior changes. The existing
[RTPEngine](https://rtpengine.com/)
[Kamailio integration](https://www.kamailio.org/docs/modules/6.1.x/modules/rtpengine.html)
handles genuine fragments; this fix introduces no DTMF synthesis or injection.

## Asterisk receive behavior

Read-only inspection on 2026-10-18 found Asterisk 20.20.1, endpoint `7101`
using `dtmf_mode=rfc4733`, and `res_pjsip_dtmf_info.so` loaded. The
[Asterisk](https://www.asterisk.org/)
[20 INFO handler](https://github.com/asterisk/asterisk/blob/20/res/res_pjsip_dtmf_info.c)
accepts `application/dtmf-relay`, queues a valid digit as a DTMF frame to the
active channel, and sends the downstream response independently of the
endpoint's transmit DTMF mode. Keep RTP-event clients and trunk settings as
configured. No endpoint, mailbox identity, authentication, PostgreSQL voicemail
or storage changes are needed. Delivery to a live VoiceMailMain application
still requires the acceptance test below.

## Regression checks

Run from the repository root:

```sh
helm dependency build AVoIP
helm lint AVoIP
python3 AVoIP/tests/sipcore-info-routing.py
AVoIP/tests/wss-ha-render.sh
AVoIP/tests/rtpengine-redis-rollout-render.sh
```

The Python check renders the HA fixture and verifies both interception points
follow dialog routing. With Kamailio 6.1.4 available, add `--runtime`, or pass
`--config /path/to/rendered/kamailio.cfg --runtime` to test a site render.
The runtime harness extracts the actual classification route and ICE handlers,
binds ephemeral loopback ports, and uses fake SIP and NG peers. It checks
mixed case, MIME parameters, other application types, prefix lookalikes,
missing Content-Type on an empty request, non-INFO fragment rejection,
unchanged dialog identifiers/body, and downstream 200/415 responses. It also
checks the ICE NG command retains fragment classification and dialog tags.
It does not simulate the complete production topology or prove media works.

Validate complete site renders with the actual Application's injected values
and Kustomize composition. Pass each affected `kamailio.cfg` through
`kamailio -c -f /dev/stdin` in the deployed image without printing its
Secret-backed environment. This is a parser check, not a configuration reload.

## Live acceptance and diagnostics

### Home1 result, 2026-10-18

Commit `f945004` was reconciled through Argo CD for exactly the legacy internal
and internal-websocket Kamailio ConfigMaps. Reloader completed the existing
rolling update; all three WebSocket owners and the private SBC loaded the new
guard. No Asterisk or RTPEngine configuration was changed.
The scoped operation succeeded at that exact revision. The Application remains
Healthy with unrelated preexisting OutOfSync resources; no full application or
fleet sync was performed.

The user confirmed successful voicemail login, menu navigation, one digit
accepted per keypress, and working audio. The correlated dialog contained five
DTMF INFO requests, each taking `dtmf-dialog`, forwarding once to Asterisk,
and receiving its downstream 200 response. No related RTPEngine Content-Type
errors appeared in the test window. The fresh call had one observed INVITE
200, an ACK with matching INVITE CSeq and dialog tags on browser ingress and
owner wire egress, and a successful BYE/200 exchange. This did not reproduce
the earlier ACK symptom or establish its historical cause.

Static/render checks, the deployed 6.1.4 checker, and the isolated runtime
regression passed. Genuine trickle ICE was exercised with the real Kamailio
module and a fake NG peer; live RTPEngine fragment processing, a separate
RTP telephone-event client, and inbound/outbound calling were not exercised
in this acceptance call and remain compatibility checks to perform.

### Procedure

Reconcile the published revision through the owning Application. Only the
affected Kamailio ConfigMaps need syncing; their existing Reloader annotations
trigger the configured rolling update. Inspect the unchanged schema hooks
before selecting resources: a ConfigMap sync intentionally skips them and
must not replay database provisioning. Watch every WebSocket owner and the
legacy private SBC finish reloading. A client reconnects when its owner rolls.
Rollback uses a corrective/revert Git commit and the same scoped reconciliation;
it does not change persistent data.

Use `kubectl --context logged-user` for Home1. With a temporary test PIN set
through the normal mailbox administration path, call `*97`, log in and
navigate menus. Do not share or collect the PIN. Correlate Call-ID and CSeq
and verify one accepted digit per keypress, an actual Asterisk 200 for each
successful INFO, and no related RTPEngine Content-Type errors. Also test
genuine trickle ICE, bidirectional audio, inbound/outbound calls, both hangup
directions, and an existing RTP telephone-event client. Readiness alone is
not acceptance.

INFO diagnostics record Call-ID, CSeq, method, Content-Type, selected branch,
relay result and response status. Ingress, forwarding and wire markers include
dialog tags for ACK correlation. Never enable raw SIP/body or digit logging
for the PIN test. No diagnostic should contain DTMF bodies or digits,
credentials, authorization headers or mailbox PINs.

## Separate ACK investigation

Retained WebSocket owner logs for the reported INVITE CSeq 443 show two
browser ACK arrivals with CSeq 443 and the same dialog tags, each queued toward
Asterisk. A later ACK arrived from the browser with CSeq 444 and was queued
with that same number. The proxy must preserve it; changing that ACK to 443
would hide a client defect and misidentify the transaction. The other reported
dialog's ACK retained INVITE CSeq 6405.

No corresponding historical Asterisk-side records were retained. Proxy queue
success does not prove Asterisk received or accepted an ACK. Repeated 200s
and the reason the client emitted the later ACK therefore remain unresolved;
no ACK routing defect is confirmed by these records, and this fix does not
alter ACK routing. For a fresh reproduction compare browser ingress, owning
pod wire egress and Asterisk receipt using only dialog metadata. Compare each
200's upstream receipt and downstream send timestamps to distinguish upstream
retransmission from proxy duplication. Match ACK Call-ID, both tags and the
INVITE CSeq; do not compare it to the most recent INFO CSeq. Multiple diagnostic
markers for one response are not evidence of duplicate network packets.
