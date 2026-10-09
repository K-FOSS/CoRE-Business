# AVoIP render checks

Run the WSS edge rendering checks from the repository root:

```sh
helm lint AVoIP
AVoIP/tests/wss-ha-render.sh
```

The WSS test renders both a selected three-replica tier and a separate staged
pilot. It checks the headless owner Service, stable StatefulSet identity,
two-pod disruption floor, existing Envoy backend Service and `/ws` contract,
Path module/configuration, Asterisk `support_path=yes`, legacy proxy omission,
gateway timeout values, TLS SAN, and invalid timeout rejection. It does not
exercise live Path routing, the custom Asterisk runtime image, WSS connection
draining, Envoy distribution, or RTP.

The working tree provided for this implementation does not contain the
previously referenced `kamailio-instances.sh`,
`asterisk-sipcore-render.sh`, `sip-security-render.sh`, or
`sip-registrar-render.sh` scripts. Verify their current tracked status before
using older runbook commands; they were not replaced by this focused test.

Before activation, validate the generated configuration with the pinned
Kamailio image and validate generated PJSIP with the deployed Asterisk image.
Then execute every live acceptance step in
[SIP Stateful HA](../docs/SIP-STATEFUL-HA.md#operational-inspection-and-live-acceptance).

## Home Assistant LF-only heartbeat regression

The [Forgejo workflow](../../.forgejo/workflows/kamailio-lf-heartbeat.yaml)
builds its separate test target, runs the regression against that image, then
builds and publishes the production `runtime` target to the Forgejo registry
on `main`. Test-only SIP configs stay out of the runtime image. Use the digest
reported in the successful run before enabling the chart option; do not guess
an image digest.

Run the self-contained integration runner against the published image with a
local Docker-compatible engine:

```sh
AVoIP/image/kamailio-lf-heartbeat/run-integration.sh \
  registry.example/kamailio-lf-heartbeat:6.1.4-buildtag podman
```

The runner starts the same image once with compatibility enabled and once
with the module parameter disabled. The enabled run exercises repeated exact
LF/LF, fragmented LF/LF, valid OPTIONS, standard CRLF keepalive, Ping/Pong,
and a different malformed payload. It must run against the locally built
image, not stock Kamailio. Render the site's actual `internal-wss` Helm values
and run
`kamailio -c` from the same image before publishing the digest. Live YVR
stability, registration refresh, OPTIONS, calls, and media checks require the
operator procedure in the HA runbook and are not replaced by this local test.
