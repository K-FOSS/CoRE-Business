# SIP call captures: 2026-10-23 05:55–06:04 UTC

This report is intentionally limited to two user calls represented by three
SIP dialogs:

| User call | SIP Call-ID | Leg |
|---|---|---|
| Groundwire 7101 to 66 | `DC5CFC2C41A12F057BF62DC6E2EEA618109C33ED` | Endpoint to FreeSWITCH |
| JsSIP 7101 to external destination | `2p085q8gir2kvv11fb2k` | Endpoint to FreeSWITCH |
| Same JsSIP call | `71ef7eea-494a-1240-2881-000000000000` | FreeSWITCH to Flowroute |

The last two IDs are B2BUA legs of one call and correlate through
`X-Call-ID: 2p085q8gir2kvv11fb2k`. The report contains no Digest response,
ICE password, SRTP key, or direct telephone number.

## Groundwire dialog

### Chronology

| UTC | Source | Destination | Transport | Message | Call-ID / CSeq | Observed routing fields |
|---|---|---|---|---|---|---|
| 05:55:56 | `10.0.0.86:52968` | SIP ingress `172.20.57.33:8443` | TLS | Initial `INVITE` to 66 | Call-ID above; first INVITE CSeq | Groundwire 26.1.18; Contact/Via details were not retained in the reconstruction |
| 05:55:56 | Kamailio `172.20.63.147:5064` | `10.0.0.86:52968` | TLS connection | `407 Proxy Authentication Required` | Same Call-ID | Normal Digest challenge |
| 05:55:56 | `10.0.0.86:52968` | SIP ingress | TLS | Authenticated `INVITE` | CSeq `2 INVITE` | Authorization value intentionally omitted |
| 05:55:56 | Kamailio | Groundwire | TLS | `100 Trying` | CSeq `2 INVITE` | Transaction accepted |
| 05:55:56 | Kamailio `172.20.63.147:5062` | FreeSWITCH Service `10.44.6.19:5072` | TLS | Forwarded `INVITE` | CSeq `2 INVITE` | RTPEngine-modified SDP |
| 05:55:56 | FreeSWITCH | Kamailio | TLS | `488 Not Acceptable Here` | CSeq `2 INVITE` | Q.850 cause 88, `INCOMPATIBLE_DESTINATION` |

Record-Route and Contact values were not included in the reconstructed record,
so they cannot be stated from this evidence.

### SDP transformation

| Property | Groundwire offer | FreeSWITCH-facing copy before correction |
|---|---|---|
| Origin | Not retained | Not retained |
| Connection | `10.0.0.86` | `172.20.56.1` |
| Media 1 | `27328 RTP/AVP` | `11016 RTP/AVP` |
| Media 2 | `27328 RTP/SAVP` | `11154 RTP/SAVP` |
| RTCP | Client ports 27328/27329 | Relay ports 11017/11155 |
| Security | ICE, SDES and DTLS attributes | ICE, SDES and DTLS attributes remained |
| Codecs | Opus, PCMU, PCMA, G.722, iLBC, G.729, GSM and telephone-event | Payload set retained |

RTPEngine anchored both sections, but it did not terminate the endpoint media
security before the internal handoff. FreeSWITCH therefore received two audio
sections with mixed AVP/SAVP and endpoint-style ICE/crypto negotiation. The
overlapping codecs show that a simple absence of common codecs is not an
adequate explanation for the 488. The demonstrated defect is the incomplete
public-to-private media-boundary conversion.

## JsSIP endpoint dialog

### Chronology

| UTC | Source | Destination | Transport | Message | Call-ID / CSeq | Observed routing fields |
|---|---|---|---|---|---|---|
| 06:04:26 | Browser flow observed as `172.20.57.217:40366` | Kamailio `172.20.63.181:8088` | WSS | Initial `INVITE` | `2p085q8gir2kvv11fb2k`, `4571 INVITE` | Browser Via used WSS `.invalid`; `Session-Expires: 90` |
| 06:04:26 | Kamailio | Browser | WSS | `407 Proxy Authentication Required` | `4571 INVITE` | Expected challenge |
| 06:04:27 | Browser | Kamailio | WSS | Authenticated `INVITE` | `4572 INVITE` | Digest value omitted |
| 06:04:27.126381 | Kamailio `172.20.63.181:5062` | FreeSWITCH Service `10.44.6.19:5072` | TLS | Forwarded `INVITE` | `4572 INVITE` | Owner-specific Contact points at replica 2 on TLS 5063; timer normalized to 120 seconds |
| 06:04:34.438564 | FreeSWITCH pod `172.20.63.211` | Kamailio | TLS | `200 OK` | `4572 INVITE` | Answer advertised pod media address |
| 06:04:35.145676 | Kamailio | Browser | WSS | `200 OK` | `4572 INVITE` | Captured answer still advertised `172.20.63.211:11278` |
| 06:04:35.326682 | Browser | Kamailio | WSS | `ACK` | `4572 ACK` | Dialog ACK |
| 06:04:35.751945–06:04:36.251993 | Both directions | Both directions | WSS/TLS | Additional `200 OK` and ACK copies | Same dialog | Consistent with delayed/retransmitted final response; capture alone cannot distinguish wire duplication from duplicate capture points |
| 06:04:38.350216 | Browser | Kamailio | WSS | `BYE` | Same dialog | User-side termination |
| 06:04:40.160380 | Kamailio | FreeSWITCH | TLS | Forwarded `BYE` | Same dialog | Approximately 1.81 seconds after first captured browser BYE |
| 06:04:40.164212 | FreeSWITCH | Kamailio | TLS | `200 OK` | BYE CSeq | FreeSWITCH accepted teardown |
| 06:04:40.927183 | Kamailio | Browser | WSS | `200 OK` | BYE CSeq | Teardown response reached client |

The evidence does not contain enough per-hop timestamps to assign the full
1.81-second BYE delay to a single component. TOPOS restoration, owner-pod
forwarding, TLS scheduling, and duplicated capture points remain candidates;
the successful FreeSWITCH response proves the dialog target was eventually
correct for this call.

### SDP transformation

| Property | Browser offer | RTPEngine offer to FreeSWITCH | FreeSWITCH answer leaked toward browser |
|---|---|---|---|
| `o=` | Browser session, loopback origin in the supplied client SDP | Rewritten by RTPEngine | FreeSWITCH-generated |
| `c=` | Server-reflexive/private browser address | `172.20.56.1` | `172.20.63.211` |
| `m=audio` | `65077 UDP/TLS/RTP/SAVPF` | `11084 UDP/TLS/RTP/SAVPF` | `11278 UDP/TLS/RTP/SAVPF` |
| ICE | Browser host/srflx candidates | Sole RTPEngine candidate | FreeSWITCH pod candidate |
| DTLS | Browser fingerprint, `setup:actpass` | RTPEngine fingerprint, `setup:actpass` | FreeSWITCH fingerprint, `setup:active` |
| RTCP | mux | mux | mux |
| Codecs | Opus, RED, G.722, PCMU, PCMA, CN, telephone-event | Retained | Opus, telephone-event and CN |

The offer-side transformation correctly replaced browser candidates with the
relay, but still made FreeSWITCH a WebRTC endpoint. More importantly, live
RTPEngine logs contained an `offer` command but no corresponding `answer`
command for this dialog. The captured client-facing 200 consequently exposed
the FreeSWITCH pod address. That was not intentional direct media; it was a
missed answer rewrite.

Signaling reached 200/ACK/BYE, but media is not proven. RTPEngine's retained
statistics showed no completed FreeSWITCH-side peer and no negotiated crypto
suite before deletion. The browser-side DTLS attempts and successful SIP
answer therefore must not be reported as confirmed audio.

## Correlated Flowroute dialog

### Chronology

| UTC | Source | Destination | Transport | Message | Call-ID | Observed routing fields |
|---|---|---|---|---|---|---|
| 06:04:27 | FreeSWITCH `172.20.63.211`, observed source `47057` and advertised Via `5081` | Internal carrier-routing Kamailio `172.20.57.38:5062` | TLS | `INVITE` | `71ef7eea-494a-1240-2881-000000000000` | `X-Call-ID: 2p085q8gir2kvv11fb2k` |
| 06:04:27 | Internal routing through `10.44.5.19:5061` / `172.20.57.33:5061` | Carrier Kamailio `172.20.63.25:5061`, then `172.20.57.34:5061` | TLS | Routed `INVITE` | Same carrier Call-ID | Provider-specific Request-URI and identity policy applied |
| 06:04:27 | Carrier Kamailio | Flowroute `34.210.91.112:5061` | TLS | Provider `INVITE` | Same carrier Call-ID | Public carrier identity advertised |
| 06:04:33.307221 | Flowroute | Carrier Kamailio | TLS | `200 OK` | Same carrier Call-ID | Remote media `67.231.3.94:43708` |
| 06:04:34.572477–06:04:34.644976 | FreeSWITCH through carrier Kamailio | Flowroute | TLS | `ACK` | Same carrier Call-ID | Dialog established |
| 06:04:35.338213–06:04:35.341754 | Same path | Same path | TLS | Additional ACK copy | Same carrier Call-ID | Corresponds to an additional final-response copy |
| 06:04:40.391120 | FreeSWITCH | Flowroute through carrier Kamailio | TLS | `BYE` | Same carrier Call-ID | B2BUA tears down carrier leg |
| 06:04:40.484304–06:04:40.489175 | Flowroute | FreeSWITCH through carrier Kamailio | TLS | `200 OK` | Same carrier Call-ID | Carrier teardown completed |

FreeSWITCH generated the B2BUA Call-ID and copied the original endpoint
Call-ID into `X-Call-ID`. AVoIP Admin's generated outbound route selected the
provider, permitted codecs and caller identity; FreeSWITCH applied those
channel variables, and carrier Kamailio applied the provider-specific
Request-URI and externally asserted identity. Exact header values are omitted
because the reconstruction intentionally excludes the direct number.

### Carrier SDP

| Property | FreeSWITCH offer | Public offer | Flowroute answer | Internal rewritten answer |
|---|---|---|---|---|
| `o=` | FreeSWITCH, `172.20.63.211` | Address rewritten to public relay | Flowroute, `67.231.3.94` | Retained session identity with relay connection |
| `c=` | `172.20.63.211` | `24.86.197.63` | `67.231.3.94` | `172.20.56.1` |
| `m=audio` | `11116 RTP/AVP` | `11168 RTP/AVP` | `43708 RTP/AVP` | `11052 RTP/AVP` |
| RTCP | Implicit/adjacent | `11169` | Not reconstructed separately | `11053` |
| Codecs | PCMU, PCMA, telephone-event, CN | Same | PCMU, G.729, telephone-event | Common selection includes PCMU payload 0 |

The same site RTPEngine performs both directions of this translation. Its
`internal` interface uses the pod address and its `external` interface
advertises the site public media address. The observed answer rewrite proves
the carrier path invoked both offer and answer processing; it does not prove
that the browser A-leg carried audio.

## Address inventory

| Class | Addresses | Meaning |
|---|---|---|
| Endpoint signaling | `10.0.0.86:52968`, `172.20.57.217:40366` | Groundwire source and observed browser flow |
| Kamailio pods/listeners | `172.20.63.147:5062/5064`, `172.20.63.181:5062/8088`, `172.20.57.38:5062`, `172.20.63.25:5061`, `172.20.57.34:5061` | Ephemeral pod addresses; never configuration targets |
| Kubernetes Services | `10.44.6.19:5072`, `10.44.5.19:5061` | Stable signaling front doors observed in the captures |
| FreeSWITCH pod | `172.20.63.211`, media ports `11116` and `11278` | Hidden B2BUA/media endpoint; must not be advertised to clients |
| RTPEngine internal | `172.20.56.1`, ports `11016/11017`, `11154/11155`, `11084`, `11052/11053` | Site-local relay interface and allocations |
| RTPEngine public | `24.86.197.63:11168/11169` | Public carrier media address for the captured leg |
| Provider | `34.210.91.112:5061`, `67.231.3.94:43708` | Flowroute signaling and media |
| Groundwire IPv4 candidates | `10.0.0.86`, `10.1.20.21`, `10.155.12.207` | Endpoint-provided candidates; not all are necessarily routable |
| Groundwire IPv6 candidates | `2604:3D08:697F:8BF0::C88F`, `2604:3D08:697F:8BF0:18A2:FBA9:C37F:D2BE`, `2604:3D08:697F:8BF0:D41E:7EC4:1A16:88B4` | Endpoint-provided candidates; usability unverified |
| JsSIP IPv4 candidates | `10.0.0.92:65077`, `10.1.20.21:65077`, TCP host candidate port 9 | Host and server-reflexive candidates |
| JsSIP IPv6 candidates | `2604:3d08:697f:8bf0:496b:1525:80e2:4ccd:65078`, `2604:3d08:697f:8bf0:45a3:aece:14aa:5b79:65079`, `2604:3d08:697f:8bf0::f1a4:65080`, plus TCP-active port 9 candidates | Browser candidates; public reachability unverified |

## Confirmed corrections

The HA registrar continues to own WSS/TLS signaling, topology hiding and
per-replica connection routing. All Kamailio instances control the single
site-public RTPEngine through the stable NG-control Service; they do not run
replica-local media relays.

For endpoint-facing dialogs, RTPEngine now establishes two deliberately
different associations:

```text
browser or native phone
  ⇄ public RTPEngine leg (ICE and endpoint encryption as negotiated)
  ⇄ hidden RTP/AVP leg (no ICE, DTLS or SDES)
  ⇄ FreeSWITCH
```

The internal offer uses `RTP/AVP ICE=remove DTLS=off SDES=off
rtcp-mux-demux`. The browser-facing offer/answer alone uses RTPEngine's
`WebRTC` policy. FreeSWITCH no longer receives a WebRTC marker or loads a
WebRTC media module for this path.

The core reply route now recognizes every response received on Kamailio's
internal TLS listener, including late final-response copies. It selects the
browser policy from the final WSS Via rather than requiring a Record-Route
that TOPOS may already have hidden. This closes the demonstrated path that
forwarded `172.20.63.211:11278` to the browser.

## Remaining verification

- Repeat both 7101-to-66 calls and confirm FreeSWITCH receives one RTP/AVP
  section containing only RTPEngine's internal address.
- Confirm browser-facing 200 responses advertise the public RTPEngine and
  contain ICE/DTLS-SRTP; confirm native TLS receives its negotiated public-side
  RTP/SRTP form.
- Confirm RTPEngine records both `offer` and `answer`, nonzero packet counters
  on both associations, selected codec, and clean deletion after BYE.
- Measure owner-hop timing for the client BYE with one capture point per hop.
- Interpret repeated 200/ACK pairs only after deduplicating Homer records by
  capture node and packet tuple.

RTPEngine uses one active media pod. Valkey-backed state, readiness gating and
Kamailio control retries provide replacement recovery, but they do not prove
that an established UDP flow survives loss of the active media pod. The
[RTPEngine HA runbook](avoip/rtpengine-ha.md) remains authoritative for that
limitation.
