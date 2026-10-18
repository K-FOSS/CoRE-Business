# AVoIP stateful SIP upgrade tracker

The [architecture, state boundaries, failure matrix, migration and validation plan](docs/SIP-STATEFUL-HA.md) define the target. Status is **Open** unless repository or live test evidence cited here meets the acceptance gate. Current manifests and existing local tests are context, not completion evidence for these phases. Do not change runtime behavior solely to close a documentation item.

## Progress recorded 2026-10-07

The operator reports that the first pieces of the new internal SIP system are
live in YVR. The fetched Backplane ApplicationSet revision
[`a39ecb3`](https://github.com/K-FOSS/CoRE-Backplane/commit/a39ecb3) enables the
single-replica `private-sbc` instance alongside the existing carrier instance
for `core-home1-talos-prod`. That is deployment configuration evidence; this
workspace has not observed Argo CD health or exercised SIP through that live
instance. The registrar is not yet proven operational: the configured
instance does not by itself establish a live database claim, successful Digest
registration, contact routing, or audio.

The operator also correlated an Iristel call in Homer and reported
approximately 120 seconds of conversation, 129 seconds total, and a complete
recording. This supports the beyond-60-second voice observation and the report
that the roughly 32-second issue is fixed. Retained SIP evidence for the 2xx
ACK at both hops and normal BYE/200 is still needed to close the full baseline.
The report and limits are recorded in [SIP-IDENTITY.md](docs/SIP-IDENTITY.md).

The chart now makes RTPEngine media Service traffic policy configurable and
validates `Cluster`/`Local`; its default is `Cluster`. The policy change is
published in Business commit `2a1399a`. Confirm the generated YVR Service and
verify two-way RTP/UDPTL after its site rollout; rendered manifests are not
live media evidence. Carrier SIP remains independently configured.

The chart also has disabled-by-default Asterisk WSS/WebRTC support for the
[SIP Core Home Assistant client](https://github.com/TECH7Fox/sipcore-hass-integration),
documented in [SIPCORE-HASS.md](docs/SIPCORE-HASS.md). It defines secret-backed
static extensions, a WSS Gateway route, exact internal dial permissions, and
optional UDP media exposure. This is code/configuration support only: no YVR
extension, Vault credential, route, RTP Service, or Home Assistant
registration/call has been enabled or observed. It does not complete the
planned Authentik-backed dynamic registrar or first-party webphone.

## Progress recorded 2026-10-17

Recent chart changes address several SIP teardown and trace-correlation
issues. Private BYEs can route to FreeSWITCH over TLS; outbound Flowroute
signaling selects the TLS gateway and its listener; FreeSWITCH's Flowroute
profile now uses the `soft` RTP timer associated with the observed delayed-BYE
failure mode. SIP Core call correlation now propagates a trusted `X-Call-ID`
alias while preserving each dialog's native Call-ID. The new alias depends on
Homer's `1_call` correlation script being activated in its persistent settings;
chart configuration only seeds that script. See [Homer correlation](docs/HOMER.md)
and the [outbound teardown runbook](docs/avoip/runbooks/outbound-flowroute-teardown.md).

Live evidence now includes one Flowroute-originated BYE that reached its
FreeSWITCH dialog owner and received a relayed `200 OK`, with INVITE, ACK and
BYE handled by different carrier Kamailio replicas. A separate call still
showed a delayed BYE with no FreeSWITCH SIP response before Kamailio timed out;
the exact FreeSWITCH wait remains unexplained. The operator subsequently
reported instant hangups in all directions, but that report lacks a retained
Call-ID trace. Treat these as progress samples, not proof that teardown is
consistently fixed. The timer change and current chart state need post-rollout
verification against the actual SIP response sequence.

The [RTPEngine failure runbook](docs/avoip/runbooks/rtpengine-failure.md)
records the failure procedure and evidence requirements. Keep media-engine
failure behavior separate from SIP dialog recovery and do not infer active-call
survival from signaling success.

Two operator-initiated YVR voice samples were observed on `2026-10-17`. The
outbound Flowroute call answered and cleared normally after 40.640 seconds of
billable time; RTPEngine recorded media packets in both directions. It is a
useful signaling/media sample, but it does not meet the >60-second voice
acceptance threshold. The subsequent inbound Iristel call rang for about 20 seconds,
then received CANCEL, returned `200` for CANCEL, `487` for INVITE, and ACK for
the non-2xx response. It was not answered and is not a successful voice
baseline; the operator reports that the iPad did not ring. The available trace
confirms the carrier-side attempt reached public Kamailio. A later Asterisk
log at `17:39 UTC` shows an inbound dial to `7101`, an INVITE, then
`180 Ringing` from a downstream contact; the 30-second dial ended unanswered. A
read-only status query shortly afterward showed two available `7101` contacts,
but neither log identifies which contact was the iPad or proves it rang there.
Trace the INVITE/180 across the WSS owner and map the contact to the iPad before
repeating the call. Once the endpoint rings, capture an answered call that
stays connected beyond 60 seconds and ends normally, including both-hop ACK
and BYE/200 evidence. These samples do not establish subjective audio quality
or fax behavior.

A further inbound YVR attempt at `17:43 UTC` received `180 Ringing` at
`17:43:53`, then `200 OK` at `17:44:01`; Asterisk recorded BYE at `17:44:09`
and 7.049 seconds of billable time. This confirms a downstream `7101` contact
answered a short call, but does not identify the contact as the iPad or confirm
usable audio. It does not meet the >60-second baseline.

Hangup propagation is now a concrete P0 concern. On that `17:43:53` inbound
call, Asterisk received BYE from `7101` and began a BYE toward FreeSWITCH at
`17:44:09`; FreeSWITCH's carrier and Asterisk legs remained active until
`17:44:26`, when a carrier-originated BYE arrived and received `200 OK` from
the backend. A second inbound call showed the same ordering: Asterisk began
BYE toward FreeSWITCH at `17:44:54`, while the carrier-originated BYE arrived
at `17:45:15` and received backend `200 OK`. Carrier Kamailio logs show no
backend-originated BYE before those carrier BYEs. This supports the reported
hangup-propagation gap, but does not by itself prove whether Asterisk's BYE
reached FreeSWITCH; that peer exchange needs targeted tracing.

At `2026-10-17 17:31 UTC`, a read-only DC1/YXL snapshot showed Asterisk,
both FreeSWITCH replicas, all three carrier Kamailio replicas, the private
Kamailio pod, RTPEngine, and both RTP Valkey pods ready. The shared
audio-library pod was in `CrashLoopBackOff` with 1,262 restarts. At `17:32 UTC`,
the YVR/Home1 snapshot showed Asterisk, both FreeSWITCH replicas, all three
carrier Kamailio replicas, private Kamailio, RTPEngine, both RTP Valkey pods,
and the Core media service ready; the audio-library pod was in
`CrashLoopBackOff` with 823 restarts. In both sites its startup log reports an
NGINX PCRE compile error at the WAV filename regex in `default.conf`; the live
ConfigMap has an unquoted `{0,63}` quantifier, which NGINX parses as
configuration syntax instead of part of the regex. The chart source now quotes
the regex and `AVoIP/tests/sound-library-nginx-render.sh` plus `helm lint`
pass. A later read-only check on `2026-10-17` found both editor pods ready
(`1/1`) with zero restarts and both 5 GiB RWX PVCs `Bound`. `IVRGreet.wav`
was present in both volumes, but the YVR and YXL checksums differed. The
earlier crash-loop issue is resolved; browser authorization and PBX playback
still need end-to-end verification. See the
[sound-library guide](docs/avoip/sound-library.md) for the site state and
replication limitation.

YVR's RTPEngine pod was ready at the time of the snapshot but had 97 container
restarts. Its prior log records a fatal connection failure to the RTPEngine
Valkey Service (`10.44.7.43:6379`, `No route to host`) at
`2026-10-15 04:41:30 UTC`. The container next started at `04:46:39 UTC`. The
service currently has two endpoints and both Valkey pods are ready. This does not
establish why the route failed or whether any calls lost media. Kubernetes in
the DC1 context did not expose the Argo CD Application resource, so the
reconciled revisions for these observations were not verified through Argo.

The 2026-10-17 HAR follow-up now has a concrete registration-response fix.
Commit `7db3791` removes Kamailio's broad 2xx Contact rewrite; the live WSS
ConfigMap contains the fix and all three WSS pods are ready. The parent Argo
Application remains OutOfSync/Progressing for other resources, and browser
`registered` event verification remains pending. The exact Asterisk binding
from the HAR is stored with OWNER1 Path and its observed WS alias; do not use
the OWNER2 Path in the browser response as proof of this binding's route.

A later browser HAR records a successful authenticated outbound call to
`[EXTERNAL-DESTINATION]` (Call-ID omitted). The browser received
183 early media and a final answer with matching public media address, ICE
ufrag, and DTLS fingerprint; session UPDATE succeeded about 45 seconds after
answer. The browser sent BYE after about 73 seconds and received its matching
200 OK about 1.313 seconds later. WebSocket OPTIONS qualification continued.
The operator reports the external party disconnected. This is a successful
browser-side long-call/refresh/hangup sample, not proof of carrier-leg BYE
receipt or backend media cleanup. Correlate both B2BUA legs and measure the
BYE interval at each boundary. It does not resolve the earlier malformed
REGISTER Contact responses or same-dialog duplicate INVITE 200 responses with
divergent SDP; both still need internal traces and focused regression checks.
The confirmed Contact defect was a Kamailio reply substitution that replaced
every owner Contact host with `.invalid`; the current source removes that
reply rewrite and retains the request-side routable owner Contact. JsSIP 3.10.6
drops the malformed response during parsing, before the registration
transaction, so frontend event verification is still required. Why the HAR
showed different Contact forms on OWNER0 versus OWNER2 remains unproven; the
read-only cluster credential has expired, preventing comparison of historical
pod revisions and internal logs. JsSIP 3.10.6 ACKs a later 2xx for its
established dialog without applying that response's SDP; the divergent SDP's
server-side path remains unknown. Do not count the new call as resolving
either defect.

### Remaining implementation

- Finish and observe YVR internal SIP rollout, then exercise mTLS peer
  authorization, internal routing, dialog ACK/BYE/re-INVITE/UPDATE, and backend
  health behavior. Keep the registrar pilot disabled until its PostgreSQL
  claim, migrations, TLS trust, and identity provisioning are verified.
- Verify browser authorization and playback through Asterisk, and verify
  playback at YXL. YVR FreeSWITCH successfully loaded and played a prompt from
  its sound library. Both editor pods are healthy and their PVCs are bound;
  site-local files do not synchronize automatically.
- Complete the SIP identity lifecycle: immutable user/AoR mapping, authorized
  extension permissions, short-lived per-device Digest issuance, expiry,
  rotation, revocation, and active-contact invalidation. The current `User`
  Composition does not publish SIP credentials or entitlements.
- Validate authenticated registration and device-to-device calls live,
  including NAT, multiple contacts, expiry, deregistration, and reconnection
  after loss of the connection-owning proxy. Implement WSS access, Origin and
  rate controls, Path/flow ownership, keepalives, and bounded re-registration.
- Build the Authentik OIDC application, BFF/session API, credential broker,
  TURN credential endpoint, and SIP.js application. The browser login,
  credential, WSS, WebRTC, Safari/iPad, and external restrictive-NAT paths do
  not exist yet.
- Complete the outbound carrier path as a live, explicitly operator-initiated
  test. The opt-in service-peer route and restrictive test destination render
  and parse, but the pilot remains disabled in Backplane; user PSTN entitlements
  and optional carrier Digest mode are outstanding. Do not run a billable call
  automatically.
- Add dispatcher-based, individually addressed PBX pools with dialog/backend
  pinning and health/drain handling; establish RTPEngine instance ownership
  and failure behavior before scaling. Cross-proxy dialog recovery,
  cross-site signaling/ownership, and active-call failover remain unproven.
- Preserve call-specific `rxfax` results, TIFFs, negotiated mode and SIP ACK
  traces for the reported YVR G.711 and YXL T.38 fax paths, and for automatic
  detection on the voice number. The functional results are reported working;
  protocol and artifact evidence remains undocumented. Verify the existing
  CoTURN deployment and MatrixRTC prerequisites. MatrixRTC, native
  incoming-call integration, and a SIP/Matrix gateway are separate future
  projects.

No plan phase is complete solely because its templates render. Keep the phase
table below as the acceptance ledger and update it only with the linked test
or live evidence required by each row.

| Priority / phase | Dependency | Work and evidence to collect | Acceptance | Status |
| --- | --- | --- | --- | --- |
| P0 / 0 — Working baseline | None | The inbound approximately 32-second ACK-timeout issue is reported resolved. Capture serialized public Contact/Record-Route, public/private socket choice and outbound SDP offer/answer. Inventory deployed versions, replicas, endpoints, Services, Gateway routes, certificates, PROXY protocol and media address ownership at YVR/YXL. Save successful trace/Call-ID references and separate voice/fax reports. | Voice has bidirectional audio beyond 60 seconds, ACK at both hops and clean BYE/200. Dedicated fax behavior is documented separately. | **Partial** — the operator correlated a 129-second total voice call with a complete recording in Homer; see the [SIP identity report](docs/SIP-IDENTITY.md). The 2026-10-18 outbound sample now adds a call lasting about two minutes with carrier `183`/`200`, ACK relay, remote BYE, successful RTPEngine deletion, downstream `200 OK`, and FreeSWITCH `NORMAL_CLEARING`; RTP packet and codec evidence for this exact sample remains to be attached. The teardown runbook records a separate delayed-BYE failure and earlier uncorrelated instant-hangup reports. Fax and device-to-contact acceptance remain open. The [test fixture](tests/README.md) is not a live call. |
| P0 / YVR fax baseline | Dedicated fax DID and Home1/YVR [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml) G.711-only override | Preserve the reported working G.711 receive path. Capture a new call-specific `rxfax` result, page count, TIFF on the retained spool, SIP ACK at both hops, and G.711 media trace. Investigate T.38 separately before enabling it in YVR; verify YXL fax on its own settings. | A retained YVR trace shows successful G.711 fax reception and output; no T.38 success or YXL result is inferred from it. | **Partial** — YVR G.711 fax reception is reported working; T.38 has not worked. The G.711-only override is published, but a post-change trace and TIFF check remain open. See [fax call path](docs/PHONE-TREE.md). |
| P0 / RTC inventory | None | Inspect the existing [NATPuncher ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/NATPuncher.yaml) and live CoTURN: advertised address/DNS/cert, 3478/5349 transports, relay range including upper boundary, REST secret publication/rotation, YXL/YVR availability, allocation capacity and observability. Inventory deployed Synapse/MAS/Element Web/Element X versions and RTC settings under the [Matrix ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Social/Matrix.yaml). | External authenticated allocations and restrictive-network fallback are captured by client/transport; version and site inventory distinguishes manifests from observed workloads. | **Partial** — the fetched Backplane revision `04fdf818501305364cc02f449363cdd984776e1a` enables CoTURN in both DC1/YXL and Home1/YVR. DC1 publishes `nat.mylogin.space` through LoadBalancer `66.165.222.101`; Home1 publishes `nat-home1.mylogin.space` through kube-vip `10.0.0.46` and overrides the relay range to `15000–15049`. Home1 UPnP includes TCP/UDP `3478` mappings. The chart uses Dragonfly database `154` for allocation statistics, and Asterisk TURN credential generation reuses Matrix's `matrix-turn-auth` Secret. Verify Argo CD reconciliation, Secret readiness, DNS/certificate state and authenticated TURN allocations; live capacity, upper-bound exposure, and client fallback remain unverified. |
| P1 / 1 — Correct routing | P0 | Centralize destination, TLS SNI and sending socket; separate initial/in-dialog routes. Put negative-response ACK and CANCEL on the matching transaction path. Authorize carrier/backend independently of To tags. Replace broad/positional header rewriting with direction-specific handling; log actual pod identity and connection correlation without credentials. Add meaningful SIP tests. | Tests cover positive/negative INVITE outcomes, ACK, CANCEL, BYE in both directions, re-INVITE, duplicate replies, invalid routes, unauthorized traffic and socket choice; live baseline still passes. | **Partial** — routing fixes now cover private BYEs over TLS, Flowroute TLS gateway/listener selection, and transport-specific routing and cross-leg correlation. The 2026-10-18 outbound sample confirms remote BYE relay, RTPEngine deletion, and backend `200 OK`; broader negative-path acceptance and the separate delayed-BYE investigation remain open. The private role and [outbound service-peer pilot](docs/OUTBOUND-PILOT.md) render and pass the pinned Kamailio parser; Backplane enables one private-SBC instance in YVR, reported live by the operator. The outbound pilot remains disabled; optional carrier Digest mode and user-level PSTN entitlements remain open. |
| P2 / 2 — Balance within a site | P1 | Add [dispatcher](https://www.kamailio.org/docs/modules/stable/modules/dispatcher.html) with individually addressable FreeSWITCH endpoints. Select once per initial attempt and retain the winning endpoint. Define probes, capacity, drain and safe pre-answer retries; never replay answered calls or duplicate downstream calls. Pin RTPEngine NG operations and media IP/port delivery to one instance. Specify Kubernetes EndpointSlice discovery/reconciliation. | Calls distribute across healthy replicas. Pool changes retain established backend/media owners. Draining stops new assignments and existing calls finish. | **Open** — one backend Service and one media control Service today. |
| P3 / 3 — Recover routing on another proxy | P2 | Evaluate [topos](https://www.kamailio.org/docs/modules/stable/modules/topos.html) supported stores in place of manual hiding; evaluate [dialog/DMQ](https://www.kamailio.org/docs/modules/stable/modules/dialog.html) supported fields. Choose one authoritative token/registry for site/backend/media assignment; list custom fields needing persistence. Test Valkey/Dragonfly commands, ACL/TLS, retention, expiry, cleanup, persistence and outage policy; cover early dialogs, forks, retransmissions and visibility races. Match identity and config on Kamailio replicas. | Request on another replica recovers owner and reaches original live backend; transaction and connection limits are documented. | **Open** — no shared Kamailio dialog assignment in current config. |
| P4 / 4 — Multisite ingress | P3 and independent site-local new-call path | Use global `sip.resolvemy.host` entry plus configurable cluster-scoped identities and explicit owner. Forward other-site ingress to owner over verified private TLS; prefer local state lookup. Define partition, replication lag, split-brain prevention and ownership rules. Evaluate K8GB/DNS steering, carrier fallback and BGP anycast separately. Use usable SIP/media health; define connection drain and route withdrawal. | Either site accepts new calls during intersite outage. Cross-site signaling reaches a live existing owner. Full site loss has a tested, explicit outcome. | **Open** — global mode is opt-in; live steering/owner forwarding unverified. |
| P5 / 5 — Evaluate active-call recovery | P4 and isolated fault test path | Test [RTPEngine](https://github.com/sipwise/rtpengine) persistence, standby restore, takeover, keyspace notifications, Redis compatibility, public media IP/port takeover and fencing. Evaluate FreeSWITCH voice, IVR and fax recovery separately. Test TCP/TLS reconnection and carrier behavior; measure interruption and unsupported sessions. | Any claimed surviving call has a repeatable voice/media trace and measured interruption for that exact failure. Unsupported types are listed. | **Open** — no active-call takeover proof. YVR RTPEngine failed startup on 2026-10-15 after `No route to host` connecting to the Valkey Service; it is now ready, but the outage cause and call impact are unknown. |
| P6 / 6 — Identity and provisioning | Identity schema and current [User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml); P0 voice baseline for call tests | Define immutable ID, AoR, extension, display name, group, tenant/site scope, permissions and reconciliation. Define suspension/deletion/reassignment/rotation. Distinguish humans, browser sessions, devices, automation and trunks. Define service owner, expiry and outbound restrictions. Pilot a scoped short-lived SIP Digest credential or separately provisioned device secret; test certificates where supported. Follow the [internal registrar integration contract](docs/INTERNAL-REGISTRAR.md). | Pilot identity and service account are provisioned without per-user dialplan edits; suspension blocks new/refresh REGISTER and unauthorized calls, extension reassignment cannot inherit old credentials. No browser primary directory password is retained. | **Open** — no credential issuer or dynamic identity policy is present. |
| P7 / 7 — Registrar and location | P6 credential/authorization pilot; P1 routing; P3 for cross-replica recovery | Evaluate Kamailio registrar/usrloc shared or replicated modes and a site-local writable authority. Test multiple contacts, expiry/refresh/deregistration, limits, NAT, Path/flow, WSS/TLS transport owner, cross-replica lookup, reconnect and re-registration after replica/site loss. Isolate REGISTER from carrier ingress and define partition behavior. | Provisioned users register without static per-user destinations; authorized calls reach active devices, revoked accounts cannot create/refresh registrations, and loss of the connection owner causes bounded reconnect/re-registration rather than a false reachable contact. | **Partial implementation, not accepted** — chart supports database-only provisioning separately from enabling the private Digest registrar; see [registrar pilot](docs/INTERNAL-REGISTRAR.md). Home1 Git desired state selects database-only provisioning, but live PostgreSQL provisioning has not been reconciled or verified. No credential broker, Authentik projection, REGISTER/contact evidence, or user WSS ingress. |
| P8 / 8 — SIP/WebRTC phone | P6–P7 and RTC inventory; Phase 2 media pinning for scaled operation | Compare maintained SIP.js/JsSIP and native SIP clients. Add proposed OIDC login, WSS with valid cert/ingress, existing CoTURN integration, ICE and RTPEngine DTLS-SRTP/codec tests. Specify call/answer/DTMF/mute/hold/transfer/device/status UI; test mobile Safari/iPad, permissions, audio output, reconnect and browser background limits. Test browser-browser, browser-device and browser-Flowroute calls. | Authorized user signs in, receives AoR, registers and completes bidirectional calls without manual SIP configuration; iPad Safari and network changes tested. Background incoming calls are not claimed without native push proof. | **Open** — no OIDC webphone, dynamic WSS registrar, TURN credential broker, or live browser call test. Separate disabled-by-default Asterisk support for the third-party [SIP Core client](https://github.com/TECH7Fox/sipcore-hass-integration) is documented in [SIPCORE-HASS.md](docs/SIPCORE-HASS.md); it is not site-enabled or live-verified. |
| P9 / 9 — Directory switchboard | P6–P8, policy and event authority | Generate authorized directory from identity/groups. Define extensions, ring groups, queues, voicemail, schedules, IVR/AI routing, SIP presence/BLF versus authoritative call/queue events. Evaluate FusionPBX/operator alternatives and FreeSWITCH/Asterisk event integration. Define attended/blind transfers, operator permissions, scoped APIs, abuse and concurrent device/call limits. Preserve the dedicated fax DID and automatic fax detection on the voice number. | Dynamic users/memberships/contact lookups work with declarative route policy; unauthorized directory/API/outbound actions fail; queue/transfer events are authoritative; voice and fax paths pass. | **Open** — no implemented dynamic directory or operator console. |
| P10 / 10 — MatrixRTC / Element Call | RTC inventory and current [Element Call self-hosting guide](https://github.com/element-hq/element-call/blob/main/docs/self_hosting.md); independent of SIP phases | Verify pinned Synapse/MAS/Element support for delayed events, transport discovery and embedded/standalone Call. Specify LiveKit SFU, MatrixRTC authorization service, discovery, WSS/HTTPS and public media ingress. Test MAS/OIDC membership authorization, existing CoTURN compatibility versus SFU-specific TURN, direct/relay UDP/TCP/TLS paths, placement, capacity, room affinity/draining/failure. Test Element Web and Element X iOS/iPadOS. | Authorized room users join audio/video and screen share, unauthorized users cannot obtain room tokens, restrictive-network calls and reconnects work with measured failure behavior. Native MatrixRTC works without SIP gateway. | **Open** — no MatrixRTC backend or Element Call deployment in current Matrix chart. |
| P11 / 11 — Native incoming-call experience | P10 for MatrixRTC, P8 for SIP if selected native SIP client; push inventory | Verify selected clients' CallKit versus Android Telecom support separately for SIP and MatrixRTC. Document APNs/FCM, push gateway, wake-up, locked-device UI, audio session, Bluetooth and interruption handling. Test answer/decline, missed calls, network changes and competing system calls. | Actual supported native client receives and handles locked-device calls on iOS/iPadOS and Android with push and OS call UI; browser/standalone webpage has no claimed CallKit. | **Open** — no client/version/push proof. |
| P12 / 12 — Optional SIP/Matrix gateway | P7–P8 and P10 accepted independently | Evaluate a supported gateway; define SIP/Matrix identity mapping, room consent/membership, signaling, media termination/transcoding, DTMF/transfers, encryption and fault boundary. Shared TURN is insufficient. | Pilot cross-protocol calls have explicit identity, consent and media traces; gateway loss leaves independent SIP and MatrixRTC calls functional. | **Open** — no gateway selected or configured. |

Keep the existing media configuration, verified TLS, private internal identities, current carrier authorization and fax isolation on its dedicated DID through every phase. Reuse existing CoTURN with consumer-specific credential lifetimes and authorization; do not add a duplicate TURN deployment. No timeout increase, weaker TLS verification or direct-media workaround qualifies as completion. Link actual render/test/trace evidence here as work proceeds; do not mark a phase complete from a proposed design or pod readiness alone. SIP login, browser SSO, registration failover, CallKit and background incoming calls remain unverified.
