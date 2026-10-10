# AVoIP SIP identity and dedicated fax routing

The active chart owner is Backplane's [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml), which supplies cluster identity, component enablement, site SIP hostname, DIDs, and egress policy. The separate [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml) configures the shared Gateway listener and its SIPS fallback. Home1/YVR and DC1/YXL use TLSRoute on port 5061; Kamailio owns the TLS session. An EnvoyPatchPolicy makes the SIPS filter chain a fallback for clients that omit SNI. Render both injected value layers before reconciliation.

## Signaling and media paths

| Traffic | Path | Carrier-facing identity at the hub |
| --- | --- | --- |
| Inbound INVITE and its reply | Flowroute ↔ Kamailio direct Service over UDP/TCP, or Envoy TLS passthrough ↔ Kamailio over TLS | Direct Service hostname on UDP/TCP 5060, or site SIP hostname on TLS 5061 |
| New outbound request, such as FreeSWITCH's BYE | Kamailio → VyOS WAN-GW/NAT VRRP pair → Flowroute | `66.165.222.97` observed on the BYE transaction |
| RTP | Flowroute ↔ RTPEngine | `66.165.222.103` advertised in SDP |

The VyOS routers [source NAT](https://docs.vyos.io/en/latest/configuration/nat/nat44.html#source-nat) new outbound connections to their shared VRRP address. The observed outbound BYE and its successful response establish that this egress path works; they do not establish that the original INVITE answer reached Flowroute.

Flowroute can send an INVITE from an ephemeral TLS source port while its Via advertises 5061 without `rport`. The chart configures [`force_rport()`](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#force_rport) for authorized carrier requests so the answer targets the received port and can reuse the inbound Envoy/PROXY-protocol connection. New outbound requests still target Flowroute's port 5061. Confirm the resulting connection choice and ACK with a live call; the address logged at Kamailio's send boundary alone does not prove delivery.

## 2026-10-07 ACK-timeout investigation

### Resolution status

The inbound-call failure that ended answered calls after approximately 32
seconds has been reported resolved on 2026-10-07. The transport-specific
public Record-Route and sending-socket correction below is the associated
configuration change. The operator correlated Call-ID
`4611692164-4000414305-968465085@IRISMSC8.iristel.net` in Homer and
reported approximately 120 seconds of conversation, 129 seconds total, and a
complete recording. That is a concrete beyond-60-second voice observation;
the Homer trace and recording were not exported into this repository or
independently reviewed here. Retain the Call-ID-correlated 2xx ACK at both
Kamailio and FreeSWITCH and the terminating BYE/200 exchange before closing
the full SIP regression gate. The recording alone does not prove those
signaling exchanges or fax reception.

The supplied Home1 trace confirms FreeSWITCH answered Call-ID
`4603026123-4000377119-1786145794@IRISMSC8.iristel.net`, retransmitted its
200 OK, received no ACK, and timed out at about 32 seconds. RTP was flowing
before `rxfax`, so no codec, fax, or RTPEngine change is indicated. A later
Call-ID's same-branch ACKs appear to acknowledge non-2xx responses and do not
establish the 2xx ACK path. Their response codes were not available in the
retained Kamailio logs; obtain the matching final response before classifying
those retries.

The confirmed configuration defect is that `RR_CARRIER_TO_BACKEND` always
inserted a public TLS/5061 Record-Route, regardless of the INVITE's ingress
transport. Kamailio 6.1.4 TOPOS used that route identity to build the carrier
Contact, so a UDP INVITE received a TLS/5061 Contact and TLS route set. The
script also forced `public_tls` in `TO_CARRIER`, overriding the public socket
selected by the restored route for backend-originated dialog requests. The
patch selects UDP/5060 and `public_udp` for UDP ingress, TCP/5060 and
`public_tcp` for TCP ingress, and retains site TLS/5061 and `public_tls` for
TLS ingress. The private Record-Route and Kamailio-to-FreeSWITCH leg remain
TLS/5062. The response's SIP transaction still returns over its original
transport; the changed Contact controls later dialog requests.

This proves why the UDP-originated dialog advertised TLS. It does not prove
whether Flowroute attempted TLS and failed negotiation, did not attempt the
advertised Contact, or lost the resulting ACK elsewhere: the supplied TCP
capture has no SIP visibility and no ACK appears at either SIP endpoint. A
live Call-ID-correlated trace after rollout is needed to establish where the
ACK travels. The expected path is Flowroute UDP → public Service UDP/5060 →
Kamailio (any replica) → private TLS/5062 → the single FreeSWITCH replica.

No Gateway or RTPEngine resource change is needed for this fix. The active
[Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml)
configures Home1's `main-gw` Service at `10.1.1.84`. Its `sips-tls` listener
uses TLS passthrough on 5061, the AVoIP TLSRoute targets Kamailio Service
TCP/5061, and its BackendTrafficPolicy adds PROXY protocol v2 so Kamailio can
enforce the carrier source ACL. The separate `kamailio-pub` Service uses
KubeVIP on Home1 and exposes UDP/5060 and TCP/5061. The supplied
`10.0.0.41` handoff trace therefore describes that direct KubeVIP path; it
does not establish TLSRoute delivery or TLS negotiation. Kamailio presents
the certificate on both TLS paths; the rendered Certificate includes the site
and direct-Service hostnames. Read-only TLS 1.3 handshakes on 2026-10-07
verified the certificate hostname and chain at the site hostname, direct
KubeVIP hostname, and configured Gateway IP `10.1.1.84`. These checks do not
prove this call's ACK delivery or the carrier's TLS behavior. UDP uses the direct Service with
`externalTrafficPolicy: Local`; Flowroute
source CIDRs are unchanged. TOPOS remains enabled and uses the site-local
Dragonfly database 51 with a single `serverid=topos` on all replicas. The
documented default branch retention is 180 seconds and dialog retention is
three hours. FreeSWITCH remains one replica per site, preserving the local
B2BUA dialog owner. RTPEngine offer/answer, deletion, codecs and fax settings
are unchanged.

For carrier TLS, `sip.siteHost` is the public SIP identity, supplied through the carrier entry's `advertisedHost` or derived as `sip.<cluster>.<datacenter>.<region>.resolvemy.host`. For carrier UDP/TCP, the public identity is the `kamailio-pub` direct Service hostname, derived as `kamailio-pub.<cluster>.<datacenter>.<region>.resolvemy.host`. Initial transport selects the paired public Record-Route URI: UDP/5060, TCP/5060, or TLS/`kamailio.defaults.advertisedTLSPort`. The private side stays Kamailio Service TLS/5062 for every carrier transport. The direct public Service is required for UDP/TCP; Helm fails rendering when either transport is enabled without it.

Kamailio 6.1.4 is pinned by `values.yaml`. Its version-specific [TOPOS documentation](https://www.kamailio.org/docs/modules/6.1.x/modules/topos.html) documents `contact_mode=1`, `cparam_name`, event hooks, and deriving the Contact host from Record-Route. The chart keeps `contact_mode=1` and the `tps` token; it does not install a Contact rewrite callback. TOPOS derives public Contact host, port, and transport from the selected Record-Route URI, so a UDP dialog now produces a direct-Service UDP/5060 Contact with the opaque `tps` parameter. TLS dialogs continue to produce the site-host TLS Contact. The outgoing-send callback only observes serialized traffic and does not modify messages.

TOPOS state uses a single site-local Dragonfly database and identical `serverid=topos` configuration on all Kamailio replicas; `event_mode=15` enables send and receive processing. The module's documented defaults retain unconfirmed branches for 180 seconds and confirmed dialogs for three hours, both longer than setup and typical calls. FreeSWITCH is one replica per site, so this chart's backend Service resolves to the same B2BUA that accepted the INVITE. An ACK can arrive at a different Kamailio pod over UDP; shared TOPOS state restores the hidden route and directs it to that same FreeSWITCH Service. This does not replicate transaction or FreeSWITCH dialog state and is not cross-site failover.

The chart's opt-in `sip.globalRouting.enabled` mode provides a global [Gateway API TLSRoute](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.TLSRoute) and K8GB DNS identity for new-call discovery. The Contact identity produced by Kamailio remains site-specific even in this mode; do not make established dialogs globally load balanced until dialog state and B2BUA recovery are actually shared across sites. K8GB DNS failover directs new dialog setup; it does not replicate Kamailio, FreeSWITCH, or RTPEngine live state across sites.

The public/private route pair is constructed once per direction with `record_route_preset()` and `r2=on`; `sockname_mode=1` associates its URIs with the named public and private sockets. TOPOS hides those Record-Routes externally and rewrites Contacts with the selected public host/port/transport or private service host plus its `tps` token. The in-dialog `loose_route_mode("1")` operation consumes the restored route. Carrier-facing in-dialog requests follow the socket encoded by that restored route; `TO_CARRIER` must not force TLS over a UDP/TCP route. A 2xx INVITE ACK is a separate transaction and is routed as a dialog request; it must never depend on `t_check_trans()`. RTPEngine's SDP rewriting is independent of this SIP topology. The service-host helpers default to chart Service names under injected `cluster.domain`; owning site values may override them with the certificate/DNS-backed cluster-scoped identities.

The `sips-tls` Gateway listener uses TLS passthrough to the Kamailio `TLSRoute`; it does not terminate the SIP TLS session. Envoy Gateway normally matches the route hostname against SNI. The fallback [EnvoyPatchPolicy](https://gateway.envoyproxy.io/docs/tasks/extensibility/envoy-patch-policy/) removes the `server_names` match from the one SIPS filter chain, allowing no-SNI TLS clients to reach that same TLSRoute without changing the backend or terminating TLS. This relies on the SIPS listener having one TLSRoute/backend; adding another SIPS route requires revisiting the fallback so it cannot route unrelated SNI traffic incorrectly. Envoy prepends PROXY protocol v2, which Kamailio consumes before its native TLS handshake. Kamailio presents its chart-managed cert-manager certificate; its SAN list includes the site hostname, shared SIP alias, and private Kamailio service name. `sip.tls.issuerName` must issue publicly trusted certificates for the public names. Verify the Kamailio `Certificate` is Ready and run the TLS verification below before testing Flowroute. The private hops remain Kamailio to FreeSWITCH on TLS 5061 at the Kamailio service's private port 5062 and FreeSWITCH to Asterisk on TLS 5061; Sofia verifies the Asterisk server certificate.

The voice DID is configured with `avoip.did` and normally bridges to Asterisk. The fax DID is configured separately with `fax.did`; it defaults to empty, so the owning ApplicationSet must supply the assigned fax number before enabling fax routing. Keep the two values distinct. A fax DID match runs before the voice and reject routes, transfers directly to `fax-receive`, answers, and executes `rxfax` to the persistent fax spool. Home1/YVR selects G.711-only PCMU reception through the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml). DC1/YXL retains the T.38-capable chart setting; T.38 reception there is reported working. The answered voice route runs `spandsp_start_fax_detect` to monitor CNG while the Asterisk voice call continues, and transfers detected fax calls to `fax-receive`. Automatic fax detection on the voice number is reported working. Call-specific traces and resulting TIFF evidence have not been recorded here. Temporary call recording is controlled separately by `freeswitch.media.diagnostics.callRecording.enabled`.

The previously observed five-second audio relay interruption is reported gone
after updating the FreeSWITCH Sofia SIP profiles. The profiles now set
`rtp-timer-name=soft` and `rtp-notimer-during-bridge=false` for the Asterisk,
external, and Kamailio legs in
[FreeSwitchSIPConfig.yaml](../templates/FreeSwitch/FreeSwitchSIPConfig.yaml).
This records the operator-observed result; a call-correlated RTP trace and
repeatable verification procedure are still needed for independent acceptance.

RTPEngine continues to advertise `rtpengine.media.address` in carrier SDP, independently of every SIP hostname. Its NG control Service and Valkey behavior are unchanged. RTPEngine HEP NG output uses Homer heplify's TCP port, while RTP remains on the existing UDP media range.

Validate a site render and the parser boundaries before GitOps reconciliation:

```sh
helm dependency build .
helm lint .
helm template core-home1-talos-prod-business-avoip-prod . -n core-prod -f values.yaml \
  --set cluster.type=spoke --set cluster.name=core-home1-talos-prod \
  --set cluster.domain=k8s.home1.resolvemy.host \
  --set datacenter=home1 --set region=yvr \
  --set-string kamailio.instances[0].name=carrier \
  --set-string kamailio.instances[0].role=carrier-sbc \
  --set kamailio.instances[0].enabled=true \
  --set kamailio.instances[0].replicas=3 \
  --set-string kamailio.instances[0].advertisedHost=sip.core-home1-talos-prod.home1.yvr.resolvemy.host \
  --set kamailio.instances[0].publicExposure.sip.udpEnabled=true \
  --set kamailio.instances[0].publicExposure.sip.directService.enabled=true \
  --set freeswitch.enabled=true --set asterisk.enabled=true \
  --set rtpengine.media.address=1.1.1.1 \
  --set-string avoip.did=voice-fixture --set-string fax.did=fax-fixture \
  > /tmp/avoip-render.yaml
python3 tests/sip_identity_render.py /tmp/avoip-render.yaml \
  --voice-did voice-fixture --fax-did fax-fixture \
  --site-host sip.core-home1-talos-prod.home1.yvr.resolvemy.host \
  --cluster-name core-home1-talos-prod \
  --cluster-domain k8s.home1.resolvemy.host --media-address 1.1.1.1
```

Set `SITE_SIP_HOST` to the current site route (for example, `sip.core-home1-talos-prod.home1.yvr.resolvemy.host` or `sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host`). For the carrier-side DNS and TLS checks, run:

```sh
dig +short "$SITE_SIP_HOST" A
dig +short "$SITE_SIP_HOST" AAAA
dig +short SRV _sips._tcp.us-west-or.sip.flowroute.com

openssl s_client \
  -connect "$SITE_SIP_HOST":5061 \
  -servername "$SITE_SIP_HOST" -verify_hostname "$SITE_SIP_HOST" \
  -verify_return_error </dev/null 2>/dev/null |
openssl x509 -noout -subject -issuer -ext subjectAltName

# Repeat without SNI; TLS must still reach Kamailio and validate its certificate.
openssl s_client \
  -connect "$SITE_SIP_HOST":5061 -noservername \
  -verify_hostname "$SITE_SIP_HOST" -verify_return_error \
  -brief </dev/null
```

The SRV result must remain the Flowroute SIPS service on TLS port 5061. The
certificate output must contain a SAN covering the selected site's hostname.

During the home1 ingress test, capture the Flowroute TCP peer on the home1
ingress node or host interface:

```sh
sudo tcpdump -ni any -tttt -vv \
  'tcp port 5061 and (host 34.210.91.112 or host 34.210.91.114)'
```

This shows TCP connection reuse or reconnection and packet direction, not SIP
message types. TCP ACK flags are not SIP ACK requests. Because SIP remains
encrypted on the wire, confirm application-layer INVITE/200/ACK in Kamailio
logs or Homer HEP after TLS is accepted by Kamailio.

After a reviewed GitOps rollout, place an inbound Flowroute call and keep it answered for at
least 60 seconds. Capture the Call-ID in Homer and verify this sequence:

```text
Flowroute -> Kamailio       INVITE
Kamailio -> FreeSWITCH      INVITE
FreeSWITCH -> Kamailio      200 OK
Kamailio -> Flowroute       200 OK
Flowroute -> Kamailio       ACK
Kamailio -> FreeSWITCH      ACK
```

Confirm the ACK has the same Call-ID and dialog tags as the answered INVITE,
and that the TOPOS Contact token restores its dialog path across the public
and private legs. There must be no repeated 200 OK after that ACK
reaches FreeSWITCH, no `ACK Timeout` in FreeSWITCH logs, and no
`Reason: SIP;cause=408;text="ACK Timeout"` BYE. End the call manually and
confirm a normal BYE/200 exchange. Then run one inbound fax test and explicitly
verify its SIP ACK in Homer; a fax completing in under 32 seconds is not proof
of this signaling fix.

For temporary dialog diagnostics, set
`kamailio.defaults.sipLogging.diagnostics.enabled=true`. The request marker includes
Call-ID, method, CSeq, From/To tags, source, receive socket/protocol,
Request-URI, and top Route. The routing decision records the next hop and
socket name; the serialized send marker records selected send protocol/socket
and destination IP/port.
Disable the switch after the capture to avoid persistent per-request
diagnostic logging. Home1 UDP ingress should show `proto=udp` and `recv=...:5060`;
a separate genuine TLS call should show `proto=tls` and `recv=...:5061`.
Filter logs from every Kamailio replica using the test Call-ID:

```sh
CALL_ID='<captured-call-id>'
kubectl --context logged-user -n core-prod logs \
  -l app=core-home1-talos-prod-business-avoip-prod-avoip-kamailio \
  -c kamailio --max-log-requests=10 --prefix --since=10m | rg -F "$CALL_ID"
kubectl --context logged-user -n core-prod logs \
  deploy/core-home1-talos-prod-business-avoip-prod-avoip-freeswitch \
  -c freeswitch --since=10m | rg -F "$CALL_ID"
```

Homer shows the SIP dialog after Kamailio decrypts TLS; use it to confirm both
ACK hops and matching dialog tags. The log commands help correlate the Call-ID.
Check that `Certificate` resources are Ready and that the public answer keeps
the same RTPEngine media address across retransmissions. Verify the internal
TLS listeners and certificate SANs with `openssl s_client`,
`sofia status profile kamailio`, `sofia status profile asterisk`, and
`pjsip show transports`.

For voice, call `avoip.did` and confirm a bridge to Asterisk without `rxfax`.
For fax, call `fax.did` and confirm `rxfax`, a result log, and a TIFF under
`freeswitch.fax.spoolPath` without an Asterisk bridge. Compare RTPEngine packet
counts in both directions and verify Homer receives RTPEngine HEP on TCP 9061.

The UDP and TLS SIPp scenarios, including steering the UDP dialog ACK and BYE
to another Kamailio replica, are documented in [tests/README.md](../tests/README.md).
Collect the Call-ID across all Kamailio pods with the command above, including
the initial public receive and the other replica's TOPOS/loose-route and
private-backend send, as well as FreeSWITCH.

Acceptance requires the successful-answer ACK at FreeSWITCH, no repeated 200
after that ACK and no `ACK Timeout`, an answered call lasting beyond 60 seconds,
and a normal BYE/200 exchange in both directions. Fax completion and a received
TIFF are a separate acceptance check. Rendered manifests and test fixtures are
not live verification. Rollback is a reviewed Git revert followed by the
normal scoped Argo CD sync; do not manually edit or apply production resources.
Existing calls keep their established Contact and route set, so verify rollback
with a fresh dialog.
