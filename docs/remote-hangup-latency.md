# Remote hangup latency investigation

## Scope and result

This note records an application-boundary investigation, the Flowroute
gateway/Contact inconsistency, and focused Kamailio relay diagnostics in
CoRE-Business's AVoIP chart. It does not change Kamailio dialog routing, media
handling, or cluster networking.

Remote-party hangup is intermittent. One carrier-originated BYE failed to get
a response and timed out; in another call the browser remained active until
it originated its own BYE. Separate earlier calls completed after an
approximately five-second interval. The issue is not resolved. The inspected
CoRE-Business application source and configuration do
not contain a call-state service, SIP Call-ID-to-application-call mapping,
Asterisk/FreeSWITCH event consumer, remote-hangup handler, or browser hangup
publisher. No CoRE-Business operation was found on the demonstrated signaling
path that could account for the interval. The implementation change here
corrects the gateway Contact mismatch and adds relay diagnostics; it is not a
confirmed repair for the no-response or five-second behavior.

This is a bounded finding: it does not prove that every external integration
is absent at runtime, nor identify the component responsible for the
intermittent failure or delay. The supplied Kamailio timestamp is a capture of
forwarding, not proof of when FreeSWITCH received the request. The delay may
be before FreeSWITCH receipt or inside the PBX path. More precise timestamps
are needed to distinguish those possibilities.

## Supplied event timeline

| Event | UTC | Elapsed from prior event |
| --- | --- | ---: |
| Flowroute originates BYE | 07:28:25.131 | — |
| Internal Kamailio captures forwarding toward FreeSWITCH | 07:28:25.186 | 55 ms |
| FreeSWITCH returns 200 OK | 07:28:30.209 | 5.023 s |
| Asterisk initiates the WebRTC-leg BYE | 07:28:30.219 | 10 ms |
| WebSocket proxy forwards the BYE to the browser | 07:28:30.222 | 3 ms |
| Browser returns 200 OK | 07:28:30.396 | 174 ms |

The successful timeline places the observed wait before Asterisk initiates the
WebRTC-leg teardown. Once Asterisk sends that BYE, the supplied browser-side
exchange completes in under 200 ms. These observations do not establish when
FreeSWITCH received the incoming BYE or what it was doing before sending its
response, and they do not generalize to the failed calls below.

An earlier call reportedly had both endpoints originate BYEs and FreeSWITCH
acknowledged the incoming BYE after about 7.13 seconds. That is consistent
with a PBX/signaling-boundary investigation, but does not prove the cause.
The separate WebRTC Call-ID `ipr2liv6jgg17ldgec7t` has not been correlated to
the carrier-leg trace and must not be treated as the same call.

## Live reproduction: 2026-10-17

During a user-placed outbound call ended by the remote party, read-only logs
provided this correlation:

- Carrier-leg SIP Call-ID: `c5a1b8af-44a1-1240-84ab-000000000000`.
- Asterisk linked ID: `avoip-asterisk-1792223218.326`.
- Browser Call-ID: `hc2osg3kc91nlpd0t6eh`.
- The FreeSWITCH carrier and Asterisk channel UUIDs were
  `a255e341-bb6a-4c2f-abff-f34c72f0e0fb` and
  `282f3665-8ccf-431b-8b24-457ff6ae6df3`, respectively.

| Event | UTC | Evidence |
| --- | ---: | --- |
| Carrier BYE reaches carrier-facing Kamailio | 07:47:10.411 | Authorized carrier peer; BYE logged |
| Carrier-facing Kamailio forwards BYE over TLS | 07:47:10.414–07:47:10.417 | Internal Kamailio service destination; relay queued |
| Internal Kamailio restores route and queues BYE to FreeSWITCH | 07:47:10.418–07:47:10.420 | `loose_route=1`; destination port 5081; TLS socket; `t_relay_result=1` |
| FreeSWITCH logs both bridge channels hanging up | 07:47:15.411 | `NORMAL_CLEARING` |
| Carrier-facing Kamailio logs response to carrier BYE | 07:47:15.432 | SIP 200, same Call-ID and BYE CSeq |
| Asterisk handles FreeSWITCH BYE response and starts browser-leg BYE | 07:47:15.432–07:47:15.439 | Asterisk result includes hangup cause 16; WebSocket proxy forwards BYE |
| WebSocket proxy logs browser response | 07:47:15.455 | SIP 200 for browser-leg BYE |

From internal Kamailio's relay-queued timestamp to FreeSWITCH's channel-hangup
log is about 4.992 seconds; the carrier-facing Kamailio's 200 log is about
5.012 seconds after that relay timestamp. These are useful bounds, not a
measurement of FreeSWITCH packet receipt: the FreeSWITCH logs available for
this call do not timestamp receipt of the carrier BYE. The end-to-end remote
hangup succeeded, with normal clearing, one observed BYE to the browser, and a
browser 200. The carrier tier logged one RTPEngine delete request with result
`1`. No call-matched 481 was present in the inspected entries.

This live call strengthens the conclusion that the measured delay is not in a
CoRE-Business application handler: no such handler exists in the inspected
repository path, and the delay precedes Asterisk's browser-leg BYE. It does
not establish the underlying cause within the PBX/signaling path. The
Call-ID-matched carrier entry also contains a Kamailio dialog-module warning
about unavailable local dialog state, while the request continued through
topology restoration and relay and received 200. That warning should be
interpreted by the SIP configuration owner; it is not evidence that the
application delayed teardown.

The live investigation could not retrieve the SIP packet timestamps needed to
split network delivery from FreeSWITCH processing. The existing Homer search
API required authentication and returned HTTP 401 without credentials; no
credentials were accessed. The existing network diagnostic sidecars had
`tcpdump`, but lacked `CAP_NET_RAW`, so a passive TLS-hop capture could not
start. No pod or logging configuration was changed. Another call observed
only through the same application logs would reproduce the delay but would
not close this evidence gap.

## CoRE-Business boundary inspected

The repository search covered application source and configuration for call
creation and state, SIP and PBX identifiers, hangup handlers, Asterisk and
FreeSWITCH integrations, webhook and event consumers, queues, and browser
notifications. No application implementation for those functions was found.
The `Communication` chart depends on Mattermost Team Edition; its deployment
and Kustomize input do not implement telephony call state or signaling.
Repository and component documentation likewise did not identify a
CoRE-Business service that must update application state before PBX teardown.

Accordingly, the current evidence does not support attributing the five-second
interval to CoRE-Business persistence, a worker, a retry, a lock, or a browser
notification. No CoRE-Business timeout was changed, and no synthetic state
transition or hangup acknowledgment was introduced. This preserves the
confirmed working remote-hangup behavior without masking a SIP failure.

## Evidence needed to localize the interval

For one new test call, correlate the carrier SIP Call-ID, dialog tags and
CSeq with PBX channel/session identifiers. Collect millisecond-precision
timestamps at these boundaries:

1. Kamailio capture immediately before forwarding the BYE.
2. FreeSWITCH host or pod network capture on receipt of that BYE.
3. FreeSWITCH transaction/application handling and 200 OK transmission.
4. Internal Kamailio receipt and forwarding of the 200 OK.
5. Asterisk receipt of the cleared channel/event and initiation of its
   WebRTC-leg BYE.
6. WebSocket proxy forwarding, browser receipt, and browser 200 OK.
7. Any CoRE-Business event receipt, state transition, publication, or cleanup,
   if a specific application event source is identified.

For the current unresolved boundary, use an already-authorized Homer search
path or an approved passive packet-capture capability at the internal
Kamailio and FreeSWITCH pod interfaces. Do not request or expose Homer
credentials. Once that observation is available, ask the user to place a
controlled test call and monitor the logs/capture directly across its time
window.

Use the same Call-ID and dialog identifiers where available, and record the
FreeSWITCH UUID, Asterisk channel ID, application call ID, event ID, and
instance/worker for any application event. Do not infer correlation from close
timestamps alone. In particular, the delay is attributable to CoRE-Business
only if timestamps show that an application operation lies on the blocking
path before the delayed downstream action.

## Validation and follow-up

### FreeSWITCH receipt timestamp attempt

On 2026-10-17, the live FreeSWITCH deployment was inspected before attempting
runtime tracing. The pod that handled the 07:47 test is
`core-home1-talos-prod-business-avoip-prod-avoip-freeswitchfmrvt` (pod IP
`172.20.56.203`, container `freeswitch`). The other healthy replica is
`core-home1-talos-prod-business-avoip-prod-avoip-freeswitchbk8hg` at
`172.20.57.188`. Startup logs on the call-owning pod show the active Sofia
profiles `asterisk`, `flowroute`, and `kamailio`; the carrier BYE target port
5081 belongs to the `flowroute` profile. The Asterisk-facing profile listens
on 5064. The running image is pinned by digest despite its mutable tag.

Sofia tracing is disabled in the chart by default. The `flowroute` profile is
rendered from the ExternalSecret template, while the other profiles are
rendered in `FreeSwitchSIPConfig.yaml`. Runtime logs are written to
`/dev/stdout` by `mod_logfile`, with `info` as the switch log level. Captured
container logs therefore contain channel events but no SIP packet trace:
`sip-trace` is false for the relevant profiles, and stdout collection can only
collect trace output after Sofia emits it.

The replacement pod handling the latest call has an Event Socket on
`127.0.0.1:8021`. `fs_cli` without the configured password returned
`Error Connecting`; an unauthenticated probe received `Content-Type:
auth/request`. A secret-safe local Event Socket client was then used: it reads
the existing container `PASSWORD` environment value into a pipe, sends it to
the loopback Event Socket without placing it in arguments or output, and runs
read-only `api sofia status`. The command succeeded on pod
`172.20.63.198`. It reported the `flowroute` profile RUNNING on both UDP and
TLS, the `flowroute` gateway REGED, and the `kamailio` profile RUNNING over
TLS. This establishes that the intended pod and TLS listener exist, but not
that the BYE opened or reused a successful connection or reached Sofia.

Sofia SIP tracing has not yet been enabled. For the next test, first establish
the call, then turn tracing on briefly for `flowroute` and `asterisk` through
the same secret-safe Event Socket client; monitor logs directly and turn both
traces off immediately after teardown. Because Sofia trace can include full
SIP messages and SDP, keep it scoped to the established test call and redact
authorization headers and bodies from any retained excerpt. The agent should
monitor logs directly and ask the user to place a test call only after the
diagnostic is ready; the user should not be asked to run console commands or
collect log output.

No Homer message with a FreeSWITCH receipt timestamp was available. The
internal Kamailio's HEP capture proves its own relay decision only; the
FreeSWITCH `flowroute` profile does not currently emit a profile SIP trace to
stdout, and existing captures have not supplied the missing Sofia receipt
event. The previous Homer search endpoint required authentication (HTTP 401),
and pod packet capture was blocked by the absence of `CAP_NET_RAW`. Neither
limitation was worked around by exposing credentials or changing pod security.

The 07:47 timeline remains the best earlier successful boundary: relay queued
at 07:47:10.418–.420, followed by FreeSWITCH's first bridge hangup log at
07:47:15.411. It does not show whether the BYE reached Sofia immediately or
waited in the TLS/network path. The five-second root cause remains
undetermined. The explicit outbound TLS gateway corrects the Contact and
selection inconsistency only. Do not change PBX timers, network policy, or
bridge behavior until a FreeSWITCH receive timestamp or equivalent authorized
application-level capture distinguishes the remaining causes.

### Flowroute Contact correction

The generated outbound bridge previously set
`sip_invite_contact_params='transport=tls'`. The active Flowroute Sofia profile
also listens on UDP 5080 and TLS 5081, has `tls=true` and `tls-only=false`, but
did not declare a TLS bind Contact parameter. A captured INVITE Contact was
reported as containing both `transport=udp` and the appended
`transport=tls`. The profile's UDP/TLS bind configuration combined with the
dialplan's unconditional appended parameter is the source of the duplicate.

The first source correction set `tls-bind-params=transport=tls` on the
Flowroute Sofia profile and removed the dialplan's extra Contact parameter.
The next live call proves that did not fix the gateway Contact: the active
profile had that setting, but after TOPOS restoration the target was still
`sip:gw+flowroute@<FreeSWITCH-pod>:5081;transport=udp;gw=flowroute`. The
remaining `transport=udp` comes from the gateway's `register-transport`, not
from the TLS profile bind. FreeSWITCH's gateway path uses the gateway's
`register_transport` for the outbound leg and the gateway's generated
`register_contact` for the INVITE Contact ([FreeSWITCH `mod_sofia.c`](https://github.com/signalwire/freeswitch/blob/master/src/mod/endpoints/mod_sofia/mod_sofia.c#L4452-L4544)).
The profile-level TLS bind parameter does not override that gateway-specific
Contact.

With the rolled-back configuration, the 08:43 call used gateway `flowroute`:
the carrier INVITE traveled over the private TLS path, but the FreeSWITCH 200
Contact was `gw+flowroute@172.20.63.198:5081;transport=udp`. TOPOS restored
that same UDP Contact in the carrier BYE Request-URI even though the Via was
TLS. The internal Kamailio route overrode only the destination URI to
`sip:172.20.63.198:5081;transport=tls`, selected `private_tls`, and logged
`t_relay_result=1`. Thus the visible Contact mismatch is confirmed, but it did
not make the current route call `t_relay()` with a UDP destination: the
selected next hop was TLS. It also cannot explain why FreeSWITCH gave no
response, because Sofia receipt and transport delivery are unmeasured.

The source is being corrected to keep the existing registered UDP gateway
available for the Flowroute SIP-REG route while adding one non-registering
`flowroute-tls` gateway for all outbound NANP calls. That gateway advertises a
TLS Contact and uses the existing protected Kamailio TLS path. The dialplan
will select it explicitly; the UDP registration gateway is no longer an
outbound fallback. This correction addresses the Contact inconsistency and
configuration ambiguity, not the intermittent no-response or five-second
delay. An earlier rollout of this same two-gateway pattern had two unanswered
BYEs and one successful call delayed by 5.02 seconds. Its live behavior must
therefore be revalidated with transport-boundary evidence before calling it a
repair.

Rollback commit `cd4d4a12ab526ff0affe00ddc5afeae94095ca05` restored the UDP
gateway as the outbound selection and was reconciled. The 08:43 call after
that rollback again failed to receive a response to Flowroute's original BYE.
The current source change reselects the explicit TLS gateway and adds more
relay diagnostics; it has not yet been deployed or live-validated.

### Latest live test: 2026-10-17 08:18 UTC

The user's latest call was correlated across carrier Kamailio, internal
Kamailio, FreeSWITCH, and Asterisk. Carrier-leg SIP Call-ID was
`3b6daa27-44a6-1240-e388-000000000000`; linked ID was
`avoip-asterisk-1792225133.336`; FreeSWITCH UUIDs were
`94227812-8383-4d73-aba8-364b3c1a5bfc` (Flowroute leg) and
`df9f607b-bbcb-400f-ad79-01e0556db486` (Asterisk leg).

| Event | UTC | Evidence |
| --- | ---: | --- |
| Carrier BYE received by carrier Kamailio | 08:19:05.816 | Same Call-ID, BYE CSeq `587712` |
| Carrier Kamailio forwards BYE | 08:19:05.819–.822 | TLS private socket to internal Kamailio |
| Internal Kamailio restores Contact and queues BYE to FreeSWITCH | 08:19:05.855–.858 | TLS to pod `172.20.63.99:5081`; `t_relay_result=1` |
| FreeSWITCH logs both bridge legs hanging up | 08:19:10.878 | Both channels `NORMAL_CLEARING` |
| Carrier Kamailio receives the BYE response | 08:19:10.885 | 200 OK, same Call-ID and CSeq |
| Asterisk observes teardown | 08:19:10.887–.890 | SIP 200 OK and Q.850 cause 16 / Normal Clearing |
| Asterisk originates browser-leg BYE | 08:19:10.894 | Separate browser Call-ID `f7mq2tavdaio8sieg7dp`, CSeq `6720 BYE` |
| WebSocket Kamailio forwards BYE to browser | 08:19:10.896–.899 | WSS flow target restored; relay queued |
| WebSocket Kamailio receives browser 200 OK | 08:19:10.913 | Same browser Call-ID and BYE CSeq |

The gap from internal Kamailio's queued relay to FreeSWITCH's channel-hangup
log was about 5.020 seconds; the carrier BYE arrived about 5.061 seconds before
that log. RTPEngine deletion was requested once at carrier dialog end and
returned result `1`. No 481 or duplicate cleanup BYE was found in the
Call-ID-matched logs. The call completed, and the browser's separate-leg 200 OK
arrived about 19 ms after WebSocket Kamailio queued its BYE. Sofia's incoming
BYE receipt timestamp was still absent, so this does not distinguish delayed
TLS delivery from delayed FreeSWITCH processing. The restored UDP Contact was
overridden by the internal route's explicit TLS next hop; the BYE succeeded
despite the Contact defect.

This test happened before the temporary `flowroute-tls` gateway was applied.
The remote BYE completed on the original `flowroute` gateway path. It remains
the last observed successful remote-initiated teardown in this investigation.

The changed source files for this correction are
`AVoIP/templates/FreeSwitch/FreeSwitchFlowrouteRegistration.yaml`,
`AVoIP/templates/FreeSwitch/FreeSwitchDialplanConfig.yaml`, and
`AVoIP/tests/outbound-teardown-render.sh`. Run the render regression from the
repository root with `AVoIP/tests/outbound-teardown-render.sh`.

### Regression after `flowroute-tls` rollout: 2026-10-17 08:30–08:34 UTC

Two calls using the newly added TLS gateway reproduced a more severe failure.
The live rollback in the working tree removes `flowroute-tls` and restores the
previously successful dialplan gateway. These observations are why the
dedicated gateway must not be retained without a verified inbound dialog
route.

For carrier Call-ID `c227041c-44a6-1240-a7b8-000000000000` and Asterisk linked
ID `avoip-asterisk-1792225789.340`:

| Event | UTC | Evidence |
| --- | ---: | --- |
| Internal Kamailio restores BYE to the FreeSWITCH pod | 08:30:07.484 | TOPOS route restored; RURI `gw+flowroute-tls`; TLS destination `172.20.56.123:5081` |
| Internal Kamailio queues the BYE | 08:30:07.486 | `t_relay_result=1` |
| Carrier-facing Kamailio receives 408 from internal tier | 08:30:38.094 | Same Call-ID and CSeq `373237 BYE` |
| FreeSWITCH logs the Asterisk leg hangup | 08:30:39.098 | `NORMAL_CLEARING` |
| FreeSWITCH originates its own carrier-leg BYE | 08:30:44.110 | CSeq `121559103 BYE` |
| Flowroute-facing Kamailio receives 481 | 08:30:44.248 | Same Call-ID; carrier dialog had already timed out the incoming BYE |

For separate carrier Call-ID `1ad115c5-44a8-1240-a7b8-000000000000` and
Asterisk linked ID `avoip-asterisk-1792225938.342`:

| Event | UTC | Evidence |
| --- | ---: | --- |
| Carrier BYE received | 08:32:34.191 | Carrier Kamailio; CSeq `331979 BYE` |
| Internal Kamailio restores BYE to the FreeSWITCH pod | 08:32:34.195 | TOPOS route restored; RURI `gw+flowroute-tls`; TLS destination `172.20.56.123:5081` |
| Internal Kamailio queues the BYE | 08:32:34.198 | `t_relay_result=1`; RTPEngine delete requested once and returned `1` |
| Carrier-facing Kamailio receives 408 from internal tier | 08:33:04.184 | Same Call-ID and BYE CSeq; Flowroute's BYE received no 200 |
| Browser dialog UPDATE is processed | 08:33:08.076–.078 | Separate browser Call-ID; Asterisk responds 200 with `Session-Expires: 90;refresher=uac` |
| Further browser UPDATEs remain active | 08:33:53.093–.094 and 08:34:38.105–.111 | Same browser Call-ID; each receives 200 |
| Asterisk sends BYE toward browser | 08:35:38.106–.112 | Browser dialog CSeq `15464 BYE`; WSS Kamailio queues it to the registered WebSocket flow |
| Asterisk's browser-leg BYE times out | 08:36:08.051 | Asterisk logs `408/BYE`; no corresponding browser 200 was found in the WSS logs |
| Asterisk's FreeSWITCH leg clears | 08:36:08.068 | Asterisk logs a separate BYE transaction receiving 200 from FreeSWITCH |
| FreeSWITCH sends late carrier-leg BYE | 08:36:13.076 | Carrier Call-ID; CSeq `121559178 BYE`, Reason Q.850 cause 16 |
| Internal Kamailio cannot restore late BYE route | 08:36:13.078 | `topos_result=route-miss`, `loose_route_result=-1`, `route=<null>`; the internal tier returns 481 |

The browser continued sending successful UPDATEs for over two minutes after
Flowroute's BYE failed. The later Asterisk BYE was queued to the browser flow,
but no browser 200 was found before Asterisk logged a 408. Asterisk separately
cleared its FreeSWITCH leg; five seconds later FreeSWITCH's own BYE arrived
with a topology token that the internal tier could not restore. That explains
why this late request received 481, but not what initiated FreeSWITCH's delayed
BYE. Cause 16 alone does not identify the trigger. Its timing follows the
Asterisk-side teardown, but the FreeSWITCH channel-state/hangup-hook evidence
needed to establish causality was unavailable after that pod was replaced.

The Asterisk-linked browser dialog's last observed UPDATE was at 08:34:38.111;
the earlier successful UPDATEs were about 45 seconds apart. No next UPDATE
appears near 08:35:23. The later BYE from Asterisk to the browser begins at
08:35:38, and its 408 is logged near 08:36:08, approximately 90 seconds after
the last UPDATE. This timing makes session-timer interaction a hypothesis for
the delayed teardown, but there is no timer-expiry event or correlated
FreeSWITCH/Asterisk SIP capture proving that it triggered either BYE. The
FreeSWITCH BYE's cause 16 is not sufficient evidence. Inspect the session
timer state on the separate Asterisk/FreeSWITCH dialog and the missing refresh
window before attributing this late cleanup.

The internal pod's socket table showed an established TCP connection to
`172.20.56.123:5081`, and Kamailio logged the expected FreeSWITCH TLS server
name. There were no matching FreeSWITCH SIP-trace lines because Sofia tracing
was disabled. The established socket and `t_relay_result=1` prove neither SIP
message receipt nor FreeSWITCH dialog matching. No 200 OK to the original
carrier BYE was observed. The late 481 is a follow-on route-restoration failure,
not the first failure.

This regression confirms that the temporary gateway change needed to be
rolled back, but does not identify why FreeSWITCH failed to answer the
in-dialog BYE.
The internal request was addressed to the restored owner pod over TLS and
preserved the dialog identifiers in TOPOS; the missing Sofia receipt time
still prevents distinguishing TLS payload delivery from FreeSWITCH SIP
processing. Do not treat the rollback as a fix for the original five-second
delay or for the separate Contact transport defect.

### Latest successful but delayed remote hangup: 2026-10-17 08:38 UTC

This is a separate call from the failed example above. Its carrier dialog was
Call-ID `ebe4f39e-44a8-1240-a7b8-000000000000`; the browser dialog was
`ogqlm3d4t6kpcmaik93o`. Asterisk correlated them to linked ID
`avoip-asterisk-1792226288.346` and origin unique ID
`avoip-asterisk-1792226288.347`. The dialogs have different Call-IDs as
expected across the B2BUAs.

| Event | UTC | Evidence |
| --- | ---: | --- |
| Carrier INVITE is relayed | 08:38:10.159 | Carrier Kamailio replica `8fjhb6`, TLS to Flowroute |
| Flowroute sends 100 and 183 | 08:38:10.546; 08:38:14.683 | Same carrier Call-ID and INVITE CSeq |
| Flowroute sends 200 OK | 08:38:16.686 | First logged 200 for the carrier dialog |
| Further 200 responses are logged | 08:38:17.201 and 08:38:17.959 | Same INVITE CSeq and branch; internal and carrier Kamailio logs record separate sends/receipts |
| FreeSWITCH ACK reaches carrier Kamailio | 08:38:17.148 | Different replica `8znj9g`; ACKs are forwarded on the logged Flowroute TLS connection |
| Flowroute originates carrier BYE | 08:38:22.154 | CSeq `144775 BYE` |
| Carrier Kamailio receives and forwards BYE | 08:38:22.295–08:38:23.210 | BYE moves from replica `8fjhb6` over TLS to internal Kamailio |
| Internal Kamailio restores route and queues BYE | 08:38:23.243–.245 | `loose_route_result=1`; destination `172.20.56.123:5081;transport=tls`; `t_relay_result=1` |
| FreeSWITCH responds 200 OK | 08:38:28.266 | Carrier-leg capture; same Call-ID and BYE CSeq |
| Carrier Kamailio relays 200 to Flowroute | 08:38:28.362–.364 | Same carrier Call-ID and BYE CSeq |
| Asterisk sends BYE on browser dialog | 08:38:28.285–.288 | Browser Call-ID; CSeq `3371 BYE`; `Reason: Q.850;cause=16` |
| Browser responds and WebSocket Kamailio relays 200 | 08:38:28.301–.303 | Same browser Call-ID and CSeq |

The measured interval from the internal relay capture at 08:38:23.244912 to
the FreeSWITCH 200 capture at 08:38:28.265866 was 5.020954 seconds. This
proves the BYE was processed by FreeSWITCH by the response time, but does not
show when Sofia first received it. The interval may include connection
establishment, TLS delivery, and FreeSWITCH processing; it cannot be assigned
to any one of those stages from Homer alone. The carrier BYE and browser BYE
are separate dialogs. Once Asterisk sent the browser BYE, the browser
acknowledged it in about 16 ms. Asterisk logs independently show the carrier
bridge ending with normal clearing and preserve the linked/origin IDs.

The carrier and internal logs contain multiple 200 responses for the same
INVITE CSeq and branch, with repeated ACK handling across carrier replicas.
These are distinct structured log events rather than a single HEP record
duplicated in the query. Their ordering is consistent with SIP 2xx
retransmissions and corresponding ACK retransmissions while the ACK path is
being processed, but packet-level transaction/branch comparison is still
needed to prove each wire copy. This does not identify the BYE delay.

Internal Kamailio logged one RTPEngine delete request for this successful
carrier BYE, and Asterisk logged RTP stop for both linked channels. A
call-matched RTPEngine deletion result or post-call state query was not
captured for this call, so media-state removal is not independently proven by
this observation.

The `5063` receive-socket labels in the matching records belong to the
WebSocket Kamailio's TLS listener for the browser/Asterisk dialog. The
carrier-side and internal Kamailio signaling path uses the separate TLS
listener on `5062`. This distinction is consistent with separate B2BUA legs;
the `5063` value alone is not evidence that the carrier BYE changed listener.

This successful call also used the temporary `flowroute-tls` gateway and the
same FreeSWITCH pod/listener (`172.20.56.123:5081`) as failed Call-ID
`1ad115c5-44a8-1240-a7b8-000000000000`. The failed request produced no
FreeSWITCH response and timed out, while this one produced 200 after 5.02
seconds. Both used TLS and the corrected TLS Contact; those static settings
therefore do not explain the difference. Replica distribution alone also does
not explain it: the per-call transport connection, receive time, and Sofia
processing are still unmeasured. This call completed before the rollback was
reconciled, so it is not a post-rollback validation.

### Latest post-rollback failure: 2026-10-17 08:43 UTC

Carrier Call-ID `a3936ec1-44a9-1240-00b2-000000000000` and browser
Call-ID `ogqlmjuopih7lub1lpnq` are separate dialogs. Asterisk correlated them
to linked ID `avoip-asterisk-1792226596.355` and origin unique ID
`avoip-asterisk-1792226596.356`. The failed carrier BYE and the later browser
BYE / FreeSWITCH BYE are separate transactions:

| Event | UTC | Evidence |
| --- | ---: | --- |
| Flowroute sends carrier BYE | 08:43:26.193075 | Carrier Call-ID; CSeq `668193 BYE` |
| Carrier Kamailio forwards toward internal tier | 08:43:26.195840–.197210 | `private_tls`, connection 18, destination `10.44.7.184:5062` |
| Internal Kamailio restores dialog route | 08:43:26.198297 | `topos_result=route-restored`, `loose_route_result=1`; restored RURI has `transport=udp` |
| Internal Kamailio selects FreeSWITCH target and queues BYE | 08:43:26.198326–.200855 | Destination `172.20.63.198:5081;transport=tls`, `private_tls`, `t_relay_result=1` |
| Browser independently sends BYE | 08:43:45.907798 | Browser Call-ID; CSeq `6537 BYE` |
| Asterisk returns 200 to browser and sends separate BYE to FreeSWITCH | 08:43:45.915894–.917624 | Browser BYE is acknowledged promptly; Asterisk then terminates its FreeSWITCH dialog |
| FreeSWITCH Asterisk-facing leg hangs up; Asterisk gets 200 | 08:43:45.924225–.927539 | FreeSWITCH `NORMAL_CLEARING`; Asterisk's BYE gets 200 within about 12 ms |
| FreeSWITCH Flowroute-facing leg hangs up and originates its BYE | 08:43:50.924210–.932106 | About 5 seconds after its Asterisk-facing leg; carrier Call-ID, CSeq `121559507 BYE`, cause 16 |
| Flowroute rejects that separate FreeSWITCH BYE | 08:43:50.991565 | 481, because Flowroute had already ended its carrier dialog |
| Internal Kamailio returns 408 for Flowroute's original BYE | 08:43:56.184010–.186440 | Original CSeq `668193 BYE`, about 30 seconds after it was relayed |

The browser remained active for about 19.7 seconds after Flowroute's BYE and
then originated its own BYE. Its prompt 200 is not an acknowledgment of the
carrier BYE. The later FreeSWITCH CSeq `121559507` BYE and Flowroute 481 are
also not the original CSeq `668193` transaction; the internal 408 is the
failure of that original transaction.

This call localizes the separate five-second interval more closely: Asterisk
sent BYE on its FreeSWITCH dialog at 08:43:45.917624 and received 200 by
08:43:45.927539; FreeSWITCH logged its Asterisk-facing channel hangup at
08:43:45.924225 and its Flowroute-facing bridge leg hangup at
08:43:50.924210. That is a five-second bridge-leg teardown gap. The available
logs do not show a FreeSWITCH timer, hook, script, or blocking database
operation responsible for it, so the specific cause remains unproven. The
separate 5.020954-second interval in the earlier successful remote-BYE call
still lacks a FreeSWITCH receive timestamp and must not be conflated with this
bridge-leg gap.

RTPEngine cleanup is idempotent in this trace: the first carrier BYE requested
deletion and received result `1`; the later FreeSWITCH BYE logged
`teardown-already-claimed` and skipped another deletion. Asterisk logs RTP
stop for both channels and its CDR records the call. The carrier dialog still
failed its original BYE transaction despite that local cleanup.

The current chart-selected gateway was `flowroute`, and both active
FreeSWITCH replicas had the same image digest and the same mounted Flowroute
profile: `flowroute` registered over UDP; profile `flowroute` listened on
5081/TLS; the dialplan selected `sofia/gateway/flowroute`. The observed
`flowroute` versus `flowroute-tls` difference comes from deployments at
different times, not a replica split in this test. The owning pod's Event
Socket reported the profile and gateway RUNNING. Internal Kamailio actively
overrode the restored UDP RURI transport with a TLS destination, so the
Contact inconsistency is a confirmed defect but not proof of a local
`t_relay()` transport mismatch in this call.

No TCP/TLS packet capture or Sofia receive timestamp is available for
08:43:26. The FreeSWITCH response to the original carrier BYE is absent, and
the later response to the separate Asterisk BYE does not prove that the
carrier BYE reached the listening socket. The cause of the original 408 and
the application-level five-second bridge delay remain separate unresolved
questions.

## Current determination

The new failed call demonstrates the selected TLS destination and successful
TM queueing, but not TLS payload delivery or FreeSWITCH receipt. Its restored
Contact still carried `transport=udp`; the private route overrode `$du` to
TLS. In the same call, Asterisk-to-FreeSWITCH BYE completed promptly, while
FreeSWITCH waited about five seconds before ending its carrier-facing bridge
leg. Earlier calls using both the UDP Contact and the TLS Contact had
intermittent responses, so neither gateway selection alone nor replica
distribution explains all outcomes.

No confirmed root cause for the unanswered carrier BYE or the FreeSWITCH
bridge-leg delay is established. `t_relay_result=1` records transaction
queueing; it does not confirm a completed TCP/TLS exchange or FreeSWITCH SIP
receipt. The 08:43 Flowroute 481 is a response to FreeSWITCH's later BYE; the
internal 408 is the response to Flowroute's original BYE. Neither response
should be substituted for the other.

After rollback `cd4d4a1`, the deployed profile contained the UDP-registered
`flowroute` gateway and the dialplan selected it; the 08:43 call on that
configuration failed to receive a response to the remote BYE. The source now
reselects an explicit TLS outbound gateway and adds Kamailio wire-attempt,
transaction-failure, correlation, and BYE-response fields. These changes have
not yet been deployed or validated. The fix is not considered complete until
a Flowroute-originated BYE receives a genuine 200 from FreeSWITCH and the
response reaches Flowroute without a later duplicate BYE or 481.

### Follow-up live call with a stale FreeSWITCH owner: 2026-10-17 08:28–08:29 UTC

The next observed call, carrier Call-ID
`9c512646-44a7-1240-e388-000000000000`, established on FreeSWITCH address
`172.20.63.99`. Its carrier BYE reached internal Kamailio and TOPOS restored
that exact owner address:

| Event | UTC | Evidence |
| --- | ---: | --- |
| Internal Kamailio receives/restores carrier BYE | 08:29:00.714 | CSeq `839796 BYE`; `loose_route_result=1`; RURI points to `172.20.63.99:5081` |
| Internal Kamailio queues BYE | 08:29:00.716 | TLS destination `172.20.63.99:5081`; `t_relay_result=1` |
| Live cluster inspection | 08:36 UTC | `172.20.63.99` was not assigned to either running FreeSWITCH pod; current pod IPs were `172.20.57.149` and `172.20.56.123` |

No receipt or response for this Call-ID appeared in either current FreeSWITCH
pod's logs. This proves the restored target was no longer a running FreeSWITCH
pod at inspection time; it does not establish whether the old pod was already
gone at the instant of BYE delivery. The application log's `t_relay_result=1`
only means the SIP transaction was queued. This test therefore cannot establish
the Sofia receipt timestamp or the original five-second delay's cause. It does
show that a pod restart/replacement during an active dialog can leave a
TOPOS-restored Contact pointing at an unavailable pod address. That is a
separate lifecycle/HA risk from the `flowroute-tls` gateway regression and
needs a deployment-safe stable FreeSWITCH dialog target designed and validated
in the AVoIP deployment layer; this task does not change the SIP architecture.
This stale-owner observation is a separate call and does not explain the
failed-versus-successful pair above, which both restored to `172.20.56.123`.

### Independent observations

The carrier Kamailio `dlg_onroute` warning about missing local dialog state
occurred while the same request continued through TOPOS restoration, TLS relay,
and a successful response. It is an HA/dialog-state concern owned by the SIP
configuration and does not explain the delay measured before Asterisk's
browser-leg BYE. Repeated INVITE 200/ACK records require a message-level
comparison to distinguish SIP retransmissions from duplicate HEP records;
they are not evidence of the BYE delay. The FreeSWITCH startup warning for
missing `mod_sms_flowroute.so` and the earlier RTP port-range rounding warning
are unrelated absent further correlation.

The acceptance condition for remote hangup remains a real Flowroute-originated
BYE reaching FreeSWITCH, a genuine FreeSWITCH 200 OK returning to Flowroute,
and normal teardown reaching the browser. The 07:47 test met that end-to-end
condition, but did not measure Sofia receipt. The rendered Contact correction
still needs live validation after deployment.

For a fresh reproduction, first establish authorized, secret-safe `fs_cli`
access and verify `sofia status` on the call-owning pod. Enable trace only on
the `flowroute` and `asterisk` profiles, monitor pod logs directly, and
disable both traces immediately after one test call. Ask the user to place the
call only after trace output has been verified; the user should not be asked
to run console commands or collect log output. If Event Socket access remains
unavailable, record that limitation and do not claim a Sofia receipt timestamp.

If follow-up evidence identifies a CoRE-Business event or operation in the
critical path, instrument event receipt, validation, call lookup, state
transition, persistence, publication, notification, and cleanup with
millisecond timestamps and correlation identifiers before changing behavior.
Keep that diagnostic logging configurable, avoid sensitive content, and add
regression tests for idempotency and event ordering if an application handler
is introduced or found. If the delay occurs before FreeSWITCH receives the
BYE or within PBX processing, address it in the owning SIP/PBX system rather
than changing unrelated CoRE-Business application state.
