# Kamailio Helm values

This is the value reference for the Kamailio part of the [AVoIP chart](../README.md).
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects one `carrier` instance for DC1, Home1, and `dc1-k3s-node1` into
`core-prod`. The chart uses [BJW-S common 5.0.1](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
for workloads and Services. It runs the pinned
[Kamailio 6.1.4 image](https://github.com/kamailio/kamailio-docker) and uses
[TOPOS](https://www.kamailio.org/docs/modules/6.1.x/modules/topos.html) with a
site-local Redis-compatible store. This page describes what the templates
currently render; it does not describe a future registrar.

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
| `role` | `carrier-sbc` | Supported roles are `carrier-sbc` for the instance named `carrier` and `private-sbc` for other names. An endpoint registrar role is not implemented. |
| `replicas` | `3` | Independent Deployment replica count; an enabled instance needs at least one. |

The `carrier-sbc` role enables media integration and public exposure. The
`private-sbc` role has a separate routing script, defaults public exposure and
media integration to off, and starts with one replica and disruption budget
`minAvailable: 0`. Its direct TLS listener requires a verified client
certificate and a configured source CIDR plus certificate DNS SAN. It rejects
`REGISTER`; SIP Digest registration is not implemented yet.

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
| `carrierOutbound.enabled` | `false` | The carrier rejects new application-originated calls. Enabling fails rendering until verified ingress identity, destination rules and quotas are implemented. Existing carrier dialogs still use the private listener. |
| `privateRouting.peers[]` | `[]` | Private role peer `name`, `controller`, literal `cidr`, certificate `sanHostname`, and `allowedUsers` (exact numeric destination extensions). Source address, verified TLS DNS SAN, and per-peer destination permission must all match. Empty `allowedUsers` denies initial calls. |
| `privateRouting.destinations[]` | `[]` | Private role dispatcher `setId`, literal `sips:<host>:<port>` `uri`, and destination pod `controller`. OPTIONS probing excludes failed destinations from new selection. |
| `privateRouting.routes[]` | `[]` | Exact numeric `user` to configured `setId` mapping. No default external route or prefix match exists. |
| `networkPolicy.envoy.namespace`, `networkPolicy.envoy.podName` | `envoy-gateway-system`, `envoy` | Labels used to permit Gateway data-plane ingress to public TLS/5061. Match the installed Gateway pods. |
| `topology.enabled` | `true` | Enables Redis-backed TOPOS and its local TLS bridge. Both supported roles require this; disabling it fails role validation. |
| `topology.redis.secretName`, `topology.redis.serverKey` | `avoip-kamailio-topos`, `server` | Secret containing the Redis server string consumed by Kamailio. Enabled instances need different Secret names. |
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
