# SIP border failure runbook

1. Check the Kamailio Deployment, both listener ports, readiness, and recent
   startup-config validation logs.
2. Check Envoy Gateway data-plane replicas, SIPS listener status, PROXYv2
   errors, and public VIP health.
3. Check `avoip-kamailio-topos` ExternalSecret status and site Dragonfly TLS,
   authentication, DB 51 reachability, and latency.
4. Confirm Kamailio can reach FreeSWITCH TLS/5061 and RTPEngine UDP/22222.
5. Capture one new call and verify `raw receive -> ACK ingress -> dialog
   decision -> ACK send` before changing routing.
6. Roll back the reviewed Git commit through Argo CD if the generated config
   is invalid. Do not bypass PROXYv2 or broaden the private NetworkPolicy.

When `kamailio.sipLogging.carrierTraffic` is enabled, Kamailio emits complete
authorized carrier-facing messages as `SIP FLOWROUTE RX` and `SIP FLOWROUTE TX`
records. RX records are emitted after the PROXYv2-derived carrier CIDR check;
TX records are emitted for the `public_tls` send socket. Use the Call-ID and
the `CSeq` value to correlate INVITE, provisional/final replies, ACK, BYE,
CANCEL, retransmissions, and error responses across replicas. These records
can contain Authorization headers, caller/callee identities, PAI, Contact,
SDP, and MESSAGE bodies. Keep the setting enabled only for an incident and
disable it afterward.

## Inspektor Gadget network debugging

Inspektor Gadget is available in the sites as an optional kernel-level view of
the border. Use it to correlate TCP connection creation, accept/close events,
and kernel TCP drops with the Kamailio, Envoy, FreeSWITCH, and RTPEngine logs.
It is especially useful when a call fails after a fixed interval and the SIP
logs show an ACK or retransmission timeout but do not identify which socket
closed or stopped receiving traffic. The [official quick start](https://inspektor-gadget.io/docs/latest/quick-start/),
[TCP tracer](https://inspektor-gadget.io/docs/latest/gadgets/trace_tcp/), and
[TCP-drop tracer](https://inspektor-gadget.io/docs/latest/gadgets/trace_tcpdrop/)
describe the supported Kubernetes commands.

Use the installed site version of the gadget image; substitute it for
`<gadget-version>` below rather than pulling a moving `latest` tag:

```sh
SITE_CONTEXT=logged-user
GADGET_VERSION=<installed-version>

kubectl --context "$SITE_CONTEXT" gadget run \
  ghcr.io/inspektor-gadget/gadget/trace_tcp:"$GADGET_VERSION" \
  -n core-prod -l app.kubernetes.io/controller=kamailio
```

For a failing call, start the trace immediately before reproducing it. Record
the Call-ID and UTC timestamps, then look for connections involving:

- Kamailio TCP/5061 (public SIPS) and TCP/5062 (private SIPS)
- FreeSWITCH TCP/5061
- Homer HEP TCP/9061
- the RTPEngine NG control path and any observed media socket endpoints

To focus on failed TCP delivery or kernel drops, run the site’s corresponding
`trace_tcpdrop` gadget with the same namespace and label filter. To investigate
unexpected Kamailio process restarts, use the installed `trace_exec` gadget
with the same filter and correlate its events with pod restart times.

Inspektor Gadget sees kernel/socket metadata and timing; SIPS payloads remain
encrypted, and it does not prove SIP transaction state, TOPOS reconstruction,
FreeSWITCH dialog ownership, or RTP continuity. Always correlate its output
with Kamailio high-level diagnostics, FreeSWITCH SIP/media logs, RTPEngine
statistics, Homer, and the call’s Call-ID. Stop the foreground gadget with
`Ctrl-C`; do not leave broad eBPF traces running during normal operation.
Gadget execution requires privileged
node/eBPF access, so restrict it to authorized operators and record the site,
node, filter, version, and capture window in the incident notes.

## TLS and SIP payload inspection options

The Cilium datapath and ordinary network eBPF hooks see SIPS as encrypted TCP;
they can show endpoints, ports, timing, retransmission, resets, and drops, but
they cannot parse SIP headers or SDP. Because Kamailio terminates TLS, a
process-level eBPF hook is possible at the TLS library boundary. Inspektor
Gadget provides an optional [`trace_ssl`](https://inspektor-gadget.io/docs/v0.56.0/gadgets/trace_ssl/)
gadget for OpenSSL, GnuTLS, NSS, and libcrypto. Confirm that the installed
gadget version supports the target library and image before using it.

Metadata-only TLS tracing should be the first step:

```sh
SITE_CONTEXT=logged-user
GADGET_VERSION=<installed-version>

kubectl --context "$SITE_CONTEXT" gadget run \
  ghcr.io/inspektor-gadget/gadget/trace_ssl:"$GADGET_VERSION" \
  -n core-prod -l app.kubernetes.io/controller=kamailio \
  --record-data=false
```

If TCP connectivity is present but SIP behavior is still unexplained, a short,
single-call payload capture can be enabled:

```sh
kubectl --context "$SITE_CONTEXT" gadget run \
  ghcr.io/inspektor-gadget/gadget/trace_ssl:"$GADGET_VERSION" \
  -n core-prod -l app.kubernetes.io/controller=kamailio \
  --record-data=true -o json
```

Treat this as equivalent to raw SIP logging. Captured data may contain
Authorization headers, Call-IDs, caller/callee identities, PAI, Contact and
Route values, SDP, MESSAGE bodies, and media addresses. Use one test call,
restrict the pod label and time window, store output only in the incident
workspace, and stop it with `Ctrl-C` immediately afterward. Do not enable
payload recording continuously or in production defaults.

There is no standard SIP-aware eBPF gadget in the Cilium monitor or the
Inspektor Gadget set. The practical SIP inspection choices are therefore:

1. Kamailio high-level diagnostics and Homer for method, Call-ID, CSeq, route,
   ACK, transaction, and sanitized SDP decisions.
2. `trace_ssl --record-data=true` for a tightly scoped plaintext-at-TLS-boundary
   capture when the SIP bytes themselves are required.
3. A separately reviewed custom uprobe/eBPF gadget for a pinned Kamailio or
   TLS-library build when repeatable SIP parsing is needed. This must be
   version-tested because symbols, offsets, buffering, and thread ownership
   can change between images.

Cilium `cilium-dbg monitor` remains the authority for network policy verdicts,
packet traces, and drops; it is not a SIP decoder. Correlate all three layers:
TLS/process capture, Kamailio/Homer SIP diagnostics, and Cilium L3/L4 events.

## Cilium pod-level network tracing

The site Cilium agents run as pods in `kube-system` and provide a second,
cluster-native view of the packet path. Run `cilium-dbg monitor` from the
Cilium pod on the same node as the Kamailio, FreeSWITCH, Envoy, or RTPEngine
pod being investigated. Cilium’s monitor reports BPF drops, packet traces,
and policy verdicts; it does not decrypt SIPS or replace SIP application logs.
See the [Cilium monitor reference](https://docs.cilium.io/en/stable/cmdref/cilium-dbg_monitor/)
and [Cilium troubleshooting guide](https://docs.cilium.io/en/stable/operations/troubleshooting/).

Resolve the node and matching Cilium pod first:

```sh
SITE_CONTEXT=logged-user
NAMESPACE=core-prod
POD=core-home1-talos-prod-business-avoip-prod-avoip-kamailio-76nzj7
NODE=$(kubectl --context "$SITE_CONTEXT" -n "$NAMESPACE" get pod "$POD" \
  -o jsonpath='{.spec.nodeName}')
CILIUM_POD=$(kubectl --context "$SITE_CONTEXT" -n kube-system get pods \
  -l k8s-app=cilium --field-selector "spec.nodeName=$NODE" \
  -o jsonpath='{.items[0].metadata.name}')
```

Watch policy drops and verdicts while reproducing the call:

```sh
kubectl --context "$SITE_CONTEXT" -n kube-system exec -it "$CILIUM_POD" \
  -c cilium-agent -- cilium-dbg monitor \
  --type drop --type policy-verdict --type trace-sock --json
```

For a readable packet path, use trace events instead:

```sh
kubectl --context "$SITE_CONTEXT" -n kube-system exec -it "$CILIUM_POD" \
  -c cilium-agent -- cilium-dbg monitor --type trace -v
```

To narrow output to one endpoint, list endpoint IDs from that same agent and
then use the ID with `--related-to`:

```sh
kubectl --context "$SITE_CONTEXT" -n kube-system exec "$CILIUM_POD" \
  -c cilium-agent -- cilium-dbg endpoint list

kubectl --context "$SITE_CONTEXT" -n kube-system exec -it "$CILIUM_POD" \
  -c cilium-agent -- cilium-dbg monitor --type drop \
  --type policy-verdict --related-to <endpoint-id> -v
```

For the recurring 30-second failure, capture the endpoint’s node, Call-ID,
and UTC window, then correlate Cilium output with these expected paths:

- Envoy node to Kamailio TCP/5061
- FreeSWITCH to Kamailio TCP/5062
- Kamailio to FreeSWITCH TCP/5061
- Kamailio to RTPEngine UDP/22222
- RTPEngine media traffic to the advertised endpoint and FreeSWITCH

Interpret `Policy denied`, `Invalid destination`, `CT` errors, TCP reset/drop
events, and asymmetric ingress/egress traces as network evidence. Do not
change Cilium policy or enable audit mode during the capture without a
separate reviewed change. Stop the monitor with `Ctrl-C`, and retain only the
bounded incident output because it may contain pod IPs, endpoint identities,
carrier addresses, and timing metadata.
