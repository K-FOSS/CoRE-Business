# CoRE Office

This rendering unit deploys the office stack, centered on Nextcloud and
Collabora, with supporting routes, workers, secrets and platform identity.
It combines Helm output with `kustomization.yaml`; inspecting Helm templates
alone is incomplete.

## Active deployment

[The NextCloud ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml) selects the YVR bare-metal
infrastructure cluster, injects cluster/site metadata and
`nextcloud.nextcloud.host`, and deploys to `core-prod` through Lovely.

The chart uses External Secrets, a CoRE `User`, HTTPRoutes and an Envoy Gateway
BackendTrafficPolicy. It also depends on shared PostgreSQL, Redis, object
storage, TLS/DNS, persistence and observability services.

## Validation and operations

```sh
helm dependency build Office
helm lint Office
helm template core-business-office Office --values Office/values.yaml >/tmp/core-business-office-helm.yaml
kustomize build Office >/tmp/core-business-office-kustomize.yaml
```

Reproduce Lovely's actual Helm/Kustomize order with Backplane-injected values.
Review encryption-secret handling, Nextcloud host/trusted domains, Collabora
WOPI settings, worker storage mounts, database/Redis/S3 endpoints and route
policies. Before upgrades, read the authoritative [Nextcloud chart](https://github.com/nextcloud/helm/tree/main/charts/nextcloud)
and [Collabora chart](https://github.com/CollaboraOnline/online/tree/main/kubernetes/helm/collabora-online)
documentation. Validate login, file upload/download, background jobs, previews
and collaborative editing after reconciliation.

## Upstream projects

- [Nextcloud website](https://nextcloud.com/), [administrator documentation](https://docs.nextcloud.com/server/latest/admin_manual/) and [Helm chart](https://github.com/nextcloud/helm/tree/main/charts/nextcloud)
- [Collabora Online website](https://www.collaboraonline.com/), [SDK documentation](https://sdk.collaboraonline.com/docs/) and [Helm chart](https://github.com/CollaboraOnline/online/tree/main/kubernetes/helm/collabora-online)
- [Vikunja website](https://vikunja.io/) and [documentation](https://vikunja.io/docs/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
