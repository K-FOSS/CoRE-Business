# CoRE Office

CoRE Office deploys the document and file-collaboration stack. The current
values enable Nextcloud, Collabora Online and a Stirling-PDF workload. Vikunja
configuration remains in the values file but is disabled.

This directory is a Lovely rendering unit: it contains a Helm chart and a
`kustomization.yaml` that adds the production environment label. Inspecting or
rendering Helm templates alone does not reproduce the complete Argo CD output.

## Deployment ownership

[The NextCloud ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml)
currently generates the Home1 YVR production Office Application in `core-prod`.
It enables namespace creation, preserves resources when an ApplicationSet
entry disappears, and injects the following through Lovely:

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
  -> external PostgreSQL + site-local Dragonfly/S3

collabora.mylogin.space ClusterIP Service
  -> Collabora Online
  -> WOPI requests to Nextcloud

pdf.mylogin.space HTTPRoute
  -> Stirling-PDF workload
```

- Nextcloud uses the FPM image with nginx enabled, a task-processing worker
  Deployment, and a separate five-minute CronJob for general `cron.php`
  background jobs. The web, worker, and CronJob use the same pinned Nextcloud
  35.0.1 Alpine FPM image digest. The worker and CronJob run as Alpine
  `www-data` (UID 82), use the chart's Nextcloud environment and config/PVC
  mounts, and have required pod affinity to the web pod so the `ReadWriteOnce`
  data PVC stays on the same node. The old standalone ReplicaSet has a different
  component selector; normal Argo CD pruning removes it during the kind change,
  and it cannot adopt the new Deployment's pods.
- The CronJob runs `php -f /var/www/html/cron.php` with
  `concurrencyPolicy: Forbid`, `OnFailure` pod restarts, two retries and bounded
  history. It has no short active deadline, so a legitimate longer cron run is
  not killed by Kubernetes. Nextcloud remains in Cron background-job mode.
- The persistent task worker runs `occ taskprocessing:worker` in a restart
  loop with a 60-second normal exit interval. This command is supported by the
  pinned Nextcloud 35 image (the command changed in Nextcloud 32.0.7). These
  command containers bypass the image entrypoint and therefore rely on the
  already initialized installation and configuration on the shared PVC and
  generated ConfigMaps.
- The external PostgreSQL endpoint and `office-nextcloud-creds` Secret provide
  the application database path. The bundled PostgreSQL and MariaDB charts are
  disabled. The values currently show both `internalDatabase.enabled` and
  `externalDatabase.enabled`; confirm the effective chart behavior before an
  upgrade rather than assuming only one is active.
- Nextcloud sends mail using `nextcloud.email`, currently
  `nextcloud-core-prod@mail.mylogin.space`, through `mail.mylogin.space:465`
  with implicit TLS and SMTP `LOGIN` authentication. The `mylogin.space` User
  resource takes its email from that same value. `WORKLOAD_ENV` is generated
  from `values.env`; both it and `nextcloud.email` are injected into the web,
  task-worker and cron containers through `office-nextcloud-workload-env`. The
  SMTP config checks that the sender's local part matches the workload
  environment. The SMTP username and password are read from the `username` and
  `password` keys of `office-nextcloud-creds`; no credential values are stored
  in chart values.
- `business-office-nextcloud-keys-prod` supplies Nextcloud administrator/token
  material. The custom encryption ExternalSecret reads platform-managed
  encryption configuration from `mainvault-core`.
- A CoRE `User` resource provisions the Nextcloud service identity and emits
  temporary S3 credentials into `office-nextcloud-s3-session`. A Crossplane
  Terraform Workspace uses the access key, secret key and session token to
  create a non-expiring MinIO service account for that identity. Its generated
  `AccessKey` and `SecretAccessKey` outputs are written to
  `office-nextcloud-s3-creds`, which is the Secret consumed by the main
  Nextcloud deployment and its custom worker.
- Nextcloud cache, distributed locks and file locking use the site-local
  [Dragonfly](https://www.dragonflydb.io/) service over TLS. Its password is
  copied by an [External Secrets](https://external-secrets.io/) resource from
  the Backplane-published `Storage/DragonFly/CoRE/.../Creds` path.
- Gateway API exposes Nextcloud, while ExternalDNS publishes the Collabora
  ClusterIP Service. An Envoy Gateway BackendTrafficPolicy adjusts the
  Nextcloud backend behavior.
- Collabora uses chart `1.3.1` and CODE image `26.04.3.1.1`. The Collabora
  service serves HTTPS directly on port 9980 using the site-local
  `myloginspace-default-certificates` Secret mounted read-only into the pod;
  startup, readiness and liveness probes use HTTPS as well. The certificate
  must cover `collabora.mylogin.space` and be present in the target namespace.
  Collabora's TLS CA path points to the image's system bundle at
  `/etc/ssl/certs/ca-certificates.crt`.
  Collabora permits the Nextcloud and
  Collabora hosts as WOPI aliases; WOPI and post requests are restricted to
  the Nextcloud host. The container runs with restricted capabilities and
  `RuntimeDefault` seccomp. Its configuration disables Collabora capability
  handling and jail bind mounts, and puts child-root and cache data under the
  writable `/tmp` volume to support that restricted runtime. Its Service is
  a `ClusterIP` with ExternalDNS
  annotations for `collabora.mylogin.space`.
- The PDF workload uses the `frooodle/s-pdf` image and a mutable `latest` tag.

## Prerequisites

- Argo CD with the Lovely plugin and Helm/Kustomize support.
- Gateway API and the Envoy Gateway extension CRDs used by
  `BackendTrafficPolicy`.
- ExternalDNS configured to publish `collabora.mylogin.space` to the internal
  ClusterIP, with client routing that can reach the cluster Service CIDR.
- External Secrets with the `mainvault-core` ClusterSecretStore.
- The site-local `myloginspace-default-certificates` TLS Secret in each target
  namespace, with `tls.crt` and `tls.key` entries for `collabora.mylogin.space`.
- The CoRE Crossplane `User` API and its providers.
- The Crossplane Terraform provider. This chart creates the credential-free
  `office-nextcloud-s3-session` ProviderConfig, with
  [`aminueza/minio` pinned to 3.40.1](https://registry.terraform.io/providers/aminueza/minio/3.40.1/docs),
  because the shared site ProviderConfig's older provider does not support
  authenticating with the `User` output's session token.
- Shared PostgreSQL, site-local [Dragonfly](https://www.dragonflydb.io/) with
  [TLS](https://www.dragonflydb.io/docs/managing-dragonfly/tls), S3-compatible
  storage, DNS and TLS.
- A working `ssd-storage` StorageClass and backup coverage for the Nextcloud
  PVC and external data services.

## Security and durability notes

- The checked-in Collabora values contain example administrator credentials
  while `existingSecret` is disabled. They must not be considered production
  credentials; migrate administrator authentication to a Secret before relying
  on that interface.
- Keep the rendered WOPI/post-allow restrictions aligned with the Nextcloud
  hostname whenever hostnames or gateway topology change.
- The Nextcloud image is pinned to the `35.0.1-fpm-alpine` linux/amd64 digest.
  The PDF image still uses the mutable `latest` tag. A PDF workload restart can
  therefore change software without a repository commit.
- Nextcloud persistence is `ReadWriteOnce`. Confirm scheduling and replacement
  behavior before changing replicas, zones, storage classes or claim identity.
- Database, object storage and PVC backups have different consistency needs.
  Validate a restore, not only backup-job completion.
- Deleting the credential Workspace or chart does not revoke the MinIO service
  account because its Crossplane deletion policy is `Orphan`. Revoke it
  explicitly during permanent decommissioning. Rotating the `User` session
  credentials lets Terraform reconcile the existing service account; it does
  not rotate Nextcloud's generated service-account secret by itself.

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
5. Database, Dragonfly cache/lock operations over TLS, and object-storage
   connectivity.
6. Backup visibility and a representative restore procedure.
7. The `nextcloud-s3-credentials` Workspace is ready and its connection Secret
   contains the expected key names; never print or decode their values.

Collabora does not need to be reachable from the public internet. It does need
to be reachable over HTTPS by every user's browser during editing, and the
Collabora pods need to reach Nextcloud for WOPI requests. A ClusterIP and
private DNS are suitable only when users' networks can route to the cluster
Service CIDR (for example through a VPN). A ClusterIP reachable only by
Nextcloud is insufficient because the browser also opens the Collabora editor
and WebSocket connection. ExternalDNS only publishes the name; it does not
provide routing or proxying. TLS terminates in Collabora using the mounted
site-local certificate.

## Upstream projects

- [Nextcloud website](https://nextcloud.com/), [administrator documentation](https://docs.nextcloud.com/server/latest/admin_manual/) and [Helm chart](https://github.com/nextcloud/helm/tree/main/charts/nextcloud)
- [Nextcloud background-job documentation](https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/background_jobs_configuration.html) and [AI task-processing worker documentation](https://docs.nextcloud.com/server/stable/admin_manual/ai/overview.html)
- [Pinned Nextcloud 35 Alpine FPM image](https://hub.docker.com/layers/library/nextcloud/35.0.1-fpm-alpine/images/sha256-f77b02a52251e408a4fbc232f27817eaedeb4acbf3c3dbd0daf72cf1e1c88601)
- [MinIO website](https://min.io/), [documentation](https://min.io/docs/minio/kubernetes/upstream/) and [`aminueza/minio` Terraform provider](https://registry.terraform.io/providers/aminueza/minio/3.40.1/docs)
- [Collabora Online website](https://www.collaboraonline.com/), [SDK documentation](https://sdk.collaboraonline.com/docs/) and [Helm chart](https://github.com/CollaboraOnline/online/tree/main/kubernetes/helm/collabora-online)
- [Stirling website](https://www.stirling.com/), [documentation](https://docs.stirlingpdf.com/) and [source](https://github.com/Stirling-Tools/Stirling-PDF)
- [Vikunja website](https://vikunja.io/) and [documentation](https://vikunja.io/docs/)
- [External Secrets documentation](https://external-secrets.io/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
