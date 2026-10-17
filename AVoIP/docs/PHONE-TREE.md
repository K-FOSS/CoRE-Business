# AVoIP phone tree and DID service

The AVoIP voice configuration is intentionally minimal. It does not ship the
upstream FreeSWITCH demonstration dialplan, sample extensions, conference
codes, parking codes, fax tests, or demo IVR. An optional Asterisk voicemail
route is available for the configured direct extension; it remains disabled
unless a site enables it and provisions a mailbox PIN. See
[voicemail](VOICEMAIL.md) for its routing and storage requirements.

The chart defaults Asterisk and FreeSWITCH to disabled. The active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
enables both at DC1/YXL and Home1/YVR and supplies a separate voice and fax
DID at each site. The `dc1-k3s-node1` spoke does not enable either workload.

Kamailio handles public carrier SIP. Direct site Services accept UDP/5060;
the shared Gateway passes TLS/5061 through to Kamailio, with PROXY protocol v2
for the original source address. Kamailio checks the configured Flowroute
source CIDRs, then relays to the private FreeSWITCH TLS profile. RTPEngine
anchors public media at the address and port range supplied by the owning
ApplicationSet. See [SIP identity](SIP-IDENTITY.md) for the transport and
dialog route details.

## Configured DID

The [chart defaults](../values.yaml) leave `avoip.did` and `fax.did` empty.
The owning ApplicationSet supplies the voice `avoip.did` and legacy FaxNumber
`fax.did` from site-specific Vault references. Do not put a resolved number or
Secret value in this page.

The desired routing sends the voice DID to a silent digit collector in YVR
FreeSWITCH. Callers can
type `7101`, `9090`, `66`, or `1234`; the allowlist is checked in FreeSWITCH
and each accepted destination is sent through the existing authenticated
FreeSWITCH-to-Asterisk gateway. The IVR has no prompt files or bundled audio
assets. It answers the call to collect DTMF, then transfers it to the selected
service. The selected Asterisk service may play its own audio.

The YXL voice DID crosses the existing carrier Kamailio SIPS/mTLS link to YVR
FreeSWITCH IVR ingress extension `7102`. The YVR carrier permits this ingress
only from the YXL carrier certificate identity and pod CIDR. YVR's own voice
DID enters that same local IVR. YXL's FaxNumber DID and YVR's FaxNumber DID
route to the YVR Asterisk SIP Core endpoint `7101`; the YXL transfer uses the
same existing carrier link, targeting extension `7101` directly.

Inbound calls over either public SIP transport follow this path:

1. The direct site Service sends UDP SIP to Kamailio, or the `main-gw` SIPS
   listener passes TLS through to Kamailio with a PROXY v2 header.
2. Kamailio validates the source against the configured Flowroute
   signaling CIDRs and rejects all other sources.
3. YXL carrier Kamailio sends the voice DID to YVR extension `7102` and its
   FaxNumber DID to extension `7101` over the existing carrier SIPS/mTLS link.
   The YVR carrier validates the YXL certificate SAN and pod CIDR, then
   permits only those two exact ingress extensions.
4. YVR FreeSWITCH requires the authenticated inter-site marker. Extension
   `7102` enters the silent IVR; extension `7101` bridges directly to Asterisk
   SIP Core endpoint `7101`. YVR's own voice DID enters the same IVR, while
   its FaxNumber DID bridges directly to Asterisk.
5. If no DTMF input is entered, FreeSWITCH ends the answered IVR call after
   its configured 15-second input timeout. Destination `66` plays the GG asset
   directly on YVR FreeSWITCH and then hangs up normally. Other selected
   Asterisk extensions use the configured endpoint timeout; failed inbound
   handoffs play GG in FreeSWITCH and hang up normally. Unmatched public
   destinations are rejected.

`freeswitch.inboundBridgeFailure.enabled` defaults to `true` for the direct
voice/FaxNumber, authenticated inter-site, and accepted IVR destination bridges.
FreeSWITCH uses [`continue_on_fail` and `hangup_after_bridge`](https://developer.signalwire.com/freeswitch/dialplan/xml/)
to continue a failed handoff while ending successful bridges normally. It ignores
early media until the destination answers, answers the caller on failure, plays
the existing GG asset from `freeswitch.preBridgeAudio.url` through `mod_shout`,
then hangs up with `NORMAL_CLEARING`. The fallback clears the post-answer hook
to avoid playing the same asset twice, and clears the inherited SIP error cause.
An already answered IVR call proceeds directly to playback. A caller who has
cancelled or hung up cannot be answered again. This applies once the call has
reached FreeSWITCH; failures in an earlier carrier/Kamailio hop cannot execute
its dialplan. Authentication failures and unmatched destinations keep their
existing rejection behavior.

Verify a new inbound bridge failure by its `AVoIP inbound bridge failed` log,
carrier `200 OK`/ACK, GG RTP playback, and normal BYE. Also verify a successful
handoff ends without GG. Reconcile the dialplan ConfigMap through the
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
and allow the existing Reloader rollout to finish on both FreeSWITCH replicas.
Setting the flag to `false` restores the earlier failure handling after the
same reconciliation; no persistent data or external resources are removed.

The YXL-to-YVR routes use the existing carrier peers' Vault-issued client
identities and YVR ClusterIP `10.44.7.136:5061`; they do not enable the YXL
direct public SIP Service. The Asterisk DID route no longer sends `Progress()`
early media before dialing, so an unavailable endpoint does not suppress
normal ringing with an empty early-media stream. See the
[inter-site voice route guide](INTERSITE-VOICE.md) for the trust path and
operations.

The separate `fax-receive` extension and retained fax spool remain available
for explicit future routing, but neither DID currently selects fax reception.
Call-detail records are written to the service account's PostgreSQL database by
[`mod_cdr_pg_csv`](https://developer.signalwire.com/freeswitch/module-reference/event-handlers/mod_cdr_pg_csv/);
the chart creates its `cdr` table during pod initialization. Runtime logs remain
stdout logs collected by Kubernetes rather than rows in PostgreSQL.

The public dialplan is in
[FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
The default context is deliberately empty.

The public context keeps inbound DID routing through Kamailio and rejects
unmatched public destinations. YVR's authenticated Asterisk SIP Core NANP
accounts may originate +1 calls through FreeSWITCH. Currently, YVR extension
`7101` is the configured SIP Core caller; YXL has no SIP Core caller configured.
FreeSWITCH at both sites registers with the existing Vault record
`AVoIP/SIP/FlowRoute` at its regional Flowroute endpoint (US-East-VA for YXL,
US-West-OR for YVR), then sends outbound INVITEs through the private Kamailio TLS
listener. Kamailio/RTPEngine retain the carrier route and media handling. Two
FreeSWITCH replicas allow new calls to use a surviving pod; active calls do
not fail over. HA uses a new RWX fax spool claim. The previous retained RWO
claim is not migrated automatically.

## SIP messaging

Flowroute SMS/SIP MESSAGE handling is provided by the
`mod_sms_flowroute` module. Its generated configuration is mounted from the
External Secret `freeswitch-sms` at
`/etc/freeswitch/autoload_configs/sms_flowroute.conf.xml`.

The reduced `modules.conf.xml` loads Sofia, XML dialplan, logging, command,
DTMF/application, and Opus support. `mod_xml_ldap` is temporarily disabled by
default because it crashes on the dedicated Asterisk authentication lookup.
The Flowroute SMS module remains loaded, but directory-backed user lookups are
unavailable while LDAP is disabled.
SMS is enabled by default through `freeswitch.sms.enabled`; disabling it omits
both the SMS modules and the External Secret-backed Flowroute SMS configuration.

## Registration and directory

FreeSWITCH LDAP directory integration is temporarily disabled by default with
`freeswitch.ldap.enabled: false`. This omits the `mod_xml_ldap` module and its
configuration mount. Re-enabling the value loads the LDAP directory from
[FreeSwitchMiscConfig.yaml](../templates/FreeSwitch/FreeSwitchMiscConfig.yaml);
the LDAPS server hostname is selected from `datacenter` as
`ldap-<datacenter>.mylogin.space`. The directory maps mylogin.space user
attributes for identity, password, dial string, number alias, call group, ACL,
and caller ID fields. Dynamic LDAP-backed SIP users are unavailable while the
integration is disabled.

The Asterisk peer uses its separate static directory entry, whose Digest
password comes from the shared Secret. It does not require the LDAP directory.
The FreeSWITCH `User` claim remains for the service identity credentials used
by the container; production Secret values are intentionally not documented.

The active SIP profiles are defined in
[FreeSwitchSIPConfig.yaml](../templates/FreeSwitch/FreeSwitchSIPConfig.yaml):

- `external` listens on SIP `5080` and TLS SIP `5081`, advertises the configured
  external addresses, and uses the `public` context.
- `asterisk` is a private TLS-only profile for the Asterisk peer. It requires
  SIP digest authentication and enters the dedicated `from-asterisk` dialplan
  context without a broad private-network ACL bypass. The
  profile listens on its dedicated TLS port `5064` (the Kamailio-facing
  FreeSWITCH profile uses `5061`). The hop uses TLS and the profile requires
  SIP Digest. It does not request Asterisk's current public server certificate
  as a client certificate; mTLS requires a separate certificate from an
  approved internal CA. The chart keeps the current Digest check active.
  The
  peer username/password come from a Kubernetes Secret mounted into the SIP
  processes, so neither credential is rendered into Git-managed configuration.
  The configured GG extension transfers to the exact `gg-audio` destination in
  `asterisk.xml`; other site-specific Asterisk transfer destinations and
  scripts belong in the same file generated by
  [FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
  That context has no wildcard route.
- The image's default `internal`, `internal-ipv6`, and `external-ipv6` Sofia
  profiles are overlaid with empty files so they cannot compete for SIP port
  `5060` or create an unintended additional listener.

The internal peer call must validate SIP Digest before reaching its restricted
context. Flowroute traffic uses the
separate external profile and source CIDR ACL; inbound Flowroute calls are
bridged to Asterisk without LDAP authentication.

## Network and media

- Asterisk runs as an unprivileged UID/GID `1000`, with all Linux capabilities
  dropped, privilege escalation disabled, and the Kubernetes RuntimeDefault
  seccomp profile. Its root filesystem is read-only; its run, library, log,
  spool, and temporary files use separate ephemeral `emptyDir` mounts and are
  lost when the pod is replaced.
- Asterisk's PJSIP transport treats the cluster pod network as local and does
  not advertise the public NAT address to FreeSWITCH. With no external media
  or signaling override configured, Asterisk advertises its pod address for
  the internal SIP/RTP leg; the Asterisk ClusterIP Service remains the SIP
  rendezvous point.
- Asterisk CDRs use the PostgreSQL database provisioned by its `User` claim and
  the site-local PostgreSQL provider. A startup init container creates the CDR
  table, while runtime credentials generate `cdr_pgsql.conf` in `emptyDir`;
  Asterisk does not use local CDR CSV or SQLite storage.
- The Asterisk init container copies packaged sounds from the image's
  `/usr/share/asterisk/sounds` into the dedicated `asterisk-sounds` `emptyDir`
  mounted at `/var/lib/asterisk/sounds`, which is the normal `Playback()` search
  path. The sounds are lost when the pod is replaced.
- Asterisk's global Entity ID is explicitly configured in `values.yaml`, so
  startup does not need to read a hardware MAC address from the pod interface.
- Asterisk startup, readiness, and liveness use `asterisk -rx 'core show
  uptime'`; FreeSWITCH uses a non-network process/configuration check because
  its event socket is not enabled. Startup checks allow up to three minutes
  for FreeSWITCH and two minutes for Asterisk.
- Both controllers use surge-first rolling updates with zero unavailable pods
  and require the replacement to pass readiness before the old replica is
  removed.
- FreeSWITCH runs with `-nf -nc` so it remains a foreground Kubernetes process
  without attaching an interactive console prompt to the container log stream.
- FreeSWITCH's Event Socket is enabled on loopback TCP `8021` for local control
  and diagnostics. It is not exposed through a Service or public route, and its
  password comes from the existing Secret-backed FreeSWITCH credential.
- Kamailio emits compact markers for inbound SIP requests, backend relay
  attempts, backend replies, relay failures, source rejections, and
  in-dialog loose-route decisions when `kamailio.sipLogging.enabled` is true.
  It records method, source, destination, route URI, request URI, and Call-ID
  without dumping full SIP messages or SDP bodies.
- Sofia raw SIP tracing is enabled by default on the Asterisk and external
  profiles through `freeswitch.sipLogging.enabled`. It is intended for call
  troubleshooting and includes signaling/SDP metadata in the pod logs.
- Public FreeSWITCH TCP/UDP SIP Gateway API routes are removed. The UDP SIP
  path uses the site's direct Kamailio Service. The `core-prod/main-gw` SIPS
  listener uses TLS passthrough to Kamailio and PROXY protocol v2.
- Kamailio accepts public signaling only from the Flowroute PoP CIDRs in
  `flowroute.signalingCIDRs`; the private FreeSWITCH Kamailio
  profile only accepts traffic from the configured Kamailio pod CIDR.
- Kamailio presents the certificate for public TLS, and FreeSWITCH uses its
  private TLS material for the backend leg. No private key is stored in Git.
- RTPEngine advertises the site-specific public media address from the owning
  ApplicationSet. FreeSWITCH's own public RTP Service is omitted while
  Kamailio and RTPEngine are enabled.

See [common.yaml](../templates/common.yaml),
[Kamailio values](KAMAILIO-VALUES.md), and
[FreeSwitchEgress.yaml](../templates/FreeSwitch/FreeSwitchEgress.yaml).

## Explicitly removed behavior

The following are no longer configured by this chart:

- FreeSWITCH's stock `default.xml` feature tree.
- Public extension and conference ranges.
- Demo IVR and its menu destinations.
- Conference, eavesdrop, paging, parking, fax, ringback, tone, and diagnostic
  test numbers.
- Default provider/sample gateway variables.
- Unused Verto, Opal, ALSA, FIFO, local-stream, FreeSWITCH voicemail, and
  sample module configuration.
- Vosk and Mycroft/OVOS speech services.

Speech integration remains a separate planned connection to the shared
[AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml),
where Wyoming, GPUStack, and Speaches are deployed.

## Validation checklist

Before enabling the hub:

1. Confirm the ApplicationSet supplies distinct `avoip.did` and `fax.did`
   values for the site; do not print their secret-backed values in logs.
2. Confirm the Asterisk `User` claim produces its connection Secret and that
   Asterisk starts with the generated PJSIP auth object (without printing the
   Secret values).
3. Send a SIP MESSAGE to the DID and verify delivery through
   `mod_sms_flowroute`.
4. Place an inbound voice call, enter each permitted destination and verify
   its Asterisk behavior. Call the FaxNumber DID separately and verify that
   extension `7101` rings; also confirm that an unavailable endpoint ends
   cleanly after the dial timeout.
5. Place an outbound call through Asterisk and verify FreeSWITCH rejects an
   invalid credential or non-internal source.
   Run the [negative SIP probes](../tests/README.md#authorization-and-outbound-call-probes)
   from both denied and ACL-permitted test sources. The current Asterisk
   endpoint has no inbound `auth` setting, so its direct private TLS listener
   needs its own challenge/rejection result before treating that boundary as
   credential protected.
6. Verify RTP, DTMF, TLS certificate validation, and provider failure behavior.

FreeSWITCH references: [official documentation](https://developer.signalwire.com/freeswitch/)
and the [XML dialplan documentation](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Configuration/Dialplan/).
The LDAP lookup behavior follows [mod_xml_ldap](https://developer.signalwire.com/freeswitch/module-reference/xml-interfaces/mod_xml_ldap/),
and the profile authentication boundary follows the [Sofia SIP profile
documentation](https://developer.signalwire.com/freeswitch/users-and-endpoints/sip-profiles/).
