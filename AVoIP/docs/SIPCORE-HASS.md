# Home Assistant SIP Core with static Asterisk extensions

The [SIP Core Home Assistant integration](https://github.com/TECH7Fox/sipcore-hass-integration)
is a browser WebRTC SIP client. It connects to Asterisk over WSS and registers
one or more configured SIP users. Its separate optional Asterisk integration
uses AMI; this AVoIP setup does not expose AMI. Follow the upstream
[SIP Core setup](https://tech7fox.github.io/sip-hass-docs/docs/tutorial/card),
[SIP Core settings](https://tech7fox.github.io/sip-hass-docs/docs/card/settings),
and Asterisk's [WebRTC/PJSIP guide](https://docs.asterisk.org/Configuration/WebRTC/Configuring-Asterisk-for-WebRTC-Clients/).

## Chart support

`asterisk.sipCore.enabled` defaults to `false`. When enabled, the chart:

- Adds an Asterisk WebSocket PJSIP transport and WebRTC endpoint/AOR/auth
  objects for each configured extension. WSS terminates at Envoy Gateway; the
  cluster hop uses plain WebSocket on the private Asterisk Service.
- Reads each extension's random SIP password from an ExternalSecret sourced
  from the configured CoreVault-backed SecretStore. At startup, it writes a
  private, temporary PJSIP include; the password is never rendered into Git or
  a ConfigMap. Use at least 32 hexadecimal characters.
- Adds a public HTTPRoute for only `/ws` on the existing Gateway HTTPS listener.
  The route terminates browser TLS at Envoy Gateway and forwards the WebSocket
  to Asterisk's internal HTTP listener on port 8088. No SIP or AMI public
  listener is added.
- Places every SIP Core extension in its own dialplan context. `allowCallsTo`
  lists exact local extension numbers and may include the configured echo
  extension for a loopback audio check. No wildcard or PSTN route is created.

The chart does not enable this feature at a site. Set the hostname to a name
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
    extensions:
      - number: '7101'
        secret:
          remoteKey: 'AVoIP/SIPCore/YVR/Home1/7101'
          property: 'Password'
        allowCallsTo: ['9090']
```

Create the remote Vault property with a unique random hexadecimal password; do
not put it in ApplicationSet values. The rendered `ExternalSecret` syncs it to a
namespace-local Secret with key `password`. The chart fails rendering for
missing password references, invalid or duplicate extension numbers, and
destinations that are not configured extensions or the echo extension. A
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

WSS signaling uses the Gateway. WebRTC media is DTLS-SRTP over ICE and UDP; an
HTTPRoute cannot forward RTP. The chart therefore leaves public RTP exposure
disabled. For external browser audio, set
`asterisk.sipCore.media.enabled: true`, provide the public media IP in
`asterisk.sipCore.media.address`, and configure
`serviceOptions.asterisk-rtp` with the site's existing LoadBalancer class,
provider annotations, and public Service labels (including `wan-mode: 'public'`).
For example, Home1 values need the site's kube-vip class/forwarding metadata;
YXL needs its PureLB address/group metadata. This creates a separate UDP
LoadBalancer Service for
`asterisk.rtp.min` through `asterisk.rtp.max` inclusive, with
`externalTrafficPolicy: Cluster`, targeting the Asterisk pod. It does not
change RTPEngine or the carrier/media routes. Do not enable it until the site
operator has assigned the address and confirmed the provider forwards the full
UDP range to service endpoints.

The endpoint uses PJSIP's `media_address` setting, available in Asterisk 20.7
and later. Confirm the deployed Asterisk image version before enabling public
media; this static pilot has not been validated against the live image.

The integration's `ice_config` can include TURN servers, but do not configure
the shared NATPuncher REST signing secret in Home Assistant. Short-lived
browser TURN credentials for this SIP consumer still need a dedicated issuance
path. Until either a verified direct UDP path or scoped TURN credentials are
available, WSS registration may work while external two-way audio does not.
Test from outside the cluster, inspect the selected ICE candidate pair, and
confirm bidirectional RTP and DTLS-SRTP before calling the feature live.

## Rollback and verification

Rollback by setting `asterisk.sipCore.enabled: false` and removing the
site-specific `asterisk-rtp` service configuration if it was enabled. This
removes the WSS route, endpoint configuration, and ExternalSecret resources;
ExternalSecret targets use `deletionPolicy: Retain`, so explicitly audit the
retained Kubernetes Secrets and Vault values before deleting them. Existing
carrier SIP and fax routing are unchanged. After a rollout, verify the route is
Accepted, `http show status` reports the Asterisk HTTP listener, `pjsip show
transports` lists `transport-ws`, and `pjsip show contacts` lists the
registered extension. Then test the echo target and a two-way call from an
external browser network.

This static extension pilot is separate from the planned dynamic SIP registrar,
Authentik credential broker, and first-party webphone. It does not satisfy the
OIDC identity, short-lived credential, TURN credential, device revocation, or
cross-proxy reconnection requirements in [TODO.md](../TODO.md).
