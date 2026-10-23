# Home Assistant SIP Core with static Asterisk extensions

AVoIP uses [TECH7Fox/sipcore-hass-integration](https://github.com/TECH7Fox/sipcore-hass-integration)
for Home Assistant SIP. The currently running integration version is **v5.1.2**,
as confirmed by the operator on 2026-10-18. Use this version as the baseline
for client compatibility investigations.

The current Home1 Envoy Gateway resources, TLS termination, Host/Origin
contract, timeout layers, and WSS instance are recorded in the [SIP HA gateway
baseline](SIP-STATEFUL-HA.md#sip-core-wss-integration-baseline-observed-2026-10-09).
The generated HTTPRoute is owned by this chart and currently targets the
three-replica `internal-websocket` Kamailio Service on port 8088. Increasing
replicas alone is unsafe:
the shared Envoy Service balances new connections but cannot route later SIP
requests to the Kamailio process that owns a registered WebSocket.
The chart's opt-in `websocketHA` mode runs in a separate named
`internal-websocket` Kamailio instance, apart from the ordinary `internal`
private-SBC. It supplies stable StatefulSet owner DNS, Path routing and
Asterisk return routing. Home1 currently uses this three-replica WSS edge
while retaining the one-replica `internal` instance. See
[SIP Stateful HA](SIP-STATEFUL-HA.md#implemented-wss-edge-mode) for the
owner-path behavior and limitations.

The [SIP Core Home Assistant integration](https://github.com/TECH7Fox/sipcore-hass-integration)
is a browser WebRTC SIP client. It connects to Asterisk over WSS and registers
one or more configured SIP users. Its separate optional Asterisk integration
uses AMI; this AVoIP setup does not expose AMI. Follow the upstream
[SIP Core setup](https://tech7fox.github.io/sip-hass-docs/docs/tutorial/card),
[SIP Core settings](https://tech7fox.github.io/sip-hass-docs/docs/card/settings),
and Asterisk's [WebRTC/PJSIP guide](https://docs.asterisk.org/Configuration/WebRTC/Configuring-Asterisk-for-WebRTC-Clients/).

## Signaling identity and client address

The browser connects to `wss://<configured-hostname>/ws`. Envoy Gateway
terminates WSS and proxies the HTTP WebSocket upgrade to the dedicated
separate WSS Kamailio instance on port 8088. That edge relays SIP to Asterisk
over TLS on port 5061. The ordinary `internal` private-SBC remains separate.
Asterisk's reverse signaling leg returns to the registered
owner's TLS listener (default port 5063) when HA Path is enabled, or to the
single shared return Service in legacy mode. The carrier SBC does not process this
WebSocket or Asterisk signaling path; its FreeSWITCH, carrier, and fax routes
remain on the carrier instance. The HTTP `X-Forwarded-For` header belongs to
the upgrade request; it is not part of the SIP messages carried inside the
WebSocket connection.

The same SIP Core hostname also has a `TLSRoute` on `main-gw`'s `tls-mqtt`
listener. A native SIP client connects to `sips:<extension>@<hostname>` using
TLS on port `8443`; the hostname in TLS SNI selects the route. TLS passes
through Envoy to the selected Kamailio SIP Core ingress listener on its
dedicated backend port `5064`. Kamailio preserves the client source with
PROXY protocol v2 and relays SIP to Asterisk, which uses the same per-extension
Digest credential as WSS. Configure the extension as both the SIP username and
authentication username, and use its existing SIP Core password. The route is
publicly reachable through `main-gw`; SIP Digest and the extension's existing
dialplan allowlist remain the authorization checks. Configure the SIP address
as `sips:<extension>@<hostname>`, the registrar as `<hostname>`, and TLS
transport on port `8443`.

This TLSRoute passes TLS through, so the phone validates the certificate
presented by Kamailio—not the certificate on `main-gw`. Its SIP Core SNI
selects a dedicated `sipcore-public-tls` certificate issued using
`sip.tls.issuerName` (`kjdev-cluster`, the public ACME issuer, by default).
The existing Kamailio SIP certificate and Vault mTLS identity remain unchanged.
The dedicated certificate must be Ready and chain to a CA trusted by the phone.

The legacy PJSIP endpoints are generated with Asterisk's `webrtc=yes`
settings. In the HA registrar path, RTPEngine terminates the browser's WebRTC
association and presents conventional RTP/AVP to FreeSWITCH. Browser-facing
SDP continues to use WebRTC ICE/DTLS-SRTP, while native SIP/TLS clients use an
independently negotiated public-side association. Registration over TLS alone
does not prove media compatibility; both transports require live media tests.
The frontend HA routing/registration path is transport-neutral; WSS is one
supported client transport alongside SIP over TLS.

When a contact's browser WebSocket has closed, its owner replica cannot relay
to that local flow. For non-ACK requests the WSS edge returns SIP `430 Flow
Failed` so Asterisk can treat the specific contact as failed; ACK receives no
response. SIP Core AORs use `qualify_2xx_only=yes`, so a failed OPTIONS probe
does not leave the contact marked reachable, and `remove_unavailable=yes`
prioritizes failed contacts when a later registration must make room under
`max_contacts`. This does not remove a failed contact immediately: it remains
until it expires or a replacement registration needs its slot. A client must
reconnect and register to restore the flow.

PJSIP endpoint selection uses the SIP username before source-IP matching. For
extension `7101`, the generated endpoint accepts the `username` and
`auth_username` identifiers, and its Digest `auth` object still validates the
password. Selecting endpoint `7101` does not authenticate the request. The
endpoint keeps its private `from-sipcore-7101` context and exact
`allowCallsTo` destinations, including `9090` when configured. A spoofed
`X-Forwarded-For` value cannot select the endpoint, authenticate SIP, or change
the actual PJSIP transport peer.

### REGISTER response Contact compatibility

On 2026-10-17, the browser HAR showed a normal Digest challenge followed by an
authenticated REGISTER that received `200 OK`; those 401/200 exchanges do not
indicate bad credentials. The Kamailio WSS request route rewrites each incoming
browser Contact to the receiving StatefulSet owner's TLS hostname and preserves
the `alias` used to return traffic to that WebSocket. The response route had
then rewritten every owner hostname in Asterisk's successful Contact list to
the literal `.invalid` host. For the current binding this changed
`sip:[USER]@<browser-host>.invalid;transport=ws` into
`sip:[USER]@.invalid;transport=ws;alias=...`.

The latter is not a valid SIP URI: its host begins with an empty DNS label.
In JsSIP 3.10.6, `Parser.parseMessage()` parses every Contact header before the
response reaches the transaction/registrator; a parse failure returns no SIP
message, so the UA drops the response without emitting `registered` from this
200. The REGISTER client transaction then times out; the registrator maps
that timeout to `registrationFailed` with `REQUEST_TIMEOUT`. If Contact
parsing succeeds, the registrator first
matches `+sip.instance` with `reg-id`, then falls back to the Contact URI user.
The HAR's response omitted instance and reg-id, so a valid Contact with the
same user would match by that fallback even though its host is the internal
owner hostname. Thus the accepted server-side registration does not prove the
browser recognized it; for the shown `@.invalid` Contact, JsSIP 3.10.6's
parser path establishes that it ignores the response rather than rejecting
the credentials. The HAR has no frontend event or parser-console record, so
the predicted event behavior still needs a browser-side reproduction. The
narrow fix is to leave the Asterisk response Contacts unchanged. Asterisk's
valid owner Contact URI (including each binding's own owner and alias) is
returned, while the browser continues to use its own WSS Contact for requests;
the response Contact is not used as the browser's transport destination.

For the HAR's exact registration Call-ID, live `pjsip show contact` showed
Asterisk storing `sip:[USER]@OWNER1:5063;transport=tls;alias=172.20.57.165~59600~5`
with Path to OWNER1 and received flow `172.20.57.165:59600;transport=ws`.
That binding was Available. This binding-specific state does not match the
OWNER2 Path shown in the HAR's response, so the single response Path must not
be used to infer that this binding was stored with OWNER2. The HAR cannot
identify which other contact's Path was represented there. The eight returned
contacts remain intact; their identities, expiry/qualification and owner
relationships must be assessed per Asterisk contact rather than collapsed
into the current browser flow.

The INVITE to `[TEST-A]` was authenticated and answered; the browser sent
an ACK, later received BYE with Q.850 cause 16, and returned `200 OK`. Cause 16
means normal clearing and does not identify who initiated the short call.
This signaling sample does not prove media completion or explain the
2.585-second duration. The HAR establishes what the browser sent/received, not
backend receipt of its ACK/BYE response or the client-side
`registered`/`registrationFailed`/`unregistered` events. Those require
frontend event telemetry plus correlated internal SIP logs/HEP.

### Latest outbound-call sample

### Live outbound and remote-hangup verification (2026-10-18)

An operator-initiated YVR outbound call was observed through the internal
FreeSWITCH callback route and the Flowroute TLS leg. FreeSWITCH selected the
authorized NANP route, offered the configured PCMU/PCMA codec policy, and the
carrier returned `183 Session Progress` followed by `200 OK`; ACKs were
relayed through the owning Kamailio instance. After approximately two minutes,
the remote side sent BYE. Kamailio accepted it, deleted the RTPEngine media
session successfully, relayed the BYE to the internal side, and received
`200 OK`. FreeSWITCH closed both legs with `NORMAL_CLEARING`, and Home
Assistant disconnected at the same time. This verifies carrier-leg teardown
propagation for this call without exposing the destination or call identity.

This sample verifies signaling and media-session cleanup. It does not replace
the separate RTP packet and codec evidence required for the complete voice
baseline, and it does not enable the opt-in outbound service-peer pilot.

The browser HAR for a Call-ID shows a successful
authenticated outbound call to `[EXTERNAL-DESTINATION]`. The initial INVITE
received the expected Digest challenge; the authenticated retry received 100
Trying, 183 Session Progress with SDP, then 200 OK with SDP. The 183 and final
answer expose the same public media address, audio port, ICE ufrag, and DTLS
fingerprint. The browser sent ACK, refreshed the session with UPDATE about 45
seconds after answer (200 OK in about 11 ms), then sent BYE after about 73
seconds. The matching browser-facing 200 OK arrived about 1.313 seconds after
the BYE. OPTIONS qualification continued afterward. No INVITE 200 or BYE
retransmission is visible for this sample.

The operator reports that local hangup disconnected the external party. The
HAR independently establishes successful browser signaling and the
browser-facing BYE response, but does not show the backend or carrier dialogs;
it is not packet-level proof that the carrier leg received teardown or that
media resources were released. The response interval is measured end-to-end
at the browser and cannot locate the delay. Correlate backend and carrier
events, independent-leg session refresh, and media cleanup before making those
claims. This successful call does not resolve the separate malformed REGISTER
Contact captures or the earlier same-dialog 200 OK responses with divergent
public/private SDP and DTLS identities.

For the earlier divergent-response capture, both final responses have the
same Call-ID and dialog tags but different SDP, ICE credentials, and DTLS
fingerprints; the second exposes a private backend address and lacks the
correlation header. These are not identical retransmissions. In the deployed
client version, JsSIP's [`RTCSession._receiveInviteResponse()`]
(https://github.com/versatica/JsSIP/blob/3.10.6/lib/RTCSession.js) detects an
already-established dialog with the same Call-ID and tags, sends ACK, and
returns before applying the later response's SDP. This matches the two ACKs
in the HAR and means that the HAR alone does not show the second SDP being
applied. Kamailio's rendered WSS reply callback is attached to the transaction
and invokes RTPEngine for SDP responses, but no internal trace is available to
show whether both responses traversed that callback, what RTPEngine returned,
or where the unanchored body and missing correlation header arose. Do not
attribute this defect to a specific proxy or alter RTPEngine behavior until
those boundaries are correlated.

Regression status: the existing WSS render check and Helm lint pass, including
the check that the broad REGISTER response Contact rewrite is absent. They do
not exercise repeated INVITE 200 responses or live registration events. The
browser HAR supplies one successful refresh/hangup example; internal ACK/BYE
receipt, carrier-leg teardown, and frontend registration events still need
correlated evidence. PostgreSQL voicemail and its persistence path were not
changed by the Contact fix and were not re-tested by this signaling sample.

PJSIP packet logging is suppressed while SIP Core is enabled because raw SIP
traces can include Digest Authorization headers. Kamailio's raw receive logs,
full carrier packet logs, and Homer SIP trace are also disabled while this
feature is enabled. The internal Kamailio instance emits concise `SIPCORE FLOW`
markers for WebSocket requests, Asterisk return requests, and SIP responses.
These include Call-ID, method/status, socket peer, extension user/target, and
CSeq, without SIP bodies or authorization headers. SDP diagnostics remain a
separate setting and can include endpoint addresses and codec details.
The WSS instance also logs parse-error metadata and `SIPCORE WS-CLOSED`
records (peer address and local connection ID), without recording the bad
buffer or close payload. The current YVR route/policy limits are 0s at the
HTTPRoute, 1h stream idle at the route policy, 300s Gateway backend idle,
1800s client idle, and 3600s maximum duration; Kamailio sends WebSocket Ping
frames every 15s. The Home1 heartbeat compatibility override addresses the
previously observed repeatable 30s disconnect. If it recurs, check the close
event and client-side reconnect logs before changing a timeout.

### Home Assistant LF-only heartbeat compatibility

The deployed SIP Core client sends the two-byte WebSocket text payload `0A 0A`
(`\n\n`) every 30 seconds after registration. Kamailio 6.1.4 normally passes
that payload to its SIP parser, which rejects it and can close the connection.
The compatibility patch handles this exact payload inside the WebSocket
module after frame decoding and fragment reassembly, only when the negotiated
subprotocol is `sip`. It consumes the message locally and replies on the same
connection with the standard single-CRLF application-data keepalive. It does
not relax SIP parsing or change REGISTER, Digest authentication, Asterisk
contact ownership, SIP Path, dialog routing, or media handling. Standard
CRLF keepalives and WebSocket Ping/Pong remain handled by Kamailio's normal
code.

The chart option defaults off. Enabling it requires the immutable, patched
Kamailio image built from the exact 6.1.4 source and matching module
parameter; do not enable the parameter with the stock image. The source patch,
Containerfile, minimal SIP test configuration and black-box regression client
are under `AVoIP/image/kamailio-lf-heartbeat/`. The root
[Forgejo workflow](../../.forgejo/workflows/kamailio-lf-heartbeat.yaml) follows
the tested Buildx and registry pattern from
[Core-Docker's image workflow](https://github.com/K-FOSS/Core-Docker/blob/main/.forgejo/workflows/Daily.yaml):
it tests and publishes an immutable amd64 image on `main` and records its
digest. The Home1 override is enabled on all three `internal-websocket`
replicas with the published image pinned by tag and digest in the owning
[CoRE-Backplane AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The deployed image is
`slop.writemy.codes/core/core-business/kamailio-lf-heartbeat:6.1.4-lf-heartbeat-5264324a63deaa38db2d0bba0d973d8296683899@sha256:5eb5f47706f13edd4a9db90b1670c12c2354476d7eff8c08e748876cadec3545`.
The ordinary `internal` private-SBC and carrier instances keep their existing
image.

The Home1 ApplicationSet's complete `kamailio.instances` list (the list
replaces rather than appends) carries this override under its existing
`internal-websocket` entry:

```yaml
websocketHA:
  compatibility:
    lfOnlyHeartbeat:
      enabled: true
      image:
        repository: <published-registry>/kamailio-lf-heartbeat
        tag: <immutable-build-tag>
        digest: sha256:<published-image-digest>
```

The values above describe the current Home1 deployment; do not copy placeholder
coordinates into a deployment. Build and run the image regression workflow,
then use that run's immutable tag and digest and render the complete owning
ApplicationSet values before enabling the option at another site.

The current YVR logs also report TOPOS storage errors and OPTIONS relay
failures. Those are independent problems and are not addressed by this
heartbeat compatibility change.

Stock Asterisk's PJSIP WebSocket transport does not retain the HTTP upgrade's
forwarded headers as SIP metadata. This design does not pass XFF to Kamailio or
Asterisk as an identity signal and does not replace either socket peer address.
Client-IP attribution must currently happen in Envoy access logs. Envoy must
accept forwarded addresses only from explicitly trusted upstream proxy hops,
strip or overwrite browser-supplied values at the public boundary, and apply a
documented single-hop or trusted-chain policy. Missing, malformed, duplicated,
or multi-hop values are unverified. Preserve Envoy's raw peer separately and
never log SIP Authorization values or passwords. A future narrowly scoped
ingress extension could parse one unambiguous IPv4 or IPv6 address only after
checking that the socket peer is a configured trusted proxy; it would retain
the result as log metadata only. It must not rewrite Via, Contact, routing,
authentication, or the PJSIP transport peer. This change adds no such proxy or
Asterisk module.

`asterisk.sipCore.allowedOrigins` remains configurable and the chart's Kamailio
WebSocket handshake checks require exactly one `Host` and one `Origin`, then
compare them to the configured SIP Core hostname and allowed origin list.
This does not establish trust in XFF. Any policy change on the shared Envoy Gateway belongs in
[CoRE-Backplane's Gateway configuration](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Operations),
which is outside this task's scope. RTPEngine media handling is separate from
WebSocket signaling: Kamailio sends SDP control to the existing RTPEngine and
the browser's ICE/DTLS-SRTP media is relayed through it. CoTURN/NATPuncher is a
separate media service. Asterisk's RTP ICE configuration uses the existing
CoTURN service for STUN discovery and TURN relay candidates; it does not change
the Kamailio signaling path or replace RTPEngine.

FreeSWITCH peer identification does not use source IP. The Asterisk endpoint is
selected by its fixed SIP `From` username. A 64-character random hexadecimal
password is generated by the
[External Secrets Password generator](https://external-secrets.io/latest/api/generator/password/)
and stored in an immutable, retained Kubernetes Secret by an
[ExternalSecret](https://external-secrets.io/latest/api/externalsecret/).
Both sides read the same password through Secret references. The initial
request selects endpoint `freeswitch`; Asterisk then challenges and validates
the SIP Digest response. The existing Asterisk `outbound_auth` remains for
Asterisk-originated requests, and the new inbound `auth` object protects
requests from FreeSWITCH. No pod IP or cluster CIDR is treated as peer
identity. Raw PJSIP and FreeSWITCH Sofia packet traces are disabled for this
authenticated path to avoid logging Authorization headers. The Secret is
retained and immutable; audit it before removing the resources or rotating the
credential. This change does not alter FreeSWITCH carrier or fax dialplan
behavior.

## Chart support

`asterisk.sipCore.enabled` defaults to `false`. When enabled, the chart:

- Adds a WebSocket listener and SIP Core route only to the selected private
  Kamailio instance. In the separated HA configuration this is `internal-wss`;
  `internal` remains the ordinary private-SBC, and the carrier has no SIP Core
  listener or route. The WSS edge relays SIP to Asterisk over TLS and controls the
  existing RTPEngine for the Home Assistant media leg. WebRTC
  endpoint/AOR/auth objects are generated for each configured extension.
- Keeps the Asterisk endpoint on TLS to Kamailio. Asterisk must not send SIP
  directly to the browser's `transport=ws` Contact because Kamailio owns that
  WebSocket connection. The chart stores a Kamailio Contact alias on REGISTER,
  gives Asterisk a dedicated private TLS return port (default `5063`), and
  routes calls from Asterisk back over the existing WebSocket flow. Its TLS
  return Service has its own internal DNS name and certificate SAN so Kamailio
  can select a port-specific TLS profile by SNI. That profile does not request
  a client certificate: the ACME certificate used by Asterisk is its server
  identity, while a Cilium pod-identity policy restricts port `5063` to this
  release's Asterisk workload. The private peer listener on `5062` continues
  to require strict mutual TLS. Record-Route uses the internal Kamailio TLS
  return Service because Asterisk cannot route dialogs over browser WSS.
  RTPEngine relays the reverse media offer and answer too. Asterisk-originated
  requests are accepted only when their Request-URI resolves through a current
  Kamailio WebSocket Contact alias. These Contact URIs use random client values,
  so Kamailio cannot compare their user part with the extension number; the
  dedicated listener's Cilium workload policy is the trust boundary. Calls
  initiated by a Home Assistant extension remain constrained by that
  extension's Asterisk `allowCallsTo` dialplan context.
- When `websocketHA.enabled` is set on the separate `internal-wss` instance,
  the chart renders that edge as a StatefulSet and adds its own headless
  owner-address Service. At cutover the generated HTTPRoute backend changes
  from the old `internal` Service to the WSS Service on port 8088. A per-owner
  Path is generated for REGISTER and stored by Asterisk
  `support_path=yes`; the browser's socket and Kamailio transaction remain
  process-local. Asterisk remains the registrar, contact database and Digest
  authority. Missing/dead Path owners fail safely and require client
  reconnection plus authenticated re-registration.
- Reads each extension's random SIP password from an ExternalSecret sourced
  from the configured CoreVault-backed SecretStore. At startup, it writes a
  private, temporary PJSIP include; the password is never rendered into Git or
  a ConfigMap. Use at least 32 hexadecimal characters.
- Adds a public HTTPRoute for only `/ws` on the existing Gateway HTTPS listener.
- Disables the route request and backend request-duration caps for WSS while
  retaining a configurable one-hour default stream-idle limit. The separately
  owned Backplane Gateway policy still has a one-hour maximum connection
  duration; it must be reviewed separately for longer-lived WebSockets.
  It forwards the WebSocket to the selected private Kamailio Service on port
  8088. A route-scoped Envoy Gateway
  [BackendTrafficPolicy](https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/backend-traffic-policy/)
  sets the WebSocket stream idle timeout from
  `asterisk.sipCore.backendTrafficPolicy.streamIdleTimeout` (default `1h`);
  HA Kamailio uses 15-second server Pong keepalives; this avoids treating a
  missing client Pong as a dead connection. The ordinary private-SBC
  compatibility path retains Ping keepalives. The
  private policy admits the Envoy data-plane on that port and the
  Asterisk workload on the TLS return port. No public Asterisk SIP or AMI
  listener is added.
- Places every SIP Core extension in its own dialplan context. `allowCallsTo`
  lists exact local extension numbers and may include the configured echo
  extension for a loopback audio check. The configured `ggAudioExtension`
  (default `66`) remains an Asterisk entry point that transfers the SIP user
  `gg-audio` to the authenticated FreeSWITCH peer on its dedicated TLS port
  `5064`. This listener is separate from the Kamailio-facing FreeSWITCH TLS
  listener on `5061`, which uses the public context. The Asterisk profile
  uses TLS on a dedicated internal port and requires SIP Digest. The
  currently selected public ACME issuer returns a server-auth-only certificate,
  so FreeSWITCH does not request it as a client certificate. Asterisk still
  verifies FreeSWITCH's TLS server certificate, and FreeSWITCH's `auth-calls`
  setting validates the peer's Digest credentials before entering
  `from-asterisk`. A future mTLS configuration needs a separate client
  certificate issued by an approved internal CA and trusted by FreeSWITCH. The
  destination is configurable with `asterisk.sipCore.ggAudioDestination`.
  The reserved `asterisk.sipCore.helloCallbackExtension`
  plays Asterisk's `hello-world` prompt, hangs up the incoming leg, and runs a
  hangup handler that asynchronously calls back the authenticated SIP Core
  source extension's registered contacts. If a device answers, Asterisk sends the
  call into the existing `ggAudioExtension` route so
  FreeSWITCH plays the GG audio. This service extension is not a SIP account
  and has no password; the callback target comes from the authenticated
  extension's dedicated dialplan context, not caller-supplied Caller ID. The
  callback rings with the configured display name
  `asterisk.sipCore.ggCallbackCallerIdName` (default `Important Message`).
  The callback greeting logs the Asterisk unique ID and audio formats before
  and after playback; the GG route logs its FreeSWITCH media and RTP counters.
  Kamailio aliases the WebSocket Contact in the callback response so Asterisk's
  later ACK and BYE reuse the active WebSocket flow.
  The callback uses `PJSIP_DIAL_CONTACTS()` to ring all current AOR contacts
  in parallel, matching the inbound DID fan-out. Its destination is derived
  from the authenticated extension's private dialplan context, not
  caller-supplied Caller ID. Kamailio routes each explicit contact URI only
  through its owning WebSocket pod; Asterisk cancels the other attempts when
  one contact answers. Asterisk starts the callback independently of the ended source
  channel, then enters the GG route and dials FreeSWITCH only after a contact
  answers. If no contact answers
  within the configured `asterisk.sipCore.ggCallbackRingTimeoutSeconds`
  (default 30 seconds), it ends without starting the GG call. The callback
  starts one minute after the hello-world call ends by default, controlled by
  `asterisk.sipCore.ggCallbackDelaySeconds`.
  A later inbound capture showed the fan-out reached the registered owner
  pods, but each branch was rejected with `404 SIP Contact Owner Path Missing`
  before WebSocket forwarding. The return-route guard treated the explicit
  per-contact INVITE URI as invalid whenever its Path Route was absent or
  unusable, even though the Request-URI already named that contact's owner.
  HA routing now allows this fallback only for an initial INVITE on the
  Asterisk-restricted TLS listener whose Request-URI hostname exactly matches
  the receiving owner pod; Kamailio must still resolve the local Contact
  alias. Other methods, wrong-owner targets and unresolvable aliases remain
  rejected. A live inbound test confirmed three registered contacts rang and
  answering on one cancelled the other attempts. The callback uses the same
  fan-out behavior.
  Separately, the public FreeSWITCH IVR callback is controlled by
  `asterisk.sipCore.externalCallback.enabled` and is disabled by default. When
  enabled, it returns the caller identity over the authenticated
  FreeSWITCH-to-Asterisk leg. Asterisk accepts an exact configured internal
  account identity or a number already in full `+1` plus ten digit form. It
  passes that value unchanged to Asterisk's `carrier-outbound` endpoint, where
  Admin's dynamic provider policy selects the authorized provider and caller
  ID. FreeSWITCH does not select a static provider route or normalize numbers.
  Carrier-side ANI validation remains an operational trust assumption for the
  inbound identity. The feature is enabled only in YVR site values. If the
  received identity exactly matches a configured SIP Core account, the
  callback instead rings that account's registered contacts in parallel.
  The `gg-audio` route emits correlated start, media-established, and playback
  completion logs with codec and outbound RTP packet/byte counters. It sends a
  configurable 100 ms `silence_stream` RTP lead-in before the remote audio by
  default, to test whether media startup is discarding the first audio frames.
  Set `asterisk.sipCore.callbackAudioDiagnostics.rtpLeadInMs: 0` for a
  no-lead-in comparison. The lead-in affects only this test audio route and
  does not record call audio.
  With the HA WSS instance selected, Asterisk must use the Path stored with
  each PJSIP contact. The endpoint therefore has no `outbound_proxy`: a fixed
  endpoint proxy overrides the per-contact owner Path. Asterisk logs from the
  YVR investigation showed the previous loopback sink proxy caused callback
  INVITEs to fail locally with 503 before reaching Kamailio. The chart now
  leaves this proxy unset for HA while Kamailio rejects REGISTER without a
  valid owner Path. Existing contacts created by the legacy path should
  re-register through the HA endpoint before calls or callbacks can reach them.
  FreeSWITCH matches `gg-audio` in the dedicated `from-asterisk` context and
  plays the configured GG audio. Its dedicated Asterisk
  profile requires SIP Digest and selects `from-asterisk`; the private-network
  ACL does not bypass authentication. The peer password is mounted from its
  Secret into both SIP processes. Add site-specific destinations and scripts
  to the `asterisk.xml` dialplan in
  [FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
  The `from-asterisk` context has no catch-all or PSTN route; only the explicit
  `gg-audio` route is included by default.

The FreeSWITCH-to-Asterisk TLS peer offers Opus first, then G.722, with PCMU
fallback; Asterisk's FreeSWITCH endpoint allows all three. SIP Core endpoints
also allow Opus, G.722, PCMU, and PCMA. A codec is selected only when the other
endpoint offers it, so existing narrowband peers continue to negotiate G.711.
This can preserve higher-quality audio on capable internal calls, but it cannot
add detail to a carrier call received at lower quality. See Asterisk's
[codec support](https://docs.asterisk.org/Operation/Asterisk-Audio-and-Video-Capabilities/)
and FreeSWITCH's [codec negotiation](https://developer.signalwire.com/freeswitch/media-and-codecs/codecs/).

The chart does not enable this feature at a site. Set
`asterisk.sipCore.kamailioInstance` to the name of the dedicated WSS
`private-sbc` instance (planned name `internal-wss`). Keep both private
instances' site-specific TOPOS settings isolated from one another and from
the carrier store. Set the hostname to a name
covered by the selected Gateway HTTPS listener and configure ExternalDNS and
the Gateway's certificate/DNS ownership through the site's established
Backplane path. A hostname under an existing wildcard listener is usually the
simplest choice. Do not reuse `sip.resolvemy.host`, which remains the carrier
SIPS name.

Example site values for one Home Assistant user (replace the example extension,
hostname, and Vault path with the site's selected values):

```yaml
asterisk:
  sipCore:
    enabled: true
    hostname: 'sipcore.mylogin.space'
    gatewaySectionName: 'https-myloginspace'
    allowedOrigins: ['https://ha.mylogin.space']
    ggAudioExtension: '66'
    extensions:
      - number: '7101'
        secret:
          remoteKey: 'AVoIP/SIPCore/YVR/Home1/7101'
          property: 'Password'
        allowCallsTo: ['9090']
```

Create the remote Vault property with a unique random hexadecimal password; do
not put it in ApplicationSet values. The rendered `ExternalSecret` syncs the
externally managed password to a namespace-local Secret with key `password`.
The chart fails rendering for
missing password references, invalid or duplicate extension numbers, and
destinations that are not configured extensions or reserved test extensions.
A SIP Core caller can dial `9090` for the echo test or the configured
`ggAudioExtension` (default `66`) to transfer to the configurable SIP user
`ggAudioDestination` (default `gg-audio`) on FreeSWITCH. Other transfer
destinations can be added to the FreeSWITCH `asterisk.xml` dialplan. A
changed password triggers an Asterisk restart so PJSIP auth and endpoint state
are regenerated together.

Install SIP Core through HACS using the upstream repository, restart Home
Assistant, then add/configure SIP Core under Settings → Devices & Services.
In its `users` options, map the exact Home Assistant username to the configured
extension and enter that extension's password from CoreVault. Set
`pbx_server` to the configured hostname and `custom_wss_url` to
`wss://<hostname>/ws`. Keep the password in the Home Assistant integration's
protected options and distribute it only to the authorized account owner. Do
not put it in Lovelace YAML, URLs, automations, or logs. The Contacts/Call
card's extension map is presentation/call-target configuration; it does not
create a PBX account. Each target must also exist as an Asterisk endpoint and
be allowed by the caller's `allowCallsTo` list.

The optional SIP Core Asterisk Integration is a different component: it
connects to AMI on port 5038. This chart keeps AMI internal and does not expose
it, so skip that optional component unless a separately reviewed private AMI
access path is established.

## Media reachability

WebRTC media is DTLS-SRTP over ICE and UDP; the HTTPRoute carries signaling
only. Kamailio sends SDP control to the existing RTPEngine, and RTPEngine
relays the browser media leg using its configured public media interface and
UDP range. Keep `asterisk.sipCore.media.enabled` disabled: the chart rejects
direct Asterisk RTP exposure while SIP Core is enabled. This change reuses the
existing RTPEngine deployment and does not create another media topology.
The chart now enables Asterisk-side CoTURN credentials for sites with SIP Core
enabled and pins the image digest supplied for the new build. The runtime image
includes the `openssl` CLI required by its startup HMAC generator. Asterisk
mounts Social/Matrix's existing `matrix-turn-auth` Secret and derives a
time-limited credential in the container's private `/tmp`, never in Helm
values or a ConfigMap. The TURN hostname defaults to the site-local NATPuncher
endpoint, with an explicit override available. Verify that
`ExternalSecret/matrix-turn-auth` is Ready in the target namespace before
reconciliation; that live check is not available from this workspace.
STUN/TURN settings here apply only to Asterisk's media ICE agent.

This does not provide TURN credentials to Home Assistant or alter the existing
Kamailio→RTPEngine media path. The Home Assistant SIP endpoint continues to
use RTPEngine for browser media. Asterisk-side CoTURN does not provide TURN
credentials to Home Assistant or alter the browser's existing media path. If two-way
audio still fails, inspect negotiated ICE candidates on both legs and
RTPEngine's available relay ports. Registration alone does not prove media
works.

## Verified pilot

On 2026-10-08, extension `7101` registered successfully with Asterisk using
SIP Digest authentication. A Home Assistant-originated call to the configured
echo destination `9090` reached the Asterisk echo extension, as confirmed by
the operator. This verifies the registration, signaling, and echo-destination
path. Bidirectional audio through RTPEngine was not separately captured as
part of this verification.

On 2026-10-10, the patched image was enabled on Home1's separate
`internal-websocket` StatefulSet through the owning ApplicationSet. The
published Home1 deployment commit is
[`f8abd3e53869e6779d8fb023b60104a0720a6102`](https://slop.writemy.codes/CoRE/CoRE-Backplane/commit/f8abd3e53869e6779d8fb023b60104a0720a6102).
Argo CD reported the Home1 AVoIP application Synced and Healthy. All three
StatefulSet pods were Ready on image digest
`sha256:5eb5f47706f13edd4a9db90b1670c12c2354476d7eff8c08e748876cadec3545`,
and the live Kamailio configuration had
`lf_keepalive_compat=1`. The operator confirmed the SIP Core extension rang
and played the test audio. The operator also reports that the Home Assistant
registration and WebSocket now remain connected over time, resolving the prior
short disconnect behavior. This is live signaling and client confirmation;
it does not by itself verify bidirectional RTP, fax, or behavior beyond the
Gateway's configured 3600-second maximum connection duration.

## Rollback and verification

Rollback by setting `asterisk.sipCore.enabled: false`. This removes the WSS
route, internal Kamailio listener and port-specific TLS policy, endpoint
configuration, and ExternalSecret resources;
ExternalSecret targets use `deletionPolicy: Retain`, so explicitly audit the
retained Kubernetes Secrets and Vault values before deleting them. The carrier
SBC remains responsible for carrier and FreeSWITCH fax signaling. After a rollout, verify the route is
Accepted, Kamailio loaded `websocket.so` and `rtpengine.so`, `pjsip show
transports` lists `transport-tls`, `pjsip show contacts` lists the registered
extension, and Asterisk reports the contact reachable through Kamailio. The
Kamailio service exposes the private return port only to the Asterisk-selected
workload policy rule. Then test an Asterisk-originated call to the extension,
the SIP Core echo target, and confirm the selected ICE pair and bidirectional
audio from an external browser network.

After rollout, verify `ExternalSecret/matrix-turn-auth` is Ready without
printing Secret contents, then inspect Asterisk ICE/TURN candidate creation
with PJSIP packet tracing disabled. Never copy the generated TURN password or
SIP Authorization data into logs or support output. The Secret remains owned
by Social/Matrix.

This static extension pilot is separate from the planned dynamic SIP registrar,
Authentik credential broker, and first-party webphone. It does not satisfy the
OIDC identity, short-lived credential, TURN credential, device revocation, or
cross-proxy reconnection requirements in [TODO.md](../TODO.md).
