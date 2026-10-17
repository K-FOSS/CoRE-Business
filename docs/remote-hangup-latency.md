# Remote hangup latency: application-boundary findings

## Scope and result

This note records an application-boundary investigation in CoRE-Business. It
does not change SIP routing, PBX behavior, media handling, or cluster
configuration.

The supplied trace shows that remote-initiated hangup completes end to end,
but has an approximately five-second interval between Kamailio's captured
forwarding of the Flowroute BYE and FreeSWITCH's 200 OK. The inspected
CoRE-Business application source and configuration do not contain a call-state
service, SIP Call-ID-to-application-call mapping, Asterisk/FreeSWITCH event
consumer, remote-hangup handler, or browser hangup publisher. No
CoRE-Business operation was found on the demonstrated signaling path that
could account for that interval. No application code or runtime configuration
change is indicated by the available evidence.

This is a bounded finding: it does not prove that every external integration
is absent at runtime, nor identify the component responsible for the delay.
The supplied Kamailio timestamp is a capture of forwarding, not proof of when
FreeSWITCH received the request. The delay may be before FreeSWITCH receipt or
inside the PBX path. More precise timestamps are needed to distinguish those
possibilities.

## Supplied event timeline

| Event | UTC | Elapsed from prior event |
| --- | --- | ---: |
| Flowroute originates BYE | 07:28:25.131 | — |
| Internal Kamailio captures forwarding toward FreeSWITCH | 07:28:25.186 | 55 ms |
| FreeSWITCH returns 200 OK | 07:28:30.209 | 5.023 s |
| Asterisk initiates the WebRTC-leg BYE | 07:28:30.219 | 10 ms |
| WebSocket proxy forwards the BYE to the browser | 07:28:30.222 | 3 ms |
| Browser returns 200 OK | 07:28:30.396 | 174 ms |

The timeline places the observed wait before Asterisk initiates the
WebRTC-leg teardown. Once Asterisk sends that BYE, the supplied browser-side
exchange completes in under 200 ms. These observations do not establish when
FreeSWITCH received the incoming BYE or what it was doing before sending its
response.

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

The active pod's Event Socket is bound to loopback port 8021 and accepts
connections (`Content-Type: auth/request`). `mod_event_socket` is included in
the loaded modules configuration. However, `fs_cli -x 'sofia status'` and an
explicit loopback invocation both returned `Error Connecting`; an unauthenticated
socket probe received the authentication request and disconnected. The socket
uses the configured FreeSWITCH Event Socket password, while `fs_cli` without a
password uses its unrelated default. The password was not accessed or exposed.
Therefore the requested runtime commands
`sofia profile flowroute siptrace on` and
`sofia profile asterisk siptrace on` could not safely be sent, and tracing was
not left enabled. The next diagnostic is to run those `fs_cli -x` commands
from a controlled operator session that already has authorized Event Socket
credentials available without placing them in shell history, process listings,
or logs; confirm SIP output in the FreeSWITCH container stdout, place one
remote-hangup test call, then run the corresponding `siptrace off` commands.

No Homer message with a FreeSWITCH receipt timestamp was available. The
internal Kamailio's HEP capture proves its own relay decision only; the
FreeSWITCH `flowroute` profile does not currently emit a profile SIP trace to
stdout, and existing captures have not supplied the missing Sofia receipt
event. The previous Homer search endpoint required authentication (HTTP 401),
and pod packet capture was blocked by the absence of `CAP_NET_RAW`. Neither
limitation was worked around by exposing credentials or changing pod security.

The 07:47 timeline remains the best measured boundary: relay queued at
07:47:10.418–.420, followed by FreeSWITCH's first bridge hangup log at
07:47:15.411. It does not show whether the BYE reached Sofia immediately or
waited in the TLS/network path. The five-second root cause remains
undetermined. Do not change PBX timers, network policy, TLS routing, or bridge
behavior until a Sofia receipt timestamp (or equivalent authorized
application-level capture) distinguishes those cases.

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

The follow-up source correction keeps the existing registered UDP gateway and
adds a separate non-registering `flowroute-tls` gateway with
`register-transport=tls`. The dialplan now originates through that gateway;
the existing regional proxy, private Kamailio TLS outbound proxy, credentials,
TLS profile, and port 5081 remain in use. This should cause Sofia's generated
gateway Contact to carry one `transport=tls` parameter while leaving the
existing Flowroute UDP registration intact. The render regression checks both
gateway configurations and the dialplan selection. This second correction is
not yet live-validated; after its rollout, inspect an outbound INVITE Contact
and verify an in-dialog BYE reaches FreeSWITCH and returns 200 OK. Neither
Contact issue has been established as the cause of the five-second delay.

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

The gap from internal Kamailio's queued relay to FreeSWITCH's channel-hangup
log was about 5.020 seconds; the carrier BYE arrived about 5.061 seconds before
that log. RTPEngine deletion was requested once at carrier dialog end and
returned result `1`. No 481 or duplicate cleanup BYE was found in the
Call-ID-matched logs. The call completed, but Sofia's BYE receipt timestamp
was still absent, so this does not distinguish delayed TLS delivery from
delayed FreeSWITCH processing. The restored UDP Contact was overridden by the
internal route's explicit TLS next hop; the BYE succeeded despite the Contact
defect.

The changed source files for this correction are
`AVoIP/templates/FreeSwitch/FreeSwitchFlowrouteRegistration.yaml`,
`AVoIP/templates/FreeSwitch/FreeSwitchDialplanConfig.yaml`, and
`AVoIP/tests/outbound-teardown-render.sh`. Run the render regression from the
repository root with `AVoIP/tests/outbound-teardown-render.sh`.

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
