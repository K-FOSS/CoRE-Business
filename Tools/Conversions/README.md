# CoRE SnapOtter conversions

This Helm chart runs [SnapOtter](https://snapotter.com/) at
`https://conotter.mylogin.space` using the same BJW-S Common 5.0.1 loader
structure as CyberChef. It pins the application to
[SnapOtter 2.2.0](https://github.com/snapotter-hq/SnapOtter/releases/tag/v2.2.0).
See the [release source](https://github.com/snapotter-hq/SnapOtter/tree/v2.2.0),
[deployment documentation](https://docs.snapotter.com/guide/deployment), and
[BJW-S Common documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).

## Deployment ownership and prerequisites

As checked on 2026-09-07, no active Backplane ApplicationSet references
`Tools/Conversions`. Adding this chart alone does not deploy the endpoint.
The [Cyberchef ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Cyberchef.yaml)
is the structural reference: native Helm, `core-prod`, no injected values,
and tenant `core.mylogin.space` bare-metal infrastructure clusters. SnapOtter
has local persistent state, so its new Backplane owner must select **one**
intended cluster, set `source.path: Tools/Conversions`, and supply any site
overrides. `cluster.name`, `datacenter` and `region` are required when either
automation is enabled; they intentionally have no deployable default. Mirror
the identity value layer injected by the
[AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml)
(which owns GPUStack):

```yaml
cluster:
  name: 'core-home1-talos-prod'
datacenter: 'home1'
region: 'yvr'
```

This is a representative Home1 layer, not a new fleet owner. Do not copy
CyberChef's fleet-wide selector unchanged: independent instances behind one
hostname would have different files and sessions.

The complete rendering unit is `Chart.yaml`, `values.yaml` and
`templates/`; there are no Kustomize or Lovely layers. Standard Kubernetes
resources use BJW-S Common. The `User` and Terraform `Workspace` use direct
templates because they are operator-specific APIs without Common resource
classes. Kubernetes 1.31+ and Helm 3.18+ are required by the pinned common
library. Provision:

- A `core-prod` namespace and `main-gw` Gateway in `core-prod`, with the
  `https-myloginspace` listener, matching DNS/TLS and permission to attach this
  route. Gateway API v1 HTTPRoute and request timeouts are supported by the
  Backplane Envoy Gateway 1.8.3 dependency. See
  [Gateway API](https://gateway-api.sigs.k8s.io/) and
  [Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/).
- A `longhorn` StorageClass with room for the 50 GiB data claim. The
  [storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
  installs the site storage configuration; its default Longhorn class has
  two replicas and a `Delete` reclaim policy. See
  [Longhorn](https://longhorn.io/) and its
  [documentation](https://longhorn.io/docs/).
- The CoRE `mylogin.space/v1alpha1` User API and site-local SQL/Terraform
  providers from the
  [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
  `snapotter.psql.enabled` defaults to true. A service-account User claim
  creates the role and its owned database, joins `LDAPService`, and publishes
  `username` and `password` in
  `<release>-snapotter-user`. The database name equals the generated username;
  the current composition does not publish a separate `database` key even
  though the XRD lists it. Both provider names default to
  `psql-<datacenter>-<region>`, and the workload connects to
  `psql-local.<cluster.name>.<datacenter>.<region>.mylogin.space:5432`.
  Host, port and providers can be overridden under `snapotter.psql`.
  This follows GPUStack's design and the current
  [User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
  SnapOtter 2.2.0 uses this database for both migrations and runtime access;
  the claim-created role owns it. `psql-local` is the site PostgreSQL master
  Service hostname, not the PGPool endpoint. The target must be writable:
  current Backplane configuration selects Home1/YVR as the PostgreSQL hub
  and DC1 sites as standbys. Use the Home1 layer above for that deployment;
  rendering another site is not proof it can provision or migrate a database.
  Any host override must preserve sessions for migration advisory locks. The current User
  composition generates URI-safe credential characters, allowing ordered
  Kubernetes environment expansion as in GPUStack; revisit URL encoding if
  that generator changes. Upstream targets
  [PostgreSQL 17](https://www.postgresql.org/docs/17/)
  ([project website](https://www.postgresql.org/)).
- The `tf.upbound.io/v1beta1` Workspace API from
  [Crossplane provider-terraform](https://github.com/upbound/provider-terraform)
  ([Crossplane website](https://www.crossplane.io/)) and the existing
  `authentik` ProviderConfig. `snapotter.oidc.enabled` defaults to true.
  The Workspace creates a confidential OAuth2 provider, application, random
  client secret, `SnapOtter Users` group, entitlement and group bindings,
  matching GPUStack. It uses the existing `tls` signing certificate and
  default explicit-consent/invalidation flows. Client ID and application
  slug include region, datacenter and cluster identity; the group's name is
  configurable and must have a single automation owner. The ProviderConfig
  supplies Authentik authentication and provider version 2025.10.1.
  See [Authentik](https://goauthentik.io/), its
  [OAuth2/OIDC documentation](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/),
  and [Terraform provider source](https://github.com/goauthentik/terraform-provider-authentik).
- A dedicated persistent [Redis](https://redis.io/) 8 queue service with
  authentication and `noeviction`, following
  [Redis persistence documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/).
  Shared Dragonfly compatibility is not assumed. Redis provisioning remains
  outside this application chart.
- The namespace-local Secret named by `snapotter.existingSecret`, defaulting
  to `snapotter-runtime`. Deliver it through platform secret automation such
  as [External Secrets](https://external-secrets.io/) using its
  [ExternalSecret API](https://external-secrets.io/latest/api/externalsecret/).
  Required keys are `REDIS_URL`, `DEFAULT_PASSWORD`, and `COOKIE_SECRET`.
  With `snapotter.psql.enabled: false`, `DATABASE_URL` is also required and
  no User claim is rendered. URLs must include provisioned service credentials;
  use a strong bootstrap password and stable random cookie secret. Never
  place their values in Helm values or Git. An empty Secret name fails Helm
  validation; absent Secrets or keys prevent container startup.

## Runtime and access

BJW-S generates one Deployment, ServiceAccount, ClusterIP Service, PVC and
HTTPRoute. Separate templates generate the User claim and OIDC Workspace
when enabled. The Service forwards port 80 to 1349. The route carries
CyberChef's
`wan-mode: public` and `lan-mode: private` labels and a 600-second timeout;
these labels do not provide authentication. The Workspace writes
`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` and `OIDC_ISSUER_URL` to
`<release>-snapotter-oidc`; the container consumes those fields directly.
Helm never renders credential values. The issuer ends in the generated
application slug, and the strict redirect is
`https://conotter.mylogin.space/api/auth/oidc/callback`. `EXTERNAL_URL` and the
redirect are derived from the same domain setting. See
[SnapOtter 2.2.0 OIDC documentation](https://github.com/snapotter-hq/SnapOtter/blob/v2.2.0/apps/docs/guide/oidc.md).

Grant SSO access by adding approved users to `SnapOtter Users` in Authentik.
The group is not a superuser group, and both application and entitlement are
bound to it. SnapOtter auto-creates ordinary `user` accounts on first SSO
login; email-based account auto-linking is disabled. Group membership does
not grant SnapOtter admin access. Local username/password login remains
available for recovery, with a required bootstrap password and upstream
first-login password change. Removing an Authentik group membership blocks
future SSO authorizations but does not revoke existing SnapOtter sessions or
local accounts; deprovision those in SnapOtter as well. Setting
`snapotter.oidc.enabled: false` removes the managed OIDC resources on
reconciliation and leaves local login enabled.

The container runs as UID/GID 1000 with matching volume fsGroup, no privilege
escalation or Linux capabilities, RuntimeDefault seccomp and no mounted
ServiceAccount token. External database mode supports non-root startup;
embedded mode is not used. Startup allows ten minutes for initialization,
and HTTP health probes check `/api/v1/health`. Telemetry is disabled through
`SNAPOTTER_TELEMETRY=0`. Egress is needed for databases, Redis and optional AI
bundle downloads; CyberChef's deny-all egress policy is not suitable here.
No GPU is requested. Resource limits allow CPU conversion and optional AI
workloads; tune them against real files and concurrent usage.

`/data` holds user files and AI bundles on the persistent volume.
`/tmp/workspace` is a bounded 10 GiB ephemeral workspace and `/dev/shm` is a
2 GiB memory volume, charged against the container memory limit. Uploaded
files follow SnapOtter's retention settings; persistence is not archival.
Uploads default to 100 MB per file. Domain, gateway, image, credentials
reference, storage capacity and resource limits are values-driven.

## Verification and recovery

Save the representative site layer above as `/tmp/snapotter-site.yaml`, or
use the actual target's injected values:

```sh
helm dependency build Tools/Conversions
helm lint Tools/Conversions --values /tmp/snapotter-site.yaml
helm template core-business-conversions Tools/Conversions --namespace core-prod \
  --values /tmp/snapotter-site.yaml \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  >/tmp/core-business-conversions.yaml
git diff --check
```

A render without the required site identity fails intentionally. Validate
both enabled and disabled automation modes, and check the embedded Terraform
against the Authentik 2025.10.1 provider schema.
The API capability flag reproduces the installed Gateway API; offline Helm
otherwise makes Common fall back to v1alpha2. Review the whole render for
Secret references, namespace, selectors, route backend and storage mounts.
Do not force-add generated `Chart.lock` or `charts/` files.

After Argo reconciliation, follow the User/XUser, generated PostgreSQL
Role/Database and OIDC Workspace until their Ready/Synced conditions are
healthy and both generated Secrets exist (check key names only). Missing
connection Secrets keep the application from starting. Check the PVC is
bound, the pod is ready, and the HTTPRoute reports `Accepted` and
`ResolvedRefs`. Verify HTTPS, local login/password
change, SSO login with an allowed member, rejection of a non-member,
ordinary-user role assignment, an image conversion, a longer conversion,
download and persistence after a pod restart. Check database and queue health as well as Argo status.
No cluster reconciliation or live workflow verification has been performed
as part of adding this chart.

One replica and `Recreate` avoid concurrent writers on the RWO claim; upgrades
interrupt service and may interrupt active jobs. Back up PostgreSQL and
`/data` together before upgrades, and retain Redis queue data as appropriate.
Roll back via Git/Argo only after checking database migration compatibility;
an image rollback alone may not reverse schema changes. The PVC carries
`helm.sh/resource-policy: keep` and Argo `Prune=false,Delete=false` annotations
so removing the chart retains it. Explicitly deleting the PVC can delete the
underlying Longhorn volume. The User claim also carries
Argo `Prune=false,Delete=false` and must be explicitly decommissioned; the
current User composition orphans PostgreSQL roles/databases on deletion.
Preserve the claim and its connection Secret to preserve access. Disabling
database automation does not migrate data: provision the fallback URL for
the same database or perform an explicit data migration. OIDC Workspace
removal destroys its managed Authentik application/provider/group and client
credentials; do not delete it before confirming local recovery access. Site
identity, release-name or application-slug changes can rename or replace
managed resources; treat them as migrations. Redis and the residual runtime
Secret remain separately owned.
