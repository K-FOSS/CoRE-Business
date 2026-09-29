# AVoIP SIP identity and dedicated fax routing

The active deployment owner is Backplane's [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml). Its Lovely merge supplies the cluster name, site, DNS domain, component enablement, DIDs, and egress policy. Render with those injected values before reconciliation.

`sip.globalHost` defaults to `sip.resolvemy.host`, the public rendezvous name. `sip.siteHost` defaults to `sip.<cluster>.<datacenter>.<region>.resolvemy.host`; Kamailio advertises this site name in the public Via and Record-Route so established dialogs remain at the handling site. Kamailio's private Record-Route uses its stable Kubernetes Service FQDN. `kamailio.sip.serviceHost`, `freeswitch.sip.serviceHost`, and `asterisk.sip.serviceHost` default to the chart Service names under the injected `cluster.domain`. Their ClusterIP Services carry both current and legacy ExternalDNS hostname annotations, `wan-mode: public` for Backplane's DNS selector, and `lan-mode: private`, following Backplane's [PSQL Service](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Databases/PSQL/templates/PSQL-Core/Service.yaml) and [mail Service](https://github.com/K-FOSS/CoRE-Business/blob/main/Mail/templates/common.yaml). Backplane's ExternalDNS has `publishInternalServices: true`, so these records publish the private Service IPs in actual DNS; the labels do not create a public network listener. Override a service host only if its DNS record resolves to that Service.

The Gateway terminates public SIP TLS using Backplane's [site certificate](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Network/TLS/Certificates/templates/ResolveMyHost.yaml). That certificate covers the site SIP name. Its published SAN set does not cover the private Service FQDNs. The chart therefore requests separate publicly trusted [cert-manager Certificates](https://cert-manager.io/docs/usage/certificate/) for the Kamailio, FreeSWITCH, and Asterisk service names from `sip.tls.issuerName`. The private hops are Kamailio to FreeSWITCH on TLS 5061 and FreeSWITCH to Asterisk on TLS 5061. The FreeSWITCH Sofia gateway checks the Asterisk server certificate against the outbound hostname. Verify certificate readiness and the actual SAN/SNI at each hop before sending production traffic.

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

After Argo CD reconciles the published chart and the Backplane value change, confirm the `Certificate` resources are Ready, then compare one inbound Call-ID in Kamailio, FreeSWITCH, Asterisk, RTPEngine, and Homer. Check the public `200 OK` and its retransmissions for the same RTPEngine media address and port, and verify the ACK reaches FreeSWITCH. Use `openssl s_client -connect <service-fqdn>:5061 -servername <service-fqdn> -verify_hostname <service-fqdn>` from a diagnostic pod on each internal hop. Check the SAN on each mounted certificate, rather than accepting a successful TLS handshake alone. Inspect `sofia status profile kamailio`, `sofia status profile asterisk`, and `pjsip show transports` for the TLS listeners.

For voice, call `avoip.did` and confirm FreeSWITCH logs a bridge to Asterisk with no `fax_detect`, `rxfax`, T.38 variables, or fax recording. For fax, call the configured `fax.did` and confirm `fax receive start`, `rxfax`, a fax result log, and a TIFF under `freeswitch.fax.spoolPath`, with no Asterisk bridge. Compare RTPEngine packet counts in both directions and verify Homer receives RTPEngine HEP on TCP 9061. Confirm the three SIP service records resolve to their ClusterIP addresses and their Certificates are Ready before placing calls.
