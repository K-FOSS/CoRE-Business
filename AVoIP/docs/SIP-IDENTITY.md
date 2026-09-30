# AVoIP SIP identity and dedicated fax routing

Kamailio applies [symmetric response routing](https://www.kamailio.org/wikidocs/cookbooks/6.1.x/core/#force_rport) to authorized Flowroute requests. Flowroute can originate an INVITE from an ephemeral TLS port while its Via advertises 5061 without `rport`; responses must use the received port so the inbound Envoy/PROXY-protocol TLS connection can be reused. New in-dialog requests, such as FreeSWITCH's BYE, still target Flowroute's public port 5061.

The active chart owner is Backplane's [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml), which supplies cluster identity, component enablement, site SIP hostname, DIDs, and egress policy. The separate [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml) configures the shared Gateway listener and its SIPS fallback. Home1/YVR and DC1/YXL use TLSRoute on port 5061; Kamailio owns the TLS session. An EnvoyPatchPolicy makes the SIPS filter chain a fallback for clients that omit SNI. Render both injected value layers before reconciliation.

By default, `sip.siteHost` is the site-specific public SIP identity, supplied through `kamailio.advertisedHost` or derived as `sip.<cluster>.<datacenter>.<region>.resolvemy.host`. Kamailio advertises this hostname on its public listener, uses it for the public side of its existing two-sided Record-Route set, and rewrites successful public Contacts to `sips:<user>@<siteHost>:5061;transport=tls`. FreeSWITCH also uses the same site hostname as its external SIP identity. This pins each dialog to the site that accepted it, so Flowroute's YVR-primary/YXL-failover routing applies to new calls while in-dialog ACK, BYE, UPDATE, and re-INVITE requests return to the originating site. Both sites may be configured with the same DIDs; keep each site's value in its own deployment secret/value injection and do not commit a DID literal. Site affinity does not replicate live dialogs between independent sites, so failover applies to new call setup, not an already established call.

The chart's opt-in `sip.globalRouting.enabled` mode adds a separate global [Gateway API TLSRoute](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.TLSRoute) and a K8GB [`Gslb`](https://www.k8gb.io/latest/resource_ref/) referencing only that route, plus a [`ZoneDelegation`](https://www.k8gb.io/latest/dynamic_zones/) for `sip.resolvemy.host`. The existing site `TLSRoute` stays site-specific; the global route targets the same Kamailio Service. Kamailio uses the global hostname for its public listener advertisement, public Record-Route, and public Contact rewrite. The site-local hostname remains published for site-specific operations, but a carrier-side direct-site fallback is not dialog-safe when the response advertises the global route: subsequent requests resolve through K8GB and must return to the site that accepted the call. Keep Flowroute on the global target unless the failover configuration also guarantees the global route resolves to the site handling that call. Set `sip.globalRouting.primaryGeoTag` to the same primary geotag in both site's injected Helm values (`home1` for YVR-primary/YXL-failover). K8GB mode is disabled by default because its active Backplane installation currently has no `Gslb`/`ZoneDelegation` resources and public DNS delegation/provider setup is not complete. Do not enable it until that DNS path is ready and verified; see the [Backplane Global Network deployment notes](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Network/Global/README.md). K8GB DNS failover directs new dialog setup; it does not replicate Kamailio, FreeSWITCH, or RTPEngine live state across sites.

The private side remains the Kamailio Kubernetes Service FQDN on TLS 5062, leading to FreeSWITCH's private TLS Service on 5061. FreeSWITCH receives both Record-Route values so it retains the private traversal route. In Kamailio's core reply route, `remove_hf_idx("Record-Route", "0")` removes the private first header before the reply is sent to Flowroute; the carrier receives only `sips:<publicSipHost>:5061;transport=tls`, where `publicSipHost` is the site identity by default and the global identity in K8GB mode. After `loose_route()` handles the public route, the configured Flowroute source CIDRs direct carrier-originated in-dialog methods to the private FreeSWITCH TLS service. The 2xx ACK uses this same standard route path. The preserved Contact user and public hostname affect SIP signaling only; they do not alter SDP or RTPEngine's public media address. `sip.globalHost` is a DNS alias in the default mode and becomes the advertised dialog identity only when global routing is enabled. `kamailio.sip.serviceHost`, `freeswitch.sip.serviceHost`, and `asterisk.sip.serviceHost` default to the chart Service names under the injected `cluster.domain`. Their ClusterIP Services carry both current and legacy ExternalDNS hostname annotations, `wan-mode: public` for Backplane's DNS selector, and `lan-mode: private`, following Backplane's [PSQL Service](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Databases/PSQL/templates/PSQL-Core/Service.yaml) and [mail Service](https://github.com/K-FOSS/CoRE-Business/blob/main/Mail/templates/common.yaml). Backplane's ExternalDNS has `publishInternalServices: true`, so these records publish the private Service IPs in actual DNS; the labels do not create a public network listener. Override a service host only if its DNS record resolves to that Service.

The `sips-tls` Gateway listener uses TLS passthrough to the Kamailio `TLSRoute`; it does not terminate the SIP TLS session. Envoy Gateway normally matches the route hostname against SNI. The fallback [EnvoyPatchPolicy](https://gateway.envoyproxy.io/docs/tasks/extensibility/envoy-patch-policy/) removes the `server_names` match from the one SIPS filter chain, allowing no-SNI TLS clients to reach that same TLSRoute without changing the backend or terminating TLS. This relies on the SIPS listener having one TLSRoute/backend; adding another SIPS route requires revisiting the fallback so it cannot route unrelated SNI traffic incorrectly. Envoy prepends PROXY protocol v2, which Kamailio consumes before its native TLS handshake. Kamailio presents its chart-managed cert-manager certificate; its SAN list includes the site hostname, shared SIP alias, and private Kamailio service name. `sip.tls.issuerName` must issue publicly trusted certificates for the public names. Verify the Kamailio `Certificate` is Ready and run the TLS verification below before testing Flowroute. The private hops remain Kamailio to FreeSWITCH on TLS 5061 at the Kamailio service's private port 5062 and FreeSWITCH to Asterisk on TLS 5061; Sofia verifies the Asterisk server certificate.

The voice DID is configured with `avoip.did` and only bridges to Asterisk. The fax DID is configured separately with `fax.did`; it defaults to empty, so the owning ApplicationSet must supply the assigned fax number before enabling fax routing. Keep the two values distinct. A fax DID match runs before the voice and reject routes, transfers directly to `fax-receive`, answers, and executes `rxfax` to the persistent fax spool. Fax T.38, PCMU/PCMA, ECM, and V.17 settings stay on that extension. The voice route has no fax detector or fax recording.

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
  --cluster-domain k8s.home1.resolvemy.host --media-address 24.86.197.63 \
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
and that Kamailio processes it through `loose_route()` using the private Route
entry to reach FreeSWITCH. There must be no repeated 200 OK after that ACK
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

Use Homer to confirm both ACK hops and the dialog tags, then check FreeSWITCH
logs for the absence of `ACK Timeout`. These log commands are correlation
helpers; the Homer packet sequence is the proof that the ACK reached the UAS.

After Argo CD reconciles the published chart and the Backplane value change, confirm the `Certificate` resources are Ready, then compare one inbound Call-ID in Kamailio, FreeSWITCH, Asterisk, RTPEngine, and Homer. Check the public `200 OK` and its retransmissions for the same RTPEngine media address and port, and verify the ACK reaches FreeSWITCH. Use `openssl s_client -connect <service-fqdn>:5061 -servername <service-fqdn> -verify_hostname <service-fqdn>` from a diagnostic pod on each internal hop. Check the SAN on each mounted certificate, rather than accepting a successful TLS handshake alone. Inspect `sofia status profile kamailio`, `sofia status profile asterisk`, and `pjsip show transports` for the TLS listeners.

For voice, call `avoip.did` and confirm FreeSWITCH logs a bridge to Asterisk with no `fax_detect`, `rxfax`, T.38 variables, or fax recording. For fax, call the configured `fax.did` and confirm `fax receive start`, `rxfax`, a fax result log, and a TIFF under `freeswitch.fax.spoolPath`, with no Asterisk bridge. Compare RTPEngine packet counts in both directions and verify Homer receives RTPEngine HEP on TCP 9061. Confirm the three SIP service records resolve to their ClusterIP addresses and their Certificates are Ready before placing calls.
