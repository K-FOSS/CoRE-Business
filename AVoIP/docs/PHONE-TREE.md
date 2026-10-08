# AVoIP phone tree and DID service

The AVoIP voice configuration is intentionally minimal. It no longer ships
the upstream FreeSWITCH demonstration dialplan, sample extensions, conference
codes, parking codes, fax tests, voicemail routes, or demo IVR.

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
The owning ApplicationSet supplies both from site-specific secret references.
Keep them distinct: `avoip.did` goes to Asterisk for voice, and `fax.did` goes
directly to FreeSWITCH fax reception. Do not put a DID or Secret value in this
page.

Inbound calls over either public SIP transport follow this path:

1. The direct site Service sends UDP SIP to Kamailio, or the `main-gw` SIPS
   listener passes TLS through to Kamailio with a PROXY v2 header.
2. Kamailio validates the source against the configured Flowroute
   signaling CIDRs and rejects all other sources.
3. Kamailio forwards accepted SIP to FreeSWITCH's private `kamailio` Sofia
   profile over TLS. Its public Contact and route set follow the carrier's
   ingress transport; the private leg uses TLS/5062 toward Kamailio and
   TLS/5061 toward FreeSWITCH.
4. FreeSWITCH matches `fax.did` first and transfers it to `fax-receive`.
   That extension answers, plays a 2100 Hz called-station tone, and runs
   [`mod_spandsp` `rxfax`](https://developer.signalwire.com/freeswitch/applications/fax/).
   At Home1/YVR, the ApplicationSet selects G.711-only PCMU reception because
   the reported working fax used G.711 and T.38 has not worked. DC1/YXL keeps
   the chart's T.38-capable setting. The chart defaults disable V.17 and ECM;
   the documented Flowroute path is validated only through 9600 bps.
5. FreeSWITCH writes `${uuid}.tif` under `freeswitch.fax.spoolPath`, logs the
   fax result and packet counts, then hangs up. The spool is a retained
   Longhorn `ReadWriteOnce` claim by default. No automatic TIFF delivery or
   TIFF retention cleanup is configured.
6. A call to `avoip.did` rings and bridges to Asterisk. The voice DID has no
   fax-tone detector and does not enter `rxfax`. Unmatched destinations are
   rejected.

The reported YVR fax success confirms G.711 reception. The page count,
resulting TIFF and SIP ACK still require a retained call-specific trace to
document them as verified. Call-detail records are
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
- Unused Verto, Opal, ALSA, FIFO, local-stream, voicemail, and sample module
  configuration.
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
4. Place an inbound voice call and verify the Asterisk bridge. Call the fax
   DID separately; confirm G.711 reception in YVR, a successful `rxfax` result,
   a TIFF on the retained spool, and an ACK on both SIP hops.
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
