# SIP call captures: 2026-10-23 05:55–06:04 UTC

This report is intentionally limited to two user calls represented by three
SIP dialogs. Network addresses and direct telephone numbers are omitted.

| User call | SIP Call-ID | Leg |
|---|---|---|
| Groundwire 7101 to 66 | `DC5CFC2C41A12F057BF62DC6E2EEA618109C33ED` | Endpoint to FreeSWITCH |
| JsSIP 7101 to external destination | `2p085q8gir2kvv11fb2k` | Endpoint to FreeSWITCH |
| Same JsSIP call | `71ef7eea-494a-1240-2881-000000000000` | FreeSWITCH to Flowroute |

The last two IDs are B2BUA legs of one call and correlate through
`X-Call-ID: 2p085q8gir2kvv11fb2k`. The report contains no Digest response,
ICE password, SRTP key, direct telephone number, or IP address.

## Groundwire dialog

### Chronology

| UTC | Source role | Destination role | Transport | Message | CSeq / result |
|---|---|---|---|---|---|
| 05:55:56 | Groundwire | Public SIP ingress | TLS | Initial `INVITE` to 66 | First INVITE challenged |
| 05:55:56 | HA registrar | Groundwire | Existing TLS flow | `407 Proxy Authentication Required` | Normal Digest challenge |
| 05:55:56 | Groundwire | HA registrar | TLS | Authenticated `INVITE` | `2 INVITE`; credential omitted |
| 05:55:56 | HA registrar | Groundwire | TLS | `100 Trying` | Transaction accepted |
| 05:55:56 | HA registrar | FreeSWITCH Service | Internal TLS | Forwarded `INVITE` | RTPEngine-modified SDP |
| 05:55:56 | FreeSWITCH | HA registrar | Internal TLS | `488 Not Acceptable Here` | Q.850 cause 88, `INCOMPATIBLE_DESTINATION` |

Contact and Record-Route values were not retained in the reconstructed record,
so they cannot be stated from this evidence.

### SDP transformation

| Property | Groundwire offer | FreeSWITCH-facing copy before correction |
|---|---|---|
| Connection | Endpoint candidate address | RTPEngine pod address |
| Media 1 | RTP/AVP on an endpoint port | RTP/AVP on an allocated relay port |
| Media 2 | RTP/SAVP on the same endpoint port | RTP/SAVP on a second relay port |
| RTCP | Endpoint RTP/RTCP pair | Separate relay RTP/RTCP pairs |
| Security | ICE, SDES and DTLS attributes | ICE, SDES and DTLS attributes remained |
| Codecs | Opus, PCMU, PCMA, G.722, iLBC, G.729, GSM and telephone-event | Payload set retained |

RTPEngine anchored both sections, but it did not terminate endpoint media
security before the internal handoff. FreeSWITCH therefore received two audio
sections with mixed AVP/SAVP and endpoint-style ICE/crypto negotiation. The
overlapping codecs show that absence of a common codec is not an adequate
explanation for the 488. The demonstrated defect is the incomplete
public-to-private media-boundary conversion.

## JsSIP endpoint dialog

### Chronology

| UTC | Source role | Destination role | Transport | Message | CSeq / result |
|---|---|---|---|---|---|
| 06:04:26 | Browser | HA registrar WSS listener | WSS | Initial `INVITE` | `4571 INVITE`; browser `.invalid` Via; 90-second timer |
| 06:04:26 | HA registrar | Browser | WSS | `407 Proxy Authentication Required` | Expected challenge |
| 06:04:27 | Browser | HA registrar | WSS | Authenticated `INVITE` | `4572 INVITE`; credential omitted |
| 06:04:27.126381 | HA registrar | FreeSWITCH Service | Internal TLS | Forwarded `INVITE` | Owner Contact selected replica 2; timer normalized to 120 seconds |
| 06:04:34.438564 | FreeSWITCH | HA registrar | Internal TLS | `200 OK` | Answer contained a pod media address |
| 06:04:35.145676 | HA registrar | Browser | WSS | `200 OK` | The pod media address was still present |
| 06:04:35.326682 | Browser | HA registrar | WSS | `ACK` | Dialog ACK |
| 06:04:35.751945–06:04:36.251993 | Both roles | Both roles | WSS/TLS | Additional `200 OK` and ACK copies | Delayed retransmission or capture duplication remains unproven |
| 06:04:38.350216 | Browser | HA registrar | WSS | `BYE` | User-side termination |
| 06:04:40.160380 | HA registrar | FreeSWITCH | Internal TLS | Forwarded `BYE` | Approximately 1.81 seconds after the first captured browser BYE |
| 06:04:40.164212 | FreeSWITCH | HA registrar | Internal TLS | `200 OK` | FreeSWITCH accepted teardown |
| 06:04:40.927183 | HA registrar | Browser | WSS | `200 OK` | Teardown response reached client |

The evidence does not contain enough per-hop timing to assign the full BYE
delay to a single component. TOPOS restoration, owner-pod forwarding, TLS
scheduling, and duplicated capture points remain candidates.

### SDP transformation

| Property | Browser offer | RTPEngine offer to FreeSWITCH | FreeSWITCH answer leaked toward browser |
|---|---|---|---|
| `o=` | Browser session with loopback origin | Rewritten by RTPEngine | FreeSWITCH-generated |
| `c=` | Browser-selected candidate | RTPEngine pod address | FreeSWITCH pod address |
| `m=audio` | UDP/TLS/RTP/SAVPF | UDP/TLS/RTP/SAVPF on a relay allocation | UDP/TLS/RTP/SAVPF on a FreeSWITCH allocation |
| ICE | Browser host and server-reflexive candidates | Sole RTPEngine candidate | FreeSWITCH pod candidate |
| DTLS | Browser fingerprint, `setup:actpass` | RTPEngine fingerprint, `setup:actpass` | FreeSWITCH fingerprint, `setup:active` |
| RTCP | mux | mux | mux |
| Codecs | Opus, RED, G.722, PCMU, PCMA, CN, telephone-event | Retained | Opus, telephone-event and CN |

The offer-side transformation replaced browser candidates with the relay but
still made FreeSWITCH a WebRTC endpoint. Live RTPEngine logs contained an
`offer` command but no corresponding `answer` command for this dialog. The
client-facing 200 consequently exposed a FreeSWITCH pod address. That was not
intentional direct media; it was a missed answer rewrite.

Signaling reached 200/ACK/BYE, but media is not proven. RTPEngine's retained
statistics showed no completed FreeSWITCH-side peer and no negotiated crypto
suite before deletion. Browser-side DTLS attempts and a successful SIP answer
must not be reported as confirmed audio.

## Correlated Flowroute dialog

### Chronology

| UTC | Source role | Destination role | Transport | Message | Result |
|---|---|---|---|---|---|
| 06:04:27 | FreeSWITCH carrier profile | Internal carrier-routing Kamailio | TLS | `INVITE` | Endpoint Call-ID copied into `X-Call-ID` |
| 06:04:27 | Internal carrier router | Carrier-facing Kamailio | TLS | Routed `INVITE` | Provider policy and identity applied |
| 06:04:27 | Carrier-facing Kamailio | Flowroute | TLS | Provider `INVITE` | Public carrier identity advertised |
| 06:04:33.307221 | Flowroute | Carrier-facing Kamailio | TLS | `200 OK` | Provider media endpoint supplied |
| 06:04:34.572477–06:04:34.644976 | FreeSWITCH through Kamailio | Flowroute | TLS | `ACK` | Dialog established |
| 06:04:35.338213–06:04:35.341754 | Same path | Same path | TLS | Additional ACK copy | Corresponds to an additional final-response copy |
| 06:04:40.391120 | FreeSWITCH | Flowroute through Kamailio | TLS | `BYE` | B2BUA tears down carrier leg |
| 06:04:40.484304–06:04:40.489175 | Flowroute | FreeSWITCH through Kamailio | TLS | `200 OK` | Carrier teardown completed |

FreeSWITCH generated the B2BUA Call-ID and copied the endpoint Call-ID into
`X-Call-ID`. AVoIP Admin's generated outbound route selected the provider,
permitted codecs and caller identity; FreeSWITCH applied those channel
variables, and carrier Kamailio applied the provider-specific Request-URI and
externally asserted identity.

### Carrier SDP

| Property | FreeSWITCH offer | Public offer | Flowroute answer | Internal rewritten answer |
|---|---|---|---|---|
| `o=` / `c=` | FreeSWITCH pod | Public RTPEngine | Provider media host | Internal RTPEngine |
| `m=audio` | RTP/AVP allocation | Public RTP/AVP allocation | Provider RTP/AVP allocation | Internal relay allocation |
| RTCP | Implicit/adjacent | Public adjacent allocation | Not reconstructed separately | Internal adjacent allocation |
| Codecs | PCMU, PCMA, telephone-event, CN | Same | PCMU, G.729, telephone-event | Common selection includes PCMU payload 0 |

The same site RTPEngine performs both directions of this translation. Its
internal interface uses the pod network and its external interface advertises
the site public media address. The observed answer rewrite proves the carrier
path invoked both offer and answer processing; it does not prove that the
browser A-leg carried audio.

## Address-class inventory

| Class | Recorded form | Required handling |
|---|---|---|
| Endpoint signaling | Groundwire TLS flow; browser WSS flow | Reuse the owning connection; never reconnect to a proxy ephemeral port |
| Kamailio signaling | Public listener, owner listener, internal listener, carrier listener | Pod addresses remain hidden and are never configuration targets |
| Kubernetes Services | FreeSWITCH and carrier-routing Services | Stable internal signaling targets only |
| FreeSWITCH media | Pod-local RTP allocation | Hidden behind RTPEngine on every endpoint and carrier leg |
| RTPEngine internal | Pod-local allocations | Visible only to in-cluster media peers |
| RTPEngine public | Site public media address and managed UDP range | Only endpoint/carrier-reachable media address |
| Provider | TLS signaling and RTP media hosts | Reached only through the carrier SBC and public RTPEngine |
| Endpoint ICE | Private, tunnel, server-reflexive, IPv6, and TCP-active candidates | Consumed by RTPEngine; never propagated to FreeSWITCH |

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

The initial implementation assumed that every FreeSWITCH response returned on
Kamailio's internal TLS listener. A post-rollout 7101-to-66 test disproved that
assumption: the internal Service returned the 200 through the frontend TLS
listener. The request-side RTPEngine offer ran, but no answer command followed,
so the FreeSWITCH media address reached the browser and DTLS could not finish.

The corrected classifier uses the preserved final WSS Via in addition to the
listener identity. The core reply route handles initial and retransmitted
answers; the transaction reply callback is a guarded fallback for the first
native TLS answer when listener mapping alone cannot classify it. The two
guards are mutually exclusive, so one wire response is transformed once. This
closes the demonstrated path that forwarded a pod media address to the browser.

The same live check found a separate WSS teardown defect. The answer Contact
correctly carried a backend TLS connection alias, but client-originated ACK and
BYE did not consume it after TOPOS restoration. They therefore had no selected
destination socket and could reach a different FreeSWITCH dialog owner, which
returned 481. Sequential requests now resolve the restored backend alias before
the generic backend fallback. This applies to ACK, BYE, UPDATE, INFO, REFER and
re-INVITE rather than special-casing hangup. The native TLS control call already
completed BYE with 200; the WSS path requires a post-rollout confirmation.

That same test confirms that timer normalization and the private media offer
now pass both former signaling gates: FreeSWITCH entered destination 66,
answered it and ended normally without 422 or 488. Media was not yet valid in
that test because it occurred before the answer-classifier correction.

## Remaining verification

- Repeat both 7101-to-66 calls and confirm FreeSWITCH receives one RTP/AVP
  section containing only the internal RTPEngine address class.
- Confirm browser-facing 200 responses advertise only the public RTPEngine and
  contain ICE/DTLS-SRTP; confirm native TLS receives its independently
  negotiated public-side RTP/SRTP form.
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
