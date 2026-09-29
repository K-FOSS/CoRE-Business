# Kamailio reply regression

## SIP identity render regression

Render with representative values from the active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
then run the YAML, Kamailio identity, private-service, Contact, RTPEngine,
TLS, DID, and Asterisk Echo greeting checks:

```sh
helm lint .
helm template avoip . -n core-prod -f values.yaml \
  --set cluster.type=hub \
  --set cluster.name=core-dc1-talos-prod \
  --set cluster.domain=k3s.dc1.resolvemy.host \
  --set asterisk.enabled=true \
  --set freeswitch.enabled=true \
  --set kamailio.advertisedHost=sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host \
  --set rtpengine.media.address=66.165.222.103 \
  --set-string avoip.did=voice-fixture \
  --set-string fax.did=fax-fixture > /tmp/avoip-render.yaml
python3 tests/sip_identity_render.py /tmp/avoip-render.yaml \
  --voice-did voice-fixture --fax-did fax-fixture \
  --site-host sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host \
  --cluster-name core-dc1-talos-prod \
  --cluster-domain k3s.dc1.resolvemy.host
```

The route identities in this example are non-numeric render fixtures, not
production DIDs or deployment values.

For Home1/YVR's native TLS mode, also set
`kamailio.publicExposure.sip.tlsPassthrough=true` and pass `--native-tls` to
the render test. The matching shared Gateway listener is configured by the
[Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml);
both layers must reconcile before live calls use passthrough. DC1/YXL stays in
termination mode unless its site values opt in.

`kamailio_reply_retransmissions.py` runs a separate instance of the deployed
Kamailio binary with the rendered chart configuration. It substitutes loopback
listeners, a local SIP backend, an authorized loopback caller and a mock
RTPEngine NG endpoint. It does not change the production process or place calls.
It requires the chart's `kamailio` and Python-capable `netshoot` containers.

Render with the current `LOVELY_HELM_MERGE` from the owning
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
then extract the configuration:

```sh
helm template avoip . -n core-prod -f /tmp/avoip-site-values.yaml > /tmp/avoip-render.yaml
yq -r 'select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-config"))) | .data."kamailio.cfg"' /tmp/avoip-render.yaml > /tmp/avoip-kamailio.cfg
python3 tests/kamailio_reply_retransmissions.py \
  --config /tmp/avoip-kamailio.cfg \
  --context core-dc1-talos-prod \
  --namespace core-prod \
  --deployment core-dc1-talos-prod-business-avoip-prod-avoip-kamailio \
  --public-host sip.core-dc1-talos-prod.dc1.yxl.resolvemy.host
```

The fixture sends an initial SDP offer and repeats the same backend `200 OK`
immediately and after transaction expiry. It checks that FreeSWITCH receives
both Record-Route values while the caller receives only the configured site's
public route, and sends a 2xx ACK with that route to verify it reaches the backend
through `loose_route()`. It also checks the bytes received by the caller,
including Content-Length framing: every answer must have the same public
connection address, allocated media port and complete body. It then injects an
NG answer failure and checks that the final response is dropped. The mock's
public address and port are test constants, not allocated live media.

Temporary listeners bind only to `127.0.0.1` on TCP 15061, 15062 and 16061,
and UDP 12223. Do not run multiple copies in one pod concurrently. The runner
stops its separate Kamailio process and removes its temporary configuration;
it writes the test process log next to the input configuration as `.test.log`.
Repeat with SIP logging disabled to check that logging does not control media
rewriting. A production carrier capture or live fax remains necessary to verify
provider interoperability and actual RTP/UDPTL delivery.
