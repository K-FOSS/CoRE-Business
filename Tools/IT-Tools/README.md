# CoRE IT-Tools

This chart deploys [IT-Tools](https://it-tools.tech/) through the
[BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It runs two stateless replicas behind a ClusterIP Service and exposes
`it-tools.mylogin.space` through a Gateway API HTTPRoute attached to the
`main-gw` `https-myloginspace` listener. The route is discoverable in the
`Tools` group of the `core` Forecastle instance.

The official image is pinned to release `2024.10.22-7ca5933` and its published
GHCR digest. The workload does not need persistent storage, runtime secrets or
egress; the egress NetworkPolicy therefore denies outbound traffic. Service
account token mounting is disabled, and the container drops all capabilities
except `CHOWN`, `SETGID`, and `SETUID`, which the bundled nginx entrypoint uses
to prepare its cache and run workers as the nginx user.

The active owner is the
[CoRE-Backplane IT-Tools ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/IT-Tools.yaml).
It renders this chart from the `HEAD` revision of `CoRE-Business` on clusters
matching `mylogin.space/tenant: core.mylogin.space`,
`resolvemy.host/computetype: baremetal`,
`resolvemy.host/nodetype: infra`, and
`topology.kubernetes.io/region: yvr`. The generator injects the selected
cluster name and `prod` environment; the destination namespace is therefore
`core-prod`. Argo CD creates the namespace and uses server-side apply.

The ApplicationSet preserves resources when the generated Application is
deleted. Removing IT-Tools therefore requires an explicit cleanup decision;
do not assume ApplicationSet deletion removes the workload.

```sh
helm dependency build Tools/IT-Tools
helm lint Tools/IT-Tools
helm template core-business-it-tools Tools/IT-Tools --namespace core-prod \
  --values Tools/IT-Tools/values.yaml >/tmp/core-business-it-tools.yaml
```

Review the upstream [IT-Tools source repository](https://github.com/CorentinTh/it-tools),
[IT-Tools self-hosting documentation](https://github.com/CorentinTh/it-tools#self-host),
the [BJW-S common chart](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common),
and the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) documentation.
After activation, validate the gateway parent/listener, service port, replica
distribution, browser loading, clipboard access and representative tools.
