# AVoIP phone tree and DID service

The AVoIP voice configuration is intentionally minimal. It no longer ships
the upstream FreeSWITCH demonstration dialplan, sample extensions, conference
codes, parking codes, fax tests, voicemail routes, or demo IVR.

The chart defaults Asterisk and FreeSWITCH to disabled. The current [AVoIP
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
enables both only on `core-dc1-talos-prod`.

## Configured DID

The configured DID is `freeswitch.did`, currently `18077893501` in
[values.yaml](../values.yaml). The value is used by the public dialplan and is
the single number accepted by the FreeSWITCH public context.

Inbound calls follow this path:

1. Flowroute registers through the `flowroute` gateway using the External
   Secret-backed account credentials in
   [FreeSwitchUpstream.yaml](../templates/FreeSwitch/FreeSwitchUpstream.yaml)
   and [FreeSwitchUpstreamSync.yaml](../templates/FreeSwitch/FreeSwitchUpstreamSync.yaml).
2. FreeSWITCH receives the call on the external Sofia profile.
3. The external profile applies the `flowroute` ACL and rejects sources that
   are not in the configured Flowroute signaling CIDRs.
4. The public context matches only the configured DID.
5. The call is delivered to the registered FreeSWITCH directory identity for
   that DID using `user/<did>@<domain>`.
6. If no matching directory registration exists, the bridge fails and the
   call is released; there are no fallback sample routes.

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
password, dial string, number alias, call group, ACL, and caller ID fields.
The FreeSWITCH `User` claim supplies the service identity credentials used by
the container; production Secret values are intentionally not documented.

The active SIP profiles are defined in
[FreeSwitchSIPConfig.yaml](../templates/FreeSwitch/FreeSwitchSIPConfig.yaml):

- `external` listens on SIP `5080` and TLS SIP `5081`, advertises the configured
  external addresses, and uses the `public` context.
- `asterisk` remains available for the separate Asterisk peer, but it is not a
  public fallback route.

## Network and media

- Gateway API routes expose TCP and UDP SIP through `main-gw`.
- The external SIP profile only accepts signaling from the Flowroute PoP CIDRs
  in `freeswitch.flowroute.signalingCIDRs`.
- TLS uses `sip.resolvemy.host` and the configured certificate Secret.
- PureLB exposes external SIP and RTP.
- RTP uses the configured FreeSWITCH range `11000–11049`.
- `network.externalIP` is used for advertised RTP; `network.egressIP` is used
  for SIP NAT and the Cilium egress policy.

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
3. Send a SIP MESSAGE to the DID and verify delivery through
   `mod_sms_flowroute`.
4. Place an inbound call and verify the registered DID endpoint receives it.
5. Verify RTP, DTMF, TLS certificate validation, and provider failure behavior.

FreeSWITCH references: [official documentation](https://developer.signalwire.com/freeswitch/)
and the [XML dialplan documentation](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Configuration/Dialplan/).
