# Workload interfaces and additional voice functions

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
owns this chart through Lovely and `LOVELY_HELM_MERGE`, targeting `core-prod`
on the DC1 hub and Home1 spoke. Network overrides belong in each site's merge
layer. Empty defaults preserve existing pods and their cluster network.

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
disables Cilium egress gateway pinning. Outbound Flowroute signaling instead
uses the site's VyOS WAN-GW/NAT VRRP source address. See
[SIP identity and egress](SIP-IDENTITY.md) for the observed hub address and
its distinction from the public RTP address.

`workloadNetworking` is keyed by enabled controller: `asterisk`, `freeswitch`,
`kamailio`, `rtpengine`, or `homer-web`. It also supports controllers added by
the `functions` array. Each profile supports placement (`nodeSelector`,
`affinity`, `tolerations`), DNS (`dnsPolicy`, `dnsConfig`), ordered `interfaces`,
and BJW-S `initContainers` for NIC configuration. An explicit affinity override
replaces the chart defaults, including RTPEngine replica spreading.

This follows the Multus model used by Backplane's
[Tunnels](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Network/Tunnels)
and [RouteServer](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Network/RouteServer).
The [Multus project and documentation](https://github.com/k8snetworkplumbingwg/multus-cni)
describe the attachment annotations; the
[CNI plugins](https://www.cni.dev/plugins/current/) document static IPAM,
macvlan, and tuning; [SR-IOV CNI](https://github.com/k8snetworkplumbingwg/sriov-cni)
documents VF resource and VLAN configuration. Multus, the selected plugins,
and matching device resources must already be installed by Backplane.

Each interface can reference an existing `networkAttachment` (optionally in
`namespace`) or supply a complete `cni` configuration to generate a NAD.
Complete CNI JSON expressed as YAML supports chained plugins, IPAM, routes,
MTU, VLANs, and tuning sysctls without reducing the available plugin options.
`resourceName` requests the SR-IOV device and annotates generated NADs. Multiple
interfaces using the same resource consume the corresponding number of VFs.
`resourceContainer` selects the consuming container, defaulting to the controller
name. All containers and diagnostic sidecars share the pod's interfaces.

```yaml
workloadNetworking:
  rtpengine:
    interfaces:
      - name: 'eth1'
        resourceName: 'mellanox.com/mlx4_cx3_netdevice'
        cni:
          type: 'sriov'
          vlan: 666
          mtu: 1500
          ipam:
            type: 'static'
            addresses:
              - address: '192.0.2.10/24'
            routes:
              - dst: '198.51.100.0/24'
                gw: '192.0.2.1'
```

Interfaces attach as secondary networks by default (`eth1`, `eth2`, ...).
`replaceDefaultNetwork: true` instead selects the first entry as Multus's
default network, matching Backplane's interface-zero model. Preserve cluster
DNS, API, backend, and database reachability when replacing the default network.
Static addresses require separate instances with unique addresses; scaling a
pod with static IPAM can duplicate addresses.

Link rings, offloads, source routes, policy routing, and `tc` classes/filters
can be declared through `initContainers` using the same commands as Backplane.
The controller's existing init containers are retained. Such a container needs
explicit `NET_ADMIN` for route/qdisc changes; the current baseline PodSecurity
policy rejects that capability. Use CNI tuning where supported or an explicitly
approved namespace policy before enabling these init containers. No privileges
are granted by the default profile.

## Named functions

`functions` is an array of independently named YAML-defined workloads for
additional PBXs, voice workers, or organization services. Every enabled entry
requires a unique `name` and a BJW-S `controller`. Optional `services`,
`configMaps`, `persistence`, and `networking` are applied to that controller. Service and
persistence identifiers are prefixed with the function name to avoid collisions.
ConfigMap identifiers receive the same prefix; set `forceRename` when an
explicit mounted name is needed. ConfigMap contents must contain configuration
only; credentials belong in existing Secrets referenced through persistence/env.
Persistence `advancedMounts` must refer to the function's controller/container.

```yaml
functions:
  - name: 'voice-worker'
    enabled: true
    controller:
      replicas: 1
      containers:
        worker:
          image:
            repository: 'example.invalid/organization/voice-worker'
            tag: '1.0.0'
          env:
            ORGANIZATION: 'example-org'
    networking:
      interfaces:
        - name: 'eth1'
          networkAttachment: 'organization-voice'
```

An additional Asterisk can use this contract with a pinned Asterisk image,
its own ConfigMap/Secret-backed configuration and volumes, and separate
Service. This does not clone the managed Asterisk's service identity, database,
dialplan, or FreeSWITCH gateway automatically. Use Secret references for
credentials. Function containers use the
[BJW-S controller schema](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
and need their own probes, security context, and rollout annotations.

Attaching an interface does not automatically change SIP/RTP binds or SDP
advertisements. Configure Asterisk `externalMediaAddress`,
`externalSignalingAddress`, and `localNet` consistently with the chosen path;
review each component's media address settings before moving traffic. Generated
NADs use BJW-S `rawResources` because NAD is a custom API.

## Verification and rollback

Render with the Backplane merge and your network override file, then inspect
all Deployments, Services, NAD JSON, device requests, and init containers:

```sh
helm lint . -f /tmp/avoip-site-values.yaml
helm template avoip . -n core-prod -f /tmp/avoip-site-values.yaml
kubectl -n core-prod get pods,network-attachment-definitions
kubectl -n core-prod get pod <pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
kubectl -n core-prod exec <pod> -c netshoot -- ip -br address
kubectl -n core-prod exec <pod> -c netshoot -- ip route
kubectl -n core-prod exec <pod> -c netshoot -- ip rule
```

Verify SIP, SDP, RTP, voice bridging and fax reception after reconciliation;
readiness alone does not validate additional interfaces. Restore empty network
profiles and remove added functions to roll back through Git/Argo CD. Removing
an attachment restarts affected pods and interrupts their active calls. Removing
functions may prune their Services/volumes according to their persistence
retention configuration; inspect those settings before removal.
