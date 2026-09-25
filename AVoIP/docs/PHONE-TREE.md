# AVoIP phone tree and DID service

The AVoIP voice configuration is intentionally minimal. It no longer ships
the upstream FreeSWITCH demonstration dialplan, sample extensions, conference
codes, parking codes, fax tests, voicemail routes, or demo IVR.

The chart defaults Asterisk and FreeSWITCH to disabled. Kamailio has its own
enablement flag. The current [AVoIP
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
enables both only on `core-dc1-talos-prod`.

Public SIP exposure is disabled by default with
`kamailio.publicExposure.sip.enabled: false`. When enabled, Kamailio owns the
public UDP SIP route on port 5060 and the TLS route on port 5061. `main-gw`
terminates TLS using its `tls-sip` listener and forwards the decrypted SIP
stream with PROXY protocol v2; Kamailio verifies the original Flowroute source
address before forwarding SIP over the private cluster network to FreeSWITCH.
FreeSWITCH has no direct public SIP routes;
the optional PureLB LoadBalancer exposes RTP only at the requested
`freeswitch.publicExposure.address`.

## Configured DID

The configured DID is `freeswitch.did`, currently `18077893501` in
[values.yaml](../values.yaml). The value is used by the public dialplan and is
the single number accepted by the FreeSWITCH public context.

Inbound calls over either public SIP transport follow this path:

1. The Gateway sends UDP SIP directly to Kamailio, or terminates TLS on the
   `main-gw` `tls-sip` listener and sends the decrypted TCP stream with a
   PROXY v2 header.
2. Kamailio validates the source against the configured Flowroute
   signaling CIDRs and rejects all other sources.
3. Kamailio forwards accepted SIP to FreeSWITCH's private `kamailio` Sofia
   profile and inserts a two-sided Record-Route set: private UDP toward
   FreeSWITCH and `sip.resolvemy.host:5081;transport=tls` toward Flowroute for
   the Gateway-terminated TLS leg. In-dialog requests are processed with
   `loose_route()` before relay; the selected route destination is preserved.
4. The public context matches only the configured DID.
5. With fax handling enabled, FreeSWITCH answers the carrier leg, starts
   SpanDSP fax-tone detection, and plays the optional pre-bridge audio. Voice
   calls then bridge to Asterisk; when a fax tone is detected, the call is
   diverted to SpanDSP `rxfax` with T.38 negotiation enabled instead. The
   deployed FreeSWITCH image does not expose the optional `disable_ec`
   dialplan application, so the chart does not invoke it.
6. FreeSWITCH writes a received TIFF to its ephemeral fax spool and logs the
   fax result, then hangs up. The same DID therefore accepts both voice and fax
   calls, subject to the carrier's fax-tone timing.

FreeSWITCH emits INFO log markers when the DID call is received and when fax
processing completes. The receive implementation uses
[`mod_spandsp`](https://developer.signalwire.com/freeswitch/applications/fax/)
and its `rxfax` application. Received TIFFs are lost when the pod is replaced;
durable fax storage and delivery are not configured yet. Call-detail records are
written to the service account's PostgreSQL database by
[`mod_cdr_pg_csv`](https://developer.signalwire.com/freeswitch/module-reference/event-handlers/mod_cdr_pg_csv/);
the chart creates its `cdr` table during pod initialization. Runtime logs remain
stdout logs collected by Kubernetes rather than rows in PostgreSQL.

The public dialplan is in
[FreeSwitchDialplanConfig.yaml](../templates/FreeSwitch/FreeSwitchDialplanConfig.yaml).
The default context is deliberately empty.

FreeSWITCH voice outbound is disabled. The public context contains an explicit
catch-all rejection after the configured DID route, so authenticated internal
SIP callers and permitted carrier sources cannot use FreeSWITCH to place an
unmatched outbound call. FreeSWITCH does not register to Flowroute; carrier
signaling is accepted only through Kamailio.

## SIP messaging

Flowroute SMS/SIP MESSAGE handling is provided by the
`mod_sms_flowroute` module. Its generated configuration is mounted from the
External Secret `freeswitch-sms` at
`/etc/freeswitch/autoload_configs/sms_flowroute.conf.xml`.

The module is explicitly loaded in the reduced `modules.conf.xml` alongside
Sofia, XML LDAP, XML dialplan, logging, command, DTMF/application, and Opus
support. Messages are not sent through the voice dialplan; they are handled by
the Flowroute SMS module and the registered directory identity.
SMS is enabled by default through `freeswitch.sms.enabled`; disabling it omits
both the SMS modules and the External Secret-backed Flowroute SMS configuration.

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
- Public FreeSWITCH TCP/UDP SIP Gateway API routes are removed. The UDP SIP and
  TLS SIP routes attach to the configured `core-prod/main-gw` Gateway and target
  Kamailio. The `tls-sip` Gateway listener must use `TLS` with `tls.mode:
  Terminate`; its Envoy `BackendTrafficPolicy` enables PROXY protocol v2 for
  the resulting plain TCP stream.
- Kamailio accepts public signaling only from the Flowroute PoP CIDRs in
  `flowroute.signalingCIDRs`; the private FreeSWITCH Kamailio
  profile only accepts traffic from the configured Kamailio pod CIDR.
- TLS uses `sip.resolvemy.host` and the configured certificate Secret on the
  `main-gw` listener. Kamailio receives plain TCP on its backend port 5061 and
  does not consume the public certificate.
- The certificate Secret is consumed at runtime by the Gateway and by
  FreeSWITCH's private TLS material; no combined private-key file is stored in
  Git.
- When public RTP exposure is enabled, PureLB exposes RTP only at the requested
  `freeswitch.publicExposure.address`.
- RTP uses the configured FreeSWITCH range `11000–11049`.
- The external FreeSWITCH profile advertises the requested PureLB RTP address
  `66.165.222.101` when public RTP exposure is enabled. The outbound SIP
  egress address is also `66.165.222.101`; the former `66.165.222.103` and
  stale `66.165.222.126` addresses are no longer used.

See [common.yaml](../templates/common.yaml),
[UDPRoute.yaml](../templates/Kamailio/UDPRoute.yaml),
[TCPRoute.yaml](../templates/Kamailio/TCPRoute.yaml), and
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

1. Confirm the DID identity exists in the current mylogin.space directory and
   can register.
2. Confirm the Asterisk `User` claim produces its connection Secret and that
   Asterisk starts with the generated PJSIP auth object (without printing the
   Secret values).
3. Send a SIP MESSAGE to the DID and verify delivery through
   `mod_sms_flowroute`.
4. Place an inbound call and verify the configured DID endpoint receives it.
5. Place an outbound call through Asterisk and verify FreeSWITCH rejects an
   invalid credential or non-internal source.
6. Verify RTP, DTMF, TLS certificate validation, and provider failure behavior.

FreeSWITCH references: [official documentation](https://developer.signalwire.com/freeswitch/)
and the [XML dialplan documentation](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Configuration/Dialplan/).
The LDAP lookup behavior follows [mod_xml_ldap](https://developer.signalwire.com/freeswitch/module-reference/xml-interfaces/mod_xml_ldap/),
and the profile authentication boundary follows the [Sofia SIP profile
documentation](https://developer.signalwire.com/freeswitch/users-and-endpoints/sip-profiles/).
