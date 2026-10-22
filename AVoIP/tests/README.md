# AVoIP render checks

Native TLS signaling regressions are checked with
`AVoIP/tests/sipcore-native-tls-render.py` and, where a pinned Kamailio 6.1.4
runtime with SQLite is available,
`AVoIP/tests/sipcore-contact-retransmission.py --runtime --runtime-image
ghcr.io/kamailio/kamailio:6.1.4-bookworm`. The latter receives
the actual TOPOS-masked response and checks its public Contact across
retransmitted answers. The render check guards the three-replica owner route,
live TLS connection pinning, answer media callback and explicit string
comparisons. Neither substitutes for the live checks in the
[native TLS runbook](../docs/NATIVE-SIP-TLS.md).
`AVoIP/tests/sipcore-sdp-retransmission.py --runtime-image
ghcr.io/kamailio/kamailio:6.1.4-bookworm` checks that both copies of a 200
carry identical rewritten SDP using a deterministic fake RTPEngine.

The inter-site inbound trust and listener path has a focused render check:

```sh
AVoIP/tests/intersite-auth-render.sh
```

It renders representative DC1/YXL and Home1/YVR carrier values, checks the
SNI-specific optional-mTLS verification profiles, exact peer and extension
authorization, header stripping, Service and NetworkPolicy mappings, DID
rewrite, next-hop logging, and dialog route generation. In an environment with
the pinned Kamailio runtime image and cluster access, pass each rendered
`kamailio.cfg` to `kamailio -c -f /dev/stdin`; this checks the SIP script parser
without changing the running pod. The render test does not make a live call or
validate ringing, answer, RTP, or clean hangup.

## Outbound Flowroute teardown regression

Run the two-tier TOPOS and in-dialog route regression from the repository root:

```sh
AVoIP/tests/outbound-teardown-render.sh
```

The test renders carrier and private Kamailio configurations, verifies the
authenticated carrier-peer route chooses the private tier's TLS socket while
preserving the restored SIP target, and checks TM retransmission and relay
diagnostics. It does not simulate a Flowroute BYE or prove FreeSWITCH delivery.
It also checks that the internal Kamailio Cilium policy allows signaling only
to the FreeSWITCH dialog-owner pods on the configured TLS listener and that a
replacement internal SBC keeps its current ready pod during startup checks.
Follow the [outbound teardown live acceptance](../docs/avoip/runbooks/outbound-flowroute-teardown.md)
for both BYE directions, cross-replica routing, UPDATE, RTPEngine cleanup,
CDR, and Homer checks.

The managed 7101 outbound identity handoff has a separate render regression:

```sh
AVoIP/tests/managed-outbound-identity-render.sh
```

It confirms that the locked Asterisk extension context stamps its identity on
the new outbound channel, Admin routing does not replace that identity with
the caller ID before authorization, and Kamailio uses the trusted marker for
the policy lookup before applying the authorized caller ID. It also confirms
that Asterisk combines public system roots with the selected site's Kamailio CA
while keeping server verification enabled, and that CA rotation triggers an
Asterisk restart. It does not place a live call or validate provider account
acceptance.

The Homer capture-ID and SIP-dialog correlation render check is:

```sh
AVoIP/tests/homer-correlation-render.sh
```

It verifies distinct role IDs for Kamailio, FreeSWITCH, and RTPEngine while
retaining the native SIP dialog identifiers and configured Homer correlation.

The RTPEngine Redis restore and rolling-replacement guard is checked with:

```sh
AVoIP/tests/rtpengine-redis-rollout-render.sh
```

This renders the full chart through the post-Helm Kustomize patch and confirms
the old pod remains available until the replacement has stayed Ready for the
configured interval. It also checks Kamailio's explicit RTPEngine control
timeout, retry, startup ping, and redetection parameters plus safe trickle-ICE
failure metadata. It does not inject a Valkey or RTPEngine endpoint failure,
prove runtime reconnection, or establish that live RTP sessions survive a node
loss.

The optional Routr Connect integration has a separate rendering check:

```sh
AVoIP/tests/routr-connect-render.sh
```

Routr is disabled by default and uses the shared PostgreSQL claim and shared
Dragonfly endpoint when opted in. Its Location and Registry images require the
published, digest-pinned DB selection patch. The test confirms rendering and
fail-closed values only; it does not test external database connectivity,
Prisma migration, or SIP signaling. See the [Routr pilot notes](../docs/ROUTR.md)
before adding a site values override.

Run the WSS edge rendering checks from the repository root:

```sh
helm lint AVoIP
AVoIP/tests/wss-ha-render.sh
```

Verify DNS resolver options across Asterisk, FreeSWITCH, and every Kamailio
instance, including the per-instance profile override, with:

```sh
AVoIP/tests/dns-ndots-render.sh
```

Verify Asterisk's RTP engine/STUN configuration and the IPv4-only SIP/RTP
path with:

```sh
AVoIP/tests/asterisk-stun-render.sh
```

This checks the default STUN target, a site override, invalid-port rejection,
the Kamailio IPv4 DNS/media settings, and FreeSWITCH's IPv4 profiles. The image
build also verifies that `res_rtp_asterisk.so` exists; the render test does not
exercise live STUN reachability or media candidates.

The sound-library NGINX config has a focused chart-render regression:

```sh
AVoIP/tests/sound-library-nginx-render.sh
```

It checks the rendered, quoted WAV filename regex and the editor's 64-character
name validation, while preserving the read-only listing and authenticated PUT
path. Validate the generated `default.conf` with `nginx -t` from the deployed
digest-pinned unprivileged NGINX image before rollout; this render check does
not run an NGINX parser or exercise a live upload.

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
