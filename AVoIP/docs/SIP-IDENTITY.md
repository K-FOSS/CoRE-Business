# AVoIP SIP identity and dedicated fax routing

The active chart owner is Backplane's [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml), which supplies cluster identity, component enablement, site SIP hostname, DIDs, and egress policy. The separate [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml) configures the shared Gateway listener and its SIPS fallback. Home1/YVR and DC1/YXL use TLSRoute on port 5061; Kamailio owns the TLS session. An EnvoyPatchPolicy makes the SIPS filter chain a fallback for clients that omit SNI. Render both injected value layers before reconciliation.

## Signaling and media paths

| Traffic | Path | Carrier-facing identity at the hub |
| --- | --- | --- |
| Inbound INVITE and its reply | Flowroute ↔ Envoy TLS passthrough ↔ Kamailio | Site SIP hostname on port 5061 |
| New outbound request, such as FreeSWITCH's BYE | Kamailio → VyOS WAN-GW/NAT VRRP pair → Flowroute | `66.165.222.97` observed on the BYE transaction |
| RTP | Flowroute ↔ RTPEngine | `66.165.222.103` advertised in SDP |

The VyOS routers [source NAT](https://docs.vyos.io/en/latest/configuration/nat/nat44.html#source-nat) new outbound connections to their shared VRRP address. The observed outbound BYE and its successful response establish that this egress path works; they do not establish that the original INVITE answer reached Flowroute.

Flowroute can send an INVITE from an ephemeral TLS source port while its Via advertises 5061 without `rport`. The chart configures [`force_rport()`](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#force_rport) for authorized carrier requests so the answer targets the received port and can reuse the inbound Envoy/PROXY-protocol connection. New outbound requests still target Flowroute's port 5061. Confirm the resulting connection choice and ACK with a live call; the address logged at Kamailio's send boundary alone does not prove delivery.

By default, `sip.siteHost` is the site-specific public SIP identity, supplied through `kamailio.advertisedHost` or derived as `sip.<cluster>.<datacenter>.<region>.resolvemy.host`. Kamailio advertises this identity for carrier-facing established dialogs and uses the private Kamailio Service FQDN on the backend-facing side. TOPOS `contact_mode=1` keeps the meaningful Contact user and places its opaque state key in `;tps=...`. TOPOS strips the paired Record-Route headers from both peers and restores dialog routing from shared site-local Dragonfly state. FreeSWITCH does not use the public carrier identity. This pins each dialog to the site that accepted it; Dragonfly sharing is per site, not cross-site, and does not replicate FreeSWITCH B2BUA state.

The chart's opt-in `sip.globalRouting.enabled` mode provides a global [Gateway API TLSRoute](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.TLSRoute) and K8GB DNS identity for new-call discovery. The Contact identity produced by Kamailio remains site-specific even in this mode; do not make established dialogs globally load balanced until dialog state and B2BUA recovery are actually shared across sites. K8GB DNS failover directs new dialog setup; it does not replicate Kamailio, FreeSWITCH, or RTPEngine live state across sites.

The public/private route pair is constructed once per direction with `record_route_preset()` and `r2=on`; `sockname_mode=1` associates its URIs with the named TLS sockets. TOPOS hides those Record-Routes externally and rewrites Contacts with the appropriate public site or private service host plus its `tps` token. One `loose_route_mode("1")` operation handles the paired route after TOPOS restoration. A 2xx INVITE ACK is a separate transaction and is routed as a dialog request; it must never depend on `t_check_trans()`. RTPEngine's SDP rewriting is independent of this SIP topology. The service-host helpers default to chart Service names under injected `cluster.domain`; owning site values may override them with the certificate/DNS-backed cluster-scoped identities.

The `sips-tls` Gateway listener uses TLS passthrough to the Kamailio `TLSRoute`; it does not terminate the SIP TLS session. Envoy Gateway normally matches the route hostname against SNI. The fallback [EnvoyPatchPolicy](https://gateway.envoyproxy.io/docs/tasks/extensibility/envoy-patch-policy/) removes the `server_names` match from the one SIPS filter chain, allowing no-SNI TLS clients to reach that same TLSRoute without changing the backend or terminating TLS. This relies on the SIPS listener having one TLSRoute/backend; adding another SIPS route requires revisiting the fallback so it cannot route unrelated SNI traffic incorrectly. Envoy prepends PROXY protocol v2, which Kamailio consumes before its native TLS handshake. Kamailio presents its chart-managed cert-manager certificate; its SAN list includes the site hostname, shared SIP alias, and private Kamailio service name. `sip.tls.issuerName` must issue publicly trusted certificates for the public names. Verify the Kamailio `Certificate` is Ready and run the TLS verification below before testing Flowroute. The private hops remain Kamailio to FreeSWITCH on TLS 5061 at the Kamailio service's private port 5062 and FreeSWITCH to Asterisk on TLS 5061; Sofia verifies the Asterisk server certificate.

The voice DID is configured with `avoip.did` and only bridges to Asterisk. The fax DID is configured separately with `fax.did`; it defaults to empty, so the owning ApplicationSet must supply the assigned fax number before enabling fax routing. Keep the two values distinct. A fax DID match runs before the voice and reject routes, transfers directly to `fax-receive`, answers, and executes `rxfax` to the persistent fax spool. Fax T.38, PCMU/PCMA, ECM, and V.17 settings stay on that extension. The voice route has no fax detector; temporary call recording is controlled separately by `freeswitch.media.diagnostics.callRecording.enabled`.

RTPEngine continues to advertise `rtpengine.media.address` in carrier SDP, independently of every SIP hostname. Its NG control Service and Valkey behavior are unchanged. RTPEngine HEP NG output uses Homer heplify's TCP port, while RTP remains on the existing UDP media range.

Validate a site render and the parser boundaries before GitOps reconciliation:

```sh
helm dependency build .
helm lint .
helm template core-home1-talos-prod-business-avoip-prod . -n core-prod -f values.yaml \
  --set cluster.type=spoke --set cluster.name=core-home1-talos-prod \
  --set cluster.domain=k8s.home1.resolvemy.host \
  --set datacenter=home1 --set region=yvr \
  --set kamailio.advertisedHost=sip.core-home1-talos-prod.home1.yvr.resolvemy.host \
  --set freeswitch.enabled=true --set asterisk.enabled=true \
  --set rtpengine.media.address=24.86.197.63 \
  --set-string avoip.did=voice-fixture --set-string fax.did=fax-fixture \
  > /tmp/avoip-render.yaml
python3 tests/sip_identity_render.py /tmp/avoip-render.yaml \
  --voice-did voice-fixture --fax-did fax-fixture \
  --site-host sip.core-home1-talos-prod.home1.yvr.resolvemy.host \
  --cluster-name core-home1-talos-prod \
  --cluster-domain k8s.home1.resolvemy.host --media-address 24.86.197.63
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

After deployment, place an inbound Flowroute call and keep it answered for at
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
`kamailio.sipLogging.diagnostics.enabled=true`. The request marker includes
Call-ID, method, CSeq, From/To tags, source, receive socket/protocol,
Request-URI, and top Route. The routing decision records the next hop and
socket name; the serialized send marker records selected send protocol/socket
and destination IP/port. Home1 public ingress should show `proto=tls` and
`recv=...:5061`.
Disable the switch after the capture to avoid persistent per-request
diagnostic logging. On home1, filter logs using the test Call-ID with:

```sh
CALL_ID='<captured-call-id>'
kubectl --context logged-user -n core-prod logs \
  deploy/core-home1-talos-prod-business-avoip-prod-avoip-kamailio \
  -c kamailio --since=10m | rg -F "$CALL_ID"
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
