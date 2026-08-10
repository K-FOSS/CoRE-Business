# CoRE Office

CoRE Office deploys the document and file-collaboration stack. The current
values enable Nextcloud, Collabora Online and a Stirling-PDF workload. Vikunja
configuration remains in the values file but is disabled.

This directory is a Lovely rendering unit: it contains a Helm chart and a
`kustomization.yaml` that adds the production environment label. Inspecting or
rendering Helm templates alone does not reproduce the complete Argo CD output.

## Deployment ownership

[The NextCloud ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml)
selects YVR bare-metal infrastructure clusters for the CoRE tenant. It deploys
this path to `core-prod`, enables namespace creation, preserves resources when
an ApplicationSet entry disappears, and injects the following through Lovely:

- Production environment, cluster name/domain, datacentre and region.
- The current `hub` role.
- `office.mylogin.space` as `nextcloud.nextcloud.host`.

Changing defaults without examining those injected values can produce a render
that differs from the deployed application.

## Components and request flow

```text
office.mylogin.space HTTPRoute
  -> Nextcloud nginx service
  -> Nextcloud FPM application and worker
  -> external PostgreSQL + platform Redis/S3

collabora.mylogin.space HTTPRoute
  -> Collabora Online
  -> WOPI requests to Nextcloud

pdf.mylogin.space HTTPRoute
  -> Stirling-PDF workload
```

- Nextcloud uses the FPM image with nginx enabled, a custom worker ReplicaSet,
  a 25 Gi `ReadWriteOnce` PVC on `ssd-storage`, and Velero backup annotations.
- The external PostgreSQL endpoint and `office-nextcloud-creds` Secret provide
  the application database path. The bundled PostgreSQL and MariaDB charts are
  disabled. The values currently show both `internalDatabase.enabled` and
  `externalDatabase.enabled`; confirm the effective chart behavior before an
  upgrade rather than assuming only one is active.
- `business-office-nextcloud-keys-prod` supplies Nextcloud administrator/token
  material. The custom encryption ExternalSecret reads platform-managed
  encryption configuration from `mainvault-core`.
- A CoRE `User` resource provisions the Nextcloud service identity.
- Gateway API HTTPRoutes expose Nextcloud and Collabora. An Envoy Gateway
  BackendTrafficPolicy adjusts the Nextcloud backend behavior.
- Collabora is configured for TLS termination at the gateway and permits the
  Nextcloud and Collabora hosts as WOPI aliases.
- The PDF workload uses the `frooodle/s-pdf` image and a mutable `latest` tag.

## Prerequisites

- Argo CD with the Lovely plugin and Helm/Kustomize support.
- Gateway API and the Envoy Gateway extension CRDs used by
  `BackendTrafficPolicy`.
- External Secrets with the `mainvault-core` ClusterSecretStore.
- The CoRE Crossplane `User` API and its providers.
- Shared PostgreSQL, Redis/Dragonfly, S3-compatible storage, DNS and TLS.
- A working `ssd-storage` StorageClass and backup coverage for the Nextcloud
  PVC and external data services.

## Security and durability notes

- The checked-in Collabora values contain example administrator credentials
  while `existingSecret` is disabled. They must not be considered production
  credentials; migrate administrator authentication to a Secret before relying
  on that interface.
- Collabora currently permits broad WOPI/post-allow host patterns. Review the
  rendered restrictions whenever hostnames or gateway topology change.
- The Nextcloud image uses the mutable `fpm-alpine` tag with `Always` pull
  policy, and the PDF image uses `latest`. A restart can therefore change
  software without a repository commit.
- Nextcloud persistence is `ReadWriteOnce`. Confirm scheduling and replacement
  behavior before changing replicas, zones, storage classes or claim identity.
- Database, object storage and PVC backups have different consistency needs.
  Validate a restore, not only backup-job completion.

## Validation

```sh
helm dependency build Office
helm lint Office
helm template core-business-office Office --values Office/values.yaml >/tmp/core-business-office-helm.yaml
kustomize build Office >/tmp/core-business-office-kustomize.yaml
git diff --check -- Office
```

Reproduce Lovely's actual composition order with the values from the linked
ApplicationSet. Review the output for literal credentials, secret-store names,
database selection, routes, WOPI hosts, PVC identity and security contexts.

After reconciliation, test:

1. OIDC login and service-user provisioning.
2. File upload, download, sharing and background jobs.
3. Collabora document open, edit and save through WOPI.
4. PDF conversion through the public route.
5. Database, Redis and object-storage connectivity.
6. Backup visibility and a representative restore procedure.

## Upstream projects

- [Nextcloud website](https://nextcloud.com/), [administrator documentation](https://docs.nextcloud.com/server/latest/admin_manual/) and [Helm chart](https://github.com/nextcloud/helm/tree/main/charts/nextcloud)
- [Collabora Online website](https://www.collaboraonline.com/), [SDK documentation](https://sdk.collaboraonline.com/docs/) and [Helm chart](https://github.com/CollaboraOnline/online/tree/main/kubernetes/helm/collabora-online)
- [Stirling website](https://www.stirling.com/), [documentation](https://docs.stirlingpdf.com/) and [source](https://github.com/Stirling-Tools/Stirling-PDF)
- [Vikunja website](https://vikunja.io/) and [documentation](https://vikunja.io/docs/)
- [External Secrets documentation](https://external-secrets.io/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
