# Home Assistant SIP Core with static Asterisk extensions

The current Home1 Envoy Gateway resources, TLS termination, Host/Origin
contract, timeout layers, and ApplicationSet's explicit one-replica override
are recorded in the [SIP HA gateway baseline](SIP-STATEFUL-HA.md#sip-core-wss-integration-baseline-observed-2026-10-08).
The generated HTTPRoute is owned by this chart and currently targets the
internal Kamailio Service on port 8088. Increasing replicas alone is unsafe:
the shared Envoy Service balances new connections but cannot route later SIP
requests to the Kamailio process that owns a registered WebSocket.
The chart's opt-in `websocketHA` mode runs in a separate named
`internal-wss` Kamailio instance, apart from the ordinary `internal`
private-SBC. It supplies stable StatefulSet owner DNS, Path routing and
Asterisk return routing; the Home1 ApplicationSet remains unchanged until its
separately reviewed staged cutover. See
[SIP Stateful HA](SIP-STATEFUL-HA.md#implemented-wss-edge-mode) for the
observed Envoy resources, exact future values and operator acceptance steps.

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

PJSIP endpoint selection uses the SIP username before source-IP matching. For
extension `7101`, the generated endpoint accepts the `username` and
`auth_username` identifiers, and its Digest `auth` object still validates the
password. Selecting endpoint `7101` does not authenticate the request. The
endpoint keeps its private `from-sipcore-7101` context and exact
`allowCallsTo` destinations, including `9090` when configured. A spoofed
`X-Forwarded-For` value cannot select the endpoint, authenticate SIP, or change
the actual PJSIP transport peer.
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
frames every 15s. These values do not explain a repeatable 30s disconnect.
Check the close event and client-side reconnect logs before changing a timeout.

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
  The reserved `asterisk.sipCore.helloCallbackExtension` (default `1234`)
  plays Asterisk's `hello-world` prompt, hangs up the incoming leg, and runs a
  hangup handler that asynchronously calls the same configured SIP Core
  extension's registered PJSIP AOR. If that device answers, Asterisk sends the
  call into the existing `ggAudioExtension` route (default `66`) so
  FreeSWITCH plays the GG audio. This service extension is not a SIP account
  and has no password; the callback target comes from the authenticated
  extension's dedicated dialplan context, not caller-supplied Caller ID. The
  callback rings with the configured display name
  `asterisk.sipCore.ggCallbackCallerIdName` (default `Important Message`).
  Kamailio aliases the WebSocket Contact in the callback response so Asterisk's
  later ACK and BYE reuse the active WebSocket flow.
  The callback uses Asterisk's `PJSIP_DIAL_CONTACTS()` to ring all currently
  registered contacts for that extension in parallel. Asterisk starts the
  callback independently of the ended source channel, then enters the GG route
  and dials FreeSWITCH only after a contact answers. If no contacts answer
  within the configured `asterisk.sipCore.ggCallbackRingTimeoutSeconds`
  (default 30 seconds), it ends without starting the GG call. The callback
  starts one minute after the hello-world call ends by default, controlled by
  `asterisk.sipCore.ggCallbackDelaySeconds`.
  FreeSWITCH matches `gg-audio` in the dedicated `from-asterisk` context and
  plays the configured GG audio. Its dedicated Asterisk
  profile requires SIP Digest and selects `from-asterisk`; the private-network
  ACL does not bypass authentication. The peer password is mounted from its
  Secret into both SIP processes. Add site-specific destinations and scripts
  to the `asterisk.xml` dialplan in
  [FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
  The `from-asterisk` context has no catch-all or PSTN route; only the explicit
  `gg-audio` route is included by default.

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
The optional Asterisk-side CoTURN credential integration is disabled by
default because its startup generator requires `openssl` in the Asterisk
container image. The current image does not provide that capability. When the
image is updated and verified, it can be enabled with
`asterisk.turn.enabled: true`; it mounts Social/Matrix's existing
`matrix-turn-auth` Secret and generates a time-limited credential in the
container's private `/tmp`, never in Helm values or a ConfigMap. STUN/TURN
settings here apply only to Asterisk's media ICE agent.

This does not provide TURN credentials to Home Assistant or alter the existing
Kamailio→RTPEngine media path. The Home Assistant SIP endpoint continues to
use RTPEngine for browser media. Re-enabling Asterisk-side CoTURN is optional
and must wait for an image with the required `openssl` support. If two-way
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

When Asterisk-side TURN is explicitly enabled after the image update, verify
`ExternalSecret/matrix-turn-auth` is Ready without printing Secret contents,
then inspect Asterisk ICE/TURN candidate creation with PJSIP packet tracing
disabled. Never copy the generated TURN password or SIP Authorization data
into logs or support output. The Secret remains owned by Social/Matrix.

This static extension pilot is separate from the planned dynamic SIP registrar,
Authentik credential broker, and first-party webphone. It does not satisfy the
OIDC identity, short-lived credential, TURN credential, device revocation, or
cross-proxy reconnection requirements in [TODO.md](../TODO.md).
