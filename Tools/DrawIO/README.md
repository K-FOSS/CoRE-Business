# CoRE Draw.io

This chart deploys Draw.io through the bjw-s common library. It exposes
`draw.mylogin.space` through a ClusterIP Service and Gateway API HTTPRoute with
public and private network-policy labels.

[The DrawIO ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/DrawIO.yaml) selects tenant bare-metal
infrastructure clusters across sites and deploys to `core-prod` without
Lovely-injected values. The image currently uses a mutable `latest` tag and
health probes are disabled; treat both as deployment risks when updating it.

```sh
helm dependency build Tools/DrawIO
helm lint Tools/DrawIO
helm template core-business-drawio Tools/DrawIO --values Tools/DrawIO/values.yaml >/tmp/core-business-drawio.yaml
```

Review the upstream [draw.io repository](https://github.com/jgraph/drawio) and
[bjw-s common chart](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common).
Validate every selected cluster, the gateway parent/listener, service target
port and editing/export workflows after reconciliation.

## Upstream projects

- [draw.io website](https://www.drawio.com/) and [documentation](https://www.drawio.com/doc/)
- [draw.io source](https://github.com/jgraph/drawio)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
