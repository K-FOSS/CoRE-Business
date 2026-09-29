# AVoIP SIP identity and dedicated fax routing

The active deployment owner is Backplane's [legacy AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml). Its Lovely merge supplies the cluster name, site, DNS domain, component enablement, DIDs, and egress policy. Render with those injected values before reconciliation.

`sip.siteHost` is the site-specific public SIP identity, supplied through `kamailio.advertisedHost` or derived as `sip.<cluster>.<datacenter>.<region>.resolvemy.host`. Kamailio advertises this hostname on its public listener, uses it for the public side of its existing two-sided Record-Route set, and rewrites successful public Contacts to `sips:<user>@<siteHost>:5061;transport=tls`. FreeSWITCH also uses the same site hostname as its external SIP identity. This pins each dialog to the site that accepted it, so Flowroute's YVR-primary/YXL-failover routing applies to new calls while in-dialog ACK, BYE, UPDATE, and re-INVITE requests return to the originating site. Both sites may be configured with the same DIDs; keep each site's value in its own deployment secret/value injection and do not commit a DID literal. Site affinity does not replicate live dialogs between independent sites, so failover applies to new call setup, not an already established call.

The private side remains the Kamailio Kubernetes Service FQDN on TLS 5062, leading to FreeSWITCH's private TLS Service on 5061. FreeSWITCH receives both Record-Route values so it retains the private traversal route. In Kamailio's core reply route, `remove_hf_idx("Record-Route", "0")` removes the private first header before the reply is sent to Flowroute; the carrier receives only `sips:<siteHost>:5061;transport=tls`. After `loose_route()` handles the public route, the configured Flowroute source CIDRs direct carrier-originated in-dialog methods to the private FreeSWITCH TLS service. The 2xx ACK uses this same standard route path. The preserved Contact user and site-specific hostname affect SIP signaling only; they do not alter SDP or RTPEngine's public media address. `sip.globalHost` remains an optional shared DNS alias, not the advertised dialog identity. `kamailio.sip.serviceHost`, `freeswitch.sip.serviceHost`, and `asterisk.sip.serviceHost` default to the chart Service names under the injected `cluster.domain`. Their ClusterIP Services carry both current and legacy ExternalDNS hostname annotations, `wan-mode: public` for Backplane's DNS selector, and `lan-mode: private`, following Backplane's [PSQL Service](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Databases/PSQL/templates/PSQL-Core/Service.yaml) and [mail Service](https://github.com/K-FOSS/CoRE-Business/blob/main/Mail/templates/common.yaml). Backplane's ExternalDNS has `publishInternalServices: true`, so these records publish the private Service IPs in actual DNS; the labels do not create a public network listener. Override a service host only if its DNS record resolves to that Service.

The Gateway terminates public SIP TLS on `tls-sip`. The selected site's hostname must resolve to that site's intended SIP ingress, and the certificate presented on port 5061 must include that hostname in its SANs and validate when SNI is the same site hostname. Check the certificate attached to each site's Gateway. The chart requests separate publicly trusted [cert-manager Certificates](https://cert-manager.io/docs/usage/certificate/) for the Kamailio, FreeSWITCH, and Asterisk service names from `sip.tls.issuerName`. The private hops are Kamailio to FreeSWITCH on TLS 5061 and FreeSWITCH to Asterisk on TLS 5061. The FreeSWITCH Sofia gateway checks the Asterisk server certificate against the outbound hostname. Verify certificate readiness and the actual SAN/SNI at each internal hop before sending production traffic.

The voice DID is configured with `avoip.did` and only bridges to Asterisk. The fax DID is configured separately with `fax.did`; it defaults to empty, so the owning ApplicationSet must supply the assigned fax number before enabling fax routing. Keep the two values distinct. A fax DID match runs before the voice and reject routes, transfers directly to `fax-receive`, answers, and executes `rxfax` to the persistent fax spool. Fax T.38, PCMU/PCMA, ECM, and V.17 settings stay on that extension. The voice route has no fax detector or fax recording.

RTPEngine continues to advertise `rtpengine.media.address` in carrier SDP, independently of every SIP hostname. Its NG control Service and Valkey behavior are unchanged. RTPEngine HEP NG output uses Homer heplify's TCP port, while RTP remains on the existing UDP media range.

Validate a site render and the parser boundaries before GitOps reconciliation:

```sh
helm dependency build .
helm lint .
helm template avoip . -n core-prod -f values.yaml \
  --set cluster.type=hub --set cluster.name=core-dc1-talos-prod \
  --set cluster.domain=k3s.dc1.resolvemy.host \
  --set freeswitch.enabled=true --set asterisk.enabled=true \
  --set-string fax.did="$FAX_DID" > /tmp/avoip-render.yaml
python3 tests/sip_identity_render.py /tmp/avoip-render.yaml \
  --voice-did "$VOICE_DID" --fax-did "$FAX_DID" \
  --site-host "sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host" \
  --cluster-domain 'k3s.dc1.resolvemy.host'
```

Set `SITE_SIP_HOST` to the current site route (for example, `sip.core-home1-talos-prod.home1.yvr.resolvemy.host` or `sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host`). For the carrier-side DNS and TLS checks, run:

```sh
dig +short "$SITE_SIP_HOST" A
dig +short "$SITE_SIP_HOST" AAAA
dig +short SRV _sips._tcp.us-west-or.sip.flowroute.com

openssl s_client \
  -connect "$SITE_SIP_HOST":5061 \
  -servername "$SITE_SIP_HOST" </dev/null 2>/dev/null |
openssl x509 -noout -subject -issuer -ext subjectAltName
```

The SRV result must remain the Flowroute SIPS service on TLS port 5061. The
certificate output must contain a SAN covering the selected site's hostname.

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

For temporary ACK diagnostics, set
`kamailio.sipLogging.diagnostics.enabled=true`. The dialog-ACK marker includes
Call-ID, From/To tags, source, receive socket, Request-URI and top Route URI;
the serialized send marker records the selected send socket and destination.
Disable the switch after the capture to avoid persistent per-request
diagnostic logging. On the hub, filter logs for a captured Call-ID with:

```sh
CALL_ID='4497330266-3999635533-138994037@IRISMSC8.iristel.net'
kubectl --context core-dc1-talos-prod -n core-prod logs \
  deploy/core-dc1-talos-prod-business-avoip-prod-avoip-kamailio \
  -c kamailio --since=10m | rg -F "$CALL_ID"
kubectl --context core-dc1-talos-prod -n core-prod logs \
  deploy/core-dc1-talos-prod-business-avoip-prod-avoip-freeswitch \
  -c freeswitch --since=10m | rg -F "$CALL_ID"
```

Use Homer to confirm both ACK hops and the dialog tags, then check FreeSWITCH
logs for the absence of `ACK Timeout`. These log commands are correlation
helpers; the Homer packet sequence is the proof that the ACK reached the UAS.

After Argo CD reconciles the published chart and the Backplane value change, confirm the `Certificate` resources are Ready, then compare one inbound Call-ID in Kamailio, FreeSWITCH, Asterisk, RTPEngine, and Homer. Check the public `200 OK` and its retransmissions for the same RTPEngine media address and port, and verify the ACK reaches FreeSWITCH. Use `openssl s_client -connect <service-fqdn>:5061 -servername <service-fqdn> -verify_hostname <service-fqdn>` from a diagnostic pod on each internal hop. Check the SAN on each mounted certificate, rather than accepting a successful TLS handshake alone. Inspect `sofia status profile kamailio`, `sofia status profile asterisk`, and `pjsip show transports` for the TLS listeners.

For voice, call `avoip.did` and confirm FreeSWITCH logs a bridge to Asterisk with no `fax_detect`, `rxfax`, T.38 variables, or fax recording. For fax, call the configured `fax.did` and confirm `fax receive start`, `rxfax`, a fax result log, and a TIFF under `freeswitch.fax.spoolPath`, with no Asterisk bridge. Compare RTPEngine packet counts in both directions and verify Homer receives RTPEngine HEP on TCP 9061. Confirm the three SIP service records resolve to their ClusterIP addresses and their Certificates are Ready before placing calls.
