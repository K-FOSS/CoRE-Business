# Kamailio Helm values

For the observed Home1 SIP Core Gateway contract and the currently explicit
`internal.replicas: 1` ApplicationSet setting, see the
[SIP HA gateway baseline](SIP-STATEFUL-HA.md#sip-core-wss-integration-baseline-observed-2026-10-08).
That baseline documents the existing backend Service/port and the separately
owned Gateway timeout layer. The ordinary `internal` private-SBC remains one
replica; the HA configuration adds a separate named `internal-wss` instance
using the same `private-sbc` role. The role default keeps WSS HA disabled.
Opt-in WSS edge behavior and its limits are documented in
[SIP Stateful HA](SIP-STATEFUL-HA.md#implemented-wss-edge-mode).

This is the value reference for the Kamailio part of the [AVoIP chart](../README.md).
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects one `carrier` instance for DC1, Home1, and `dc1-k3s-node1` into
`core-prod`. The chart uses [BJW-S common 5.0.1](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
for workloads and Services. It runs the pinned
[Kamailio 6.1.4 image](https://github.com/kamailio/kamailio-docker) and uses
[TOPOS](https://www.kamailio.org/docs/modules/6.1.x/modules/topos.html) with a
site-local Redis-compatible store. This page describes what the templates
currently render, including the disabled private registrar pilot.

## Value layers and instance identity

Configure `kamailio.defaults`, `kamailio.roleDefaults.<role>`, then
`kamailio.instances[]`. For each instance, the chart deep copies and merges
those three maps in that order; the instance wins for a matching scalar or map
key. Lists replace whole lists. In particular, site values replace the entire
`instances` array. Include **every** desired instance in each site's
[ApplicationSet values](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
`extraEnv`, tolerations, and topology spread constraints also replace rather
than append.

| Path under `kamailio.instances[]` | Current value | Effect |
| --- | --- | --- |
| `name` | `carrier` | Stable identifier; DNS label, lowercase, at most 24 characters. Resource names derive from it, never array position. `carrier` retains the existing `kamailio` resource names and selectors. |
| `enabled` | `true` | Disabled entries render no Kamailio resources. Keep the entry in the complete site array if it may be enabled later. |
| `role` | `carrier-sbc` | Supported roles are `carrier-sbc` for the instance named `carrier` and `private-sbc` for other names. The separate `internal` and `internal-wss` instances both use `private-sbc`, with independent configuration and selectors. An endpoint registrar role is not implemented. |
| `replicas` | `3` | Deployment replicas normally; the dedicated WSS instance opts into a StatefulSet with 2–10 replicas. |

The `carrier-sbc` role enables media integration and public exposure. The
`private-sbc` role has a separate routing script, defaults public exposure and
media integration to off, and starts with one replica and disruption budget
`minAvailable: 0`. Its direct TLS listener requires a verified client
certificate and a configured source CIDR plus certificate DNS SAN. It rejects
`REGISTER` unless the registrar pilot is explicitly enabled with a dedicated
PostgreSQL service identity and named mTLS access peer.

The private role reserves `100m` CPU and `256Mi` memory for the Kamailio
container and sends WebSocket keepalives every 15 seconds. The HA WSS edge
uses unsolicited Pong frames (`websocketHA.keepaliveMechanism: 2`) because
live Kamailio logs showed that missing Pong responses caused the Ping mode to
forcibly close quiet connections. The legacy private SBC preserves Ping mode
(`websocket.keepaliveMechanism: 1`). Asterisk OPTIONS checks SIP flow
reachability. The interval is configurable at
`kamailio.defaults.websocket.keepaliveTimeoutSeconds` and can be overridden
by role or instance; valid values are 5–600 seconds.
The regular private-SBC stays one replica. Add a separate named private-SBC
instance (recommended `internal-wss`) and explicitly set
`websocketHA.enabled: true` there. A one-replica enabled instance is allowed
only with `websocketHA.pilot: true`; use it for staged Path and runtime
validation, then scale to at least two (normally three) before production
activation. HA uses stable StatefulSet
pod DNS names and Asterisk-stored Path; shared TOPOS does not transfer a live
WebSocket or a Kamailio transaction. See the staged pilot and cutover steps in
the [HA runbook](SIP-STATEFUL-HA.md#implemented-wss-edge-mode).

| Current site | Carrier instances and exposure |
| --- | --- |
| DC1 | One `carrier`, three replicas, public TLS/5061, UDP/5060, and TCP/5060; PureLB direct Service. |
| Home1 | One `carrier`, three replicas, public TLS/5061 and UDP/5060; kube-vip direct Service. |
| `dc1-k3s-node1` | One `carrier`, three replicas, public TLS/5061; FreeSWITCH and Asterisk are disabled there. |

DC1's injected `publicExposure.sip.udpRoute.enabled: false` is a legacy
value with no template consumer. The chart does not render a UDPRoute.

## Workload and Kubernetes options

The following paths are under `kamailio.defaults`. They may also be set in a
role profile or an instance. Empty maps and lists below are the chart defaults.

| Path | Default | Rendered behavior |
| --- | --- | --- |
| `image.repository`, `image.tag`, `image.digest`, `image.pullPolicy` | `ghcr.io/kamailio/kamailio`, `6.1.4-bookworm`, `sha256:c54f770ab74ae64588cc174e206aa337108cc777b6162d738189d1cb0c32d116`, `IfNotPresent` | Main container and the FreeSWITCH TLS CA init container. Keep the digest pinned when changing the image. |
| `resources` | `{}` | Container requests and limits; empty preserves the current carrier manifest. |
| `websocket.keepaliveTimeoutSeconds` | `60` | Ping interval for WebSocket clients when SIP Core WebSocket handling is enabled; the private role uses `15`. Valid range is 5–600 seconds. |
| `websocket.keepaliveMechanism` | `1` | Kamailio WebSocket keepalive mode: `0` disabled, `1` Ping and require client Pong, or `2` server Pong heartbeat. HA mode requires `2`; legacy private instances retain `1`. |
| `websocketHA.keepaliveMechanism` | `2` | HA WSS keepalive mode. Render-time validation rejects values other than `2` because missed client Pong frames previously closed live connections. |
| `serviceAccountName` | `default` | Pod ServiceAccount reference. A blank value fails rendering. The chart does not create a new account for an instance. |
| `securityContext.pod`, `securityContext.container` | `{}`, `{}` | Nonempty maps replace the built-in pod or container security context. The built-in pod runs as UID/GID 1000 with RuntimeDefault seccomp; the container drops capabilities and uses a read-only root filesystem. |
| `scheduling.nodeSelector`, `scheduling.tolerations` | `{}`, `[]` | Pod placement. The tolerations list replaces the default list. |
| `scheduling.affinity`, `scheduling.topologySpreadConstraints` | `{}`, `[]` | Nonempty values replace the built-in hostname anti-affinity or spread constraints. |
| `podAnnotations`, `podLabels` | `{}`, `{}` | Add pod metadata. Required `app`, controller, and Kamailio instance labels cannot be overridden. Do not override generated Reloader annotations. |
| `extraEnv` | `[]` | Additional main-container environment entries. Duplicate names and `POD_NAME` or `TOPOS_REDIS_SERVER` fail rendering. Use `valueFrom.secretKeyRef` for credentials. |
| `rollingUpdate.surge`, `rollingUpdate.unavailable` | `'0'`, `1` | Deployment rolling update limits. The quoted zero is intentional for BJW-S rendering. |
| `podDisruptionBudget.minAvailable` | `2` for carrier; `0` for private | Per-instance disruption budget. Set it consistently with replicas. |

Each enabled instance gets its own Deployment, ConfigMap, private Service,
SIP certificate, TOPOS ExternalSecret, and applicable NetworkPolicy and
disruption budget. Public resources render only for a publicly exposed
instance. The carrier's existing selector remains stable; other instances use
their own controller and instance selector labels. The generated configuration
checksum and Reloader references cause a rollout when configuration changes.

### WSS edge HA options

Only the selected Asterisk SIP Core private instance may enable HA directly.
A separate unselected pilot may set `websocketHA.pilot: true` while leaving
the selected legacy instance running. Invalid replica counts, missing Asterisk
SIP Core selection, enabled Kamailio registrar, invalid drain timings, PDB
values and rollout partitions fail Helm rendering.

| Path | Default | Rendered behavior |
| --- | --- | --- |
| `websocketHA.enabled` | `false` | Enables StatefulSet identities, Path routing and the owner TLS Service; does not alter the carrier instance. |
| `websocketHA.pilot` | `false` | Allows an unselected HA private-SBC instance to coexist with the selected legacy service; also permits a selected one-replica test instance. |
| `websocketHA.legacyOwner` | `false` | Keeps the previous single-replica SIP Core listener and return Service present after another instance becomes selected. Enables local `ctl` and shutdown drain behavior; setting it on an already running legacy instance causes one controlled pod replacement so later drains can use `ws.disable`. |
| `websocketHA.ownerServiceName` | generated `*-owner` | Headless Service identity used for pod DNS and wildcard certificate SANs. |
| `websocketHA.podDisruptionBudget.minAvailable` | `2` | Protects at least two replicas during voluntary disruption. |
| `websocketHA.rolloutPartition` | `0` | StatefulSet rolling update partition for controlled ordinal updates. |
| `websocketHA.endpointRemovalDelaySeconds` | `10` | Wait after readiness removal for EndpointSlice and gateway backend updates. |
| `websocketHA.drainSeconds` | `120` | Time for existing connections/dialogs before container exit. |
| `websocketHA.terminationGracePeriodSeconds` | `150` | Must exceed drain plus endpoint-removal delay by at least five seconds. |

When HA or `legacyOwner` draining is enabled, the default pod security context
sets `fsGroup: 1000` so the non-root Kamailio UID/GID can write the existing
`/tmp` emptyDir marker and local ctl socket. A custom pod security context must
also set `fsGroup: 1000`; Helm rejects a value that would make draining fail.

## Listeners, Services, and SIP identities

| Path under `kamailio.defaults` | Default | Rendered behavior |
| --- | --- | --- |
| `listeners.bindAddress` | `'0.0.0.0'` | Bind address for the four configured SIP listeners. The ports are fixed by this chart. |
| `tcpChildren` | `4` | Kamailio `tcp_children`. |
| `publicExposure.enabled` | `true` for carrier; `false` for private | Gates public Service ports and Gateway resources. The private Service always includes TLS/5062. A private role cannot turn this on. |
| `publicExposure.sip.enabled` | `true` | Enables the TLSRoute and TLS/5061 port on the direct public Service if that Service is enabled. The private role does not bind the public TLS socket. |
| `publicExposure.sip.udpEnabled` | `false` | Adds UDP/5060 listener and Service port. Requires the direct public Service. |
| `publicExposure.sip.tcpEnabled` | `false` | Adds TCP/5060 listener and Service port. Requires the direct public Service. |
| `publicExposure.sip.directService.enabled` | `false` | Creates the `kamailio-pub` Service for enabled public transports. UDP/TCP require it so the Contact is reachable. A LoadBalancer Service uses `externalTrafficPolicy: Local` to retain the carrier source IP. |
| `publicExposure.sip.directService.hostname` | `''` | Overrides the direct Service identity; otherwise `kamailio-pub.<cluster>.<datacenter>.<region>.resolvemy.host` for the carrier. |
| `advertisedHost` | `''` | Carrier site hostname override. `sip.siteHost` takes precedence when set; otherwise the chart derives `sip.<cluster>.<datacenter>.<region>.resolvemy.host`. A private instance's value does not create a separate public hostname. |
| `advertisedTLSPort` | `5061` | Public TLS advertised port and aliases. The actual listener and Gateway backend port stay 5061. |
| `sip.serviceHost` | `''` | Private Kamailio Service identity in TLS certificates and SIP routes; empty derives the instance Service DNS name under `<namespace>.svc.<cluster.domain>`. Private TLS stays on 5062. |
| `services.private.annotations`, `services.private.labels`, `services.private.type` | `{}`, `{}`, `''` | Private Service metadata and type. Empty type uses `serviceOptions.<instance component>`, then `serviceOptions.defaults`. |
| `services.public.annotations`, `services.public.labels`, `services.public.type`, `services.public.loadBalancerClass` | `{}`, `{}`, `''`, `''` | Direct public Service settings. Instance metadata overrides matching `serviceOptions` metadata; instance type and class override nonempty global values. The chart adds ExternalDNS hostname annotations for this Service. |

For the carrier, the `serviceOptions` keys are `kamailio` and
`kamailio-pub`. For an instance named `internal`, the private key is
`kamailio-internal`. Site-specific LoadBalancer annotations and classes are
currently supplied by the
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml):
Home1 uses kube-vip and DC1 uses PureLB. Do not replace those site values with
chart defaults.

The script advertises public UDP/5060 or TCP/5060 for a dialog received on
those transports, public TLS/5061 for a TLS dialog, and private TLS/5062 to
FreeSWITCH. TOPOS derives its Contact and token from the corresponding
Record-Route identity. Public TLS uses an Envoy Gateway TLSRoute with PROXY
protocol v2; the direct Service carries UDP/TCP. The actual source ACL is
`flowroute.signalingCIDRs`, not a Kamailio instance field. See
[SIP identity and call verification](SIP-IDENTITY.md) before changing a public
host, transport, Gateway, or carrier CIDR.

Related chart values outside `kamailio` can affect instance routing or
resources:

| Chart path | Effect |
| --- | --- |
| `cluster.name`, `cluster.domain`, `datacenter`, `region` | Derive site SIP and Service DNS identities and the site Dragonfly endpoint. The ApplicationSet injects these. |
| `sip.siteHost` | Overrides the carrier's `advertisedHost` and derived public site hostname. |
| `sip.globalHost`, `sip.globalRouting.*` | Global SIP alias and optional global TLSRoute/K8GB DNS resources. Global routing is off by default. |
| `sip.tls.issuerName` | ClusterIssuer used for each Kamailio SIP certificate. |
| `gateway.name`, `gateway.namespace` | Public TLSRoute parent Gateway; the route uses the fixed `sips-tls` section. |
| `flowroute.signalingCIDRs` | Carrier source allowlist. Requests from other sources or sockets receive 403, except ACKs are silently dropped. Keep it narrow. |
| `freeswitch.enabled`, `rtpengine.enabled`, `homer.enabled` | Gate backend, media, and HEP behavior together with the instance function switches. |

The carrier NetworkPolicy is present while FreeSWITCH is enabled and
`backend.serviceName` is empty. An enabled private instance gets a dedicated
`CiliumNetworkPolicy` selecting its pod and the configured peer/destination
controller labels. Custom targets require matching controller labels and a
review of DNS and TLS certificate identity.

## Backend, topology, and logging

| Path under `kamailio.defaults` | Default | Rendered behavior |
| --- | --- | --- |
| `backend.serviceName` | `''` | Empty selects the chart's FreeSWITCH Service. A custom name disables the default FreeSWITCH NetworkPolicy rule; provide an appropriate network policy and verify the backend target before use. |
| `backend.servicePort` | `5061` | Backend TLS port. |
| `backend.podCIDR` | `'172.16.0.0/12'` | Coarse source guard on the private TLS/5062 listener, in addition to the default pod selector NetworkPolicy. |
| `carrierOutbound.enabled` | `false` | Enables the isolated service-peer PSTN pilot only when its mTLS, exact test number, caller ID and quota values validate. The FreeSWITCH backend listener still rejects new calls. See [outbound pilot](OUTBOUND-PILOT.md). |
| `carrierOutbound.gatewayServiceHost`, `gatewayNamespace`, `sniHost` | `''`, `kube-system`, `''` | Existing Envoy Gateway Service DNS name, data-plane namespace and dedicated carrier TLS SNI. The route reuses Gateway PROXY v2; it does not create a LoadBalancer. |
| `carrierOutbound.peer.cidr`, `sanHostname`, `serviceHost`, `controller` | `''` | Authorized internal peer address/certificate and its separately addressable private Service/pod selector. Carrier-to-private dialog traffic uses only this service. |
| `carrierOutbound.testRoute.extension`, `peerName`, `destination`, `callerId` | `''` | Exact private test extension and mTLS origin, one non-premium E.164 NANP destination and permitted NANP caller ID. Empty values fail when enabled. |
| `carrierOutbound.limits.callsPerMinute`, `concurrentCalls`, `maxDurationSeconds` | `1`, `1`, `600` | Atomic carrier-wide Dragonfly rate/concurrency limits and dialog lifetime. No billing call is automated. |
| `privateRouting.peers[]` | `[]` | Private role peer `name`, `controller`, literal `cidr`, certificate `sanHostname`, and `allowedUsers` (exact numeric destination extensions). Source address, verified TLS DNS SAN, and per-peer destination permission must all match. Empty `allowedUsers` denies initial calls. |
| `privateRouting.destinations[]` | `[]` | Private role dispatcher `setId`, literal `sips:<host>:<port>` `uri`, and destination pod `controller`. OPTIONS probing excludes failed destinations from new selection. |
| `privateRouting.routes[]` | `[]` | Exact numeric `user` to configured `setId` mapping. No default external route or prefix match exists. |
| `registrar.enabled`, `realm`, `accessPeerName`, `allowedUsers` | `false`, `''`, `''`, `[]` | Private-only Digest pilot. Requires a configured mTLS access peer and explicit numeric AoRs; browser/WSS ingress is not present. A Digest-authenticated peer can call only another listed registered AoR, never PSTN. |
| `registrar.database.host`, `port`, `username`, `secretName`, `terraformProvider`, `crossplaneProvider` | `''`, `5432`, `''`, `''`, `''`, `''` | Site-local PostgreSQL service identity via the existing `User` Composition. The stable Secret supplies `psqlURI`, `username`, `password`, and `database`; no SIP secret is stored in it. Empty provider fields derive from site values. |
| `registrar.maxContacts`, `minExpires`, `maxExpires` | `2`, `120`, `600` | Registrar contact and refresh limits. The separate `subscriber.enabled`/`expires_at` view controls verifier validity; database triggers purge contacts on disable, expiry change or HA1 rotation. No credential issuer is deployed. |
| `networkPolicy.envoy.namespace`, `networkPolicy.envoy.podName` | `envoy-gateway-system`, `envoy` | Labels used to permit Gateway data-plane ingress to public TLS/5061. Match the installed Gateway pods. |
| `topology.enabled` | `true` | Enables Redis-backed TOPOS and its local TLS bridge. Both supported roles require this; disabling it fails role validation. |
| `topology.redis.secretName`, `topology.redis.serverKey` | `avoip-kamailio-topos`, `server` | Secret containing the Redis server string consumed by Kamailio. Duplicate names are made instance-specific for later instances. |
| `topology.redis.database` | `51` | Site-local logical database. Enabled instances need different nonzero databases; allocate one before adding an instance. |
| `topology.redis.host`, `port`, `proxyPort`, `tlsServerName` | derived Dragonfly host, `6379`, `16379`, derived Dragonfly host | The local HAProxy bridge listens on loopback and verifies TLS to the site Dragonfly endpoint. |
| `topology.redis.secretStoreRef.kind`, `name` | `ClusterSecretStore`, `corevault-rootsecrets` | External Secrets store reference. |
| `topology.redis.remoteRef.key`, `property` | derived site credential path, `Password` | Vault reference used by the ExternalSecret. Keep the password out of Helm values. |
| `sipLogging.enabled` | `true` | Compact reply and dialog markers. Some ACK and failure markers are always emitted. |
| `sipLogging.carrierTraffic` | `true` | Full authorized carrier-facing SIP messages. These can contain identity data and SDP. |
| `sipLogging.postToposResponses` | `true` | Pre-TOPOS and final network-send snapshots for selected INVITE responses. |
| `sipLogging.rawInbound` | `true` | Full raw receive and parse-error messages. |
| `sipLogging.diagnostics.enabled`, `coreDebug`, `sdp` | `true`, `2`, `true` | Routing markers, Kamailio core debug level, and SDP send diagnostics. These defaults reflect the ongoing ACK investigation. |

Removing an instance removes its ExternalSecret from desired state. Review
its target Secret's ownership before deletion; the chart does not remove a
Dragonfly allocation or revoke the Vault source.
The container's Redis client uses the loopback bridge, which verifies TLS to
Dragonfly. Separate instance databases and Secrets prevent shared TOPOS token
namespaces. The current media function operates only when the instance switch,
`rtpengine.enabled`, and `freeswitch.enabled` are all true.

When adding another private Kamailio instance, set
`topology.redis.database` explicitly to an allocation in the shared Dragonfly
registry. If two instances inherit or specify the same `secretName`, the chart
derives an instance-specific Secret name for each later instance because each
generated ExternalSecret embeds its database number in the TOPOS server string.
The chart still rejects duplicate database allocations.

## SIP function switches and validation

| `functions.*` | Carrier role | Private role | Behavior |
| --- | --- | --- | --- |
| `sanity`, `classification`, `transactions`, `dialog`, `authorization`, `recordRoute`, `backendSelection`, `topology` | `true` | `true` | Required by both roles. Setting any to `false` fails rendering; they describe one coherent SIP function, not independent modules to remove. |
| `media` | `true` | `false` | Controls RTPEngine module and route calls when FreeSWITCH and RTPEngine are enabled, plus the RTPEngine NetworkPolicy egress stanza. Carrier role requires it. |
| `sipTrace` | `true` | `true` | Controls `siptrace` module, HEP parameters, and Homer NetworkPolicy egress when Homer is enabled. |

Rendering also fails for duplicate or invalid names, unsupported roles, a
noncarrier `carrier-sbc`, public exposure on `private-sbc`, zero replicas on
an enabled instance, mismatched `functions.topology` and
`topology.enabled`, missing TOPOS Secret settings, database zero, duplicate
enabled TOPOS databases or Secret names, and duplicate or reserved environment
names. The chart does not validate that an arbitrary custom backend, bind
address, certificate hostname, or Service class is reachable; review those
along with the rendered SIP configuration.

## Example and verification

This **test-only Home1** overlay retains its current carrier identity and
transport overrides while adding one private instance. Applying it to a live
site would add a Deployment. At another site, copy that site's entire carrier
entry from the owning ApplicationSet. Allocate the new database in the
[Backplane Dragonfly registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md)
before any production use.

```yaml
kamailio:
  instances:
    - name: 'carrier'
      enabled: true
      role: 'carrier-sbc'
      replicas: 3
      advertisedHost: 'sip.core-home1-talos-prod.home1.yvr.resolvemy.host'
      publicExposure:
        enabled: true
        sip:
          udpEnabled: true
          directService:
            enabled: true
    - name: 'internal'
      enabled: true
      role: 'private-sbc'
      replicas: 1
      topology:
        redis:
          database: 52
          secretName: 'avoip-kamailio-internal-topos'
      resources:
        requests:
          cpu: '100m'
```

Run `helm lint AVoIP` and `AVoIP/tests/kamailio-instances.sh`, then render
with each site's complete ApplicationSet-injected values. The
[SIP security render guard](../tests/README.md#authorization-and-outbound-call-probes)
checks the source ACL and registration rejection; live negative SIP probes
still need an isolated deployment. A standalone Helm render covers only part
of the Lovely pipeline because this chart also has a `kustomization.yaml`.
For rollout, rollback, and Call-ID acceptance steps, see the
[AVoIP deployment guide](../README.md#named-kamailio-instances).
