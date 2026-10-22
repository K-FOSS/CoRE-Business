# CoRE-Business Draw.io

This chart follows the CyberChef deployment pattern using the bjw-s common
library. It runs two replicas behind a ClusterIP Service and exposes each
hostname in `drawio.domains` through a Gateway API HTTPRoute carrying public
and private network-policy labels. The primary route is visible in the `Tools`
group of the `core` Forecastle instance under the friendly name `DrawIO`.

For global DNS balancing, the chart creates a second HTTPRoute for each host
under `k8gb.domain` and one `k8gb.io/v1beta1` `Gslb` per hostname. Each Gslb
references the generated secondary route and uses round-robin DNS with a
30-second TTL across the infrastructure clusters selected by the owning
ApplicationSet. K8GB's configured zones, DNS provider and hostname delegation
must cover these records. This chart does not create a `ZoneDelegation` or
change parent-zone DNS records. See the [K8GB resource reference](https://www.k8gb.io/latest/resource_ref/)
and [dynamic zone documentation](https://www.k8gb.io/latest/dynamic_zones/).

[The DrawIO ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Tools/DrawIO.yaml)
selects tenant bare-metal infrastructure clusters across sites and deploys to
`core-prod` without Lovely-injected values. Confirm that this selector includes
the intended global balancing sites and that each site's K8GB instance is
configured for the `gslb.mylogin.space` zone. Site-specific gateway, hostname,
replica and image settings are kept in `values.yaml`; workload configuration
lives in `templates/common.yaml`. The image is pinned to Draw.io 32.5.5's
multi-architecture Docker Hub manifest. The container runs non-root with a
RuntimeDefault seccomp profile, no service account token, disabled privilege
escalation and dropped Linux capabilities.
HTTP probes check port 8080, and an egress NetworkPolicy denies outbound
connections, matching the static web-app posture in CyberChef. Verify that
Draw.io's complete editing, export, embed and optional integration workflows
work under that restriction.

The pinned bjw-s common chart 5.0.1 requires Kubernetes 1.31 or newer and Helm
3.18 or newer in the deployment renderer; see the upstream
[v4-to-v5 upgrade guide](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/4-to-5/).

```sh
helm dependency build Tools/DrawIO
helm lint Tools/DrawIO
helm template core-business-drawio Tools/DrawIO --namespace core-prod --values Tools/DrawIO/values.yaml >/tmp/core-business-drawio.yaml
```

Review the upstream [draw.io project](https://github.com/jgraph/drawio) and
[bjw-s common chart](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common).
Review the [K8GB project](https://github.com/k8gb-io/k8gb) before changing
global DNS behavior. After reconciliation, validate every selected cluster,
the gateway parent/listener, service target port, Gslb-to-route references,
DNS answers and editing/export workflows.

## Upstream projects

- [draw.io website](https://www.drawio.com/) and [documentation](https://www.drawio.com/doc/)
- [draw.io source](https://github.com/jgraph/drawio)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
- [K8GB documentation](https://www.k8gb.io/)
