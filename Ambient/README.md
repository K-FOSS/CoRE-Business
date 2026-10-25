# CoRE Ambient

This chart deploys Moodist as a static web application through the [bjw-s
common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It runs two replicas behind a ClusterIP Service and exposes
`sounds.mylogin.space` through a Gateway API HTTPRoute. The route is visible in
the `Tools` group of the `core` Forecastle instance under the friendly name
`Moodist`.

The chart also creates a second HTTPRoute at `sounds.gslb.mylogin.space` and a
`k8gb.io/v1beta1` `Gslb` for each hostname. Each Gslb references that secondary
route and uses round-robin DNS with a 30-second TTL across the active DC1 and
Home1 clusters selected by the owning ApplicationSet. K8GB's configured zones,
DNS provider and hostname delegation must cover these records. This chart does
not create a `ZoneDelegation` or change parent-zone DNS records. See the
[K8GB resource reference](https://www.k8gb.io/latest/resource_ref/) and
[dynamic zone documentation](https://www.k8gb.io/latest/dynamic_zones/).

[The Ambient ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Tools/Ambient.yaml)
explicitly selects the DC1 and Home1 bare-metal infrastructure clusters,
injects environment and site metadata through Lovely, and deploys into
`core-prod`. The image is pinned to Moodist v3.0.0's multi-architecture OCI
index digest. Pods do not mount a Kubernetes service account token, run as
non-root with RuntimeDefault seccomp, disable privilege escalation and drop all
Linux capabilities. Resource requests and limits bound usage. A deny-all egress
NetworkPolicy matches the static web-app posture in CyberChef and Draw.io.
HTTP startup, readiness and liveness probes check port 8080. Rolling updates
keep the available replicas up while replacing pods, and a soft topology-spread
constraint prefers separate nodes.

```sh
helm dependency build Ambient
helm lint Ambient
helm template core-dc1-talos-prod-business-ambient-prod Ambient --namespace core-prod --values Ambient/values.yaml >/tmp/core-business-ambient.yaml
```

Review the upstream [Moodist website](https://moodist.mvze.net/) and
[source](https://github.com/remvze/moodist), the [bjw-s common chart
documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/),
the [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/),
and [K8GB documentation](https://www.k8gb.io/). After reconciliation, validate
the gateway parent/listener, service target port, Gslb-to-route references,
DNS answers in both selected sites, audio playback and the deny-all egress
policy.

## Upstream projects

- [Moodist website](https://moodist.mvze.net/) and [source/documentation](https://github.com/remvze/moodist)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
- [K8GB documentation](https://www.k8gb.io/) and [source](https://github.com/k8gb-io/k8gb)
