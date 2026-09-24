# AVoIP phone tree and DID service

The AVoIP voice configuration is intentionally minimal. It no longer ships
the upstream FreeSWITCH demonstration dialplan, sample extensions, conference
codes, parking codes, fax tests, voicemail routes, or demo IVR.

The chart defaults Asterisk and FreeSWITCH to disabled. The current [AVoIP
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
enables both only on `core-dc1-talos-prod`.

Public SIP exposure is disabled by default with
`freeswitch.publicExposure.sip.enabled: false`. FreeSWITCH keeps its internal
ClusterIP services and outbound Flowroute registration, while the optional
PureLB LoadBalancer exposes RTP only at the requested
`freeswitch.publicExposure.address`.

## Configured DID

The configured DID is `freeswitch.did`, currently `18077893501` in
[values.yaml](../values.yaml). The value is used by the public dialplan and is
the single number accepted by the FreeSWITCH public context.

Inbound calls follow this path:

1. FreeSWITCH registers through the `flowroute` gateway using the configured
   DID as the SIP/From username and the External Secret-backed Flowroute SIP
   username and password for digest authentication. The registration realm,
   proxy, and transport are pinned to the configured Flowroute Oregon PoP. The
   gateway configuration is in
   [FreeSwitchUpstream.yaml](../templates/FreeSwitch/FreeSwitchUpstream.yaml)
   and [FreeSwitchUpstreamSync.yaml](../templates/FreeSwitch/FreeSwitchUpstreamSync.yaml).
2. FreeSWITCH receives the call on the external Sofia profile.
3. The external profile applies the `flowroute` ACL and rejects sources that
   are not in the configured Flowroute signaling CIDRs.
4. The public context matches only the configured DID.
5. With fax handling enabled, FreeSWITCH answers the carrier leg, disables echo
   cancellation, waits two seconds for fax tone stabilization, and runs
   SpanDSP `rxfax` with T.38 negotiation enabled.
6. FreeSWITCH writes the received TIFF to its ephemeral fax spool and logs the
   fax result, then hangs up. The DID does not bridge to Asterisk while fax
   handling is enabled.

FreeSWITCH emits INFO log markers when the DID call is received and when fax
processing completes. The receive implementation uses
[`mod_spandsp`](https://developer.signalwire.com/freeswitch/applications/fax/)
and its `rxfax` application. Received TIFFs are lost when the pod is replaced;
durable storage and delivery are not configured yet.

The public dialplan is in
[FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
The default context is deliberately empty.

## SIP messaging

Flowroute SMS/SIP MESSAGE handling is provided by the
`mod_sms_flowroute` module. Its generated configuration is mounted from the
External Secret `freeswitch-sms` at
`/etc/freeswitch/autoload_configs/sms_flowroute.conf.xml`.

The module is explicitly loaded in the reduced `modules.conf.xml` alongside
Sofia, XML LDAP, XML dialplan, logging, command, DTMF/application, and Opus
support. Messages are not sent through the voice dialplan; they are handled by
the Flowroute SMS module and the registered directory identity.

## Registration and directory

FreeSWITCH loads the LDAP directory integration from
[FreeSwitchMiscConfig.yaml](../templates/FreeSwitch/FreeSwitchMiscConfig.yaml).
The directory maps the current mylogin.space user attributes for identity,
password, dial string, number alias, call group, ACL, and caller ID fields for
authenticated internal SIP users.
The FreeSWITCH `User` claim supplies the service identity credentials used by
the container; production Secret values are intentionally not documented.

The active SIP profiles are defined in
[FreeSwitchSIPConfig.yaml](../templates/FreeSwitch/FreeSwitchSIPConfig.yaml):

- `external` listens on SIP `5080` and TLS SIP `5081`, advertises the configured
  external addresses, and uses the `public` context.
- `asterisk` remains an internal, ACL-restricted peer for Asterisk. It requires
  SIP digest authentication and resolves the supplied username with the LDAP
  `cn=%s` filter; it is not a public fallback route. Asterisk obtains its
  username/password from its generated mylogin.space `User` connection Secret
  at startup, so neither credential is rendered into Git-managed configuration.
- The image's default `internal`, `internal-ipv6`, and `external-ipv6` Sofia
  profiles are overlaid with empty files so they cannot compete for SIP port
  `5060` or create an unintended additional listener.

Outbound authorization therefore has two independent gates: the request must
come from the internal Asterisk ACL, and its username/password must validate
against the LDAP-backed FreeSWITCH directory. Flowroute traffic uses the
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
- The Asterisk init container copies packaged sounds from the image's
  `/usr/share/asterisk/sounds` into the writable library volume at
  `/var/lib/asterisk/sounds`, which is the normal `Playback()` search path.
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
- Public TCP/UDP SIP Gateway API routes are not rendered unless
  `freeswitch.publicExposure.sip.enabled` is explicitly enabled. The existing
  TLS SIP route remains attached to the configured `core-prod/main-gw`
  Gateway.
- The external SIP profile only accepts signaling from the Flowroute PoP CIDRs
  in `freeswitch.flowroute.signalingCIDRs`.
- TLS uses `sip.resolvemy.host` and the configured certificate Secret.
- The certificate Secret is consumed at runtime as `tls.crt` and `tls.key`; a
  rootless init container combines them into FreeSWITCH's required
  `agent.pem` without storing a combined private-key file in Git.
- When public RTP exposure is enabled, PureLB exposes RTP only at the requested
  `freeswitch.publicExposure.address`.
- RTP uses the configured FreeSWITCH range `11000–11049`.
- The external FreeSWITCH profile advertises the requested PureLB RTP address
  `66.165.222.101` when public RTP exposure is enabled. The outbound SIP
  egress address is also `66.165.222.101`; the former `66.165.222.103` and
  stale `66.165.222.126` addresses are no longer used.

See [common.yaml](../templates/common.yaml),
[FreeSwitchTCPRoute.yaml](../templates/FreeSwitch/FreeSwitchTCPRoute.yaml),
[FreeSwitchUDPRoute.yaml](../templates/FreeSwitch/FreeSwitchUDPRoute.yaml),
[TLSRoute.yaml](../templates/FreeSwitch/TLSRoute.yaml), and
[FreeSwitchEgress.yaml](../templates/FreeSwitch/FreeSwitchEgress.yaml).

## Explicitly removed behavior

The following are no longer configured by this chart:

- FreeSWITCH's stock `default.xml` feature tree.
- Public extension and conference ranges.
- Demo IVR and its menu destinations.
- Conference, eavesdrop, paging, parking, fax, ringback, tone, and diagnostic
  test numbers.
- Default provider/sample gateway variables.
- Unused Verto, Opal, ALSA, FIFO, local-stream, voicemail, and sample module
  configuration.
- Vosk and Mycroft/OVOS speech services.

Speech integration remains a separate planned connection to the shared
[AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml),
where Wyoming, GPUStack, and Speaches are deployed.

## Validation checklist

Before enabling the hub:

1. Confirm the Flowroute ExternalSecret is ready and the gateway registers.
2. Confirm the DID identity exists in the current mylogin.space directory and
   can register.
3. Confirm the Asterisk `User` claim produces its connection Secret and that
   Asterisk starts with the generated PJSIP auth object (without printing the
   Secret values).
4. Send a SIP MESSAGE to the DID and verify delivery through
   `mod_sms_flowroute`.
5. Place an inbound call and verify the registered DID endpoint receives it.
6. Place an outbound call through Asterisk and verify FreeSWITCH rejects an
   invalid credential or non-internal source.
7. Verify RTP, DTMF, TLS certificate validation, and provider failure behavior.

FreeSWITCH references: [official documentation](https://developer.signalwire.com/freeswitch/)
and the [XML dialplan documentation](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Configuration/Dialplan/).
The LDAP lookup behavior follows [mod_xml_ldap](https://developer.signalwire.com/freeswitch/module-reference/xml-interfaces/mod_xml_ldap/),
and the profile authentication boundary follows the [Sofia SIP profile
documentation](https://developer.signalwire.com/freeswitch/users-and-endpoints/sip-profiles/).
