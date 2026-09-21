# K-FOSS/CoRE-Business Personal/Tasks

This chart starts the personal task stack with
[Donetick](https://github.com/donetick/donetick), a self-hosted task and chore
manager, rendered through the
[BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).

## Current deployment

The chart uses the pinned Donetick `v0.1.79` image and exposes a private
Gateway API `HTTPRoute` at `tasks.mylogin.space`. It uses the site PostgreSQL
service through a Backplane `mylogin.space/v1alpha1 User` resource. The
generated database name is the generated connection Secret's `username` key,
so the application uses the same value for `DT_DATABASE_USER` and
`DT_DATABASE_NAME`. A retained 10Gi Longhorn PVC stores Donetick's local
uploads at `/donetick-data/uploads`; PostgreSQL stores task and account data.
The PVC uses the chart-owned `core-tasks-rwx` Longhorn StorageClass with
ReadWriteMany access, two replicas and `migratable: false`.
The upstream
[self-hosting configuration](https://github.com/donetick/donetick#quick-start)
uses port `2021` and a JWT secret of at least 32 characters.

The JWT is generated once by the
[External Secrets Password generator](https://external-secrets.io/latest/api/generator/password/)
and retained in `donetick-jwt`. Authentik is provisioned through its
[OAuth2/OIDC provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
by a Crossplane Terraform
[Workspace](https://docs.crossplane.io/latest/packages/providers/terraform/)
and restricted to the `Home Users` group; the generated
OIDC client Secret is consumed from the Workspace connection Secret. Password
authentication is disabled and Donetick's single-circle mode is enabled.
The configured Authentik authorization, token and userinfo URLs use the
provider's global `/application/o/` endpoints; the application slug is used
only for the provider/application identity and redirect registration.

No Backplane ApplicationSet currently selects `Personal/Tasks` in this
worktree. Before activation, add or confirm the owning ApplicationSet and
configure its Lovely renderer, destination namespace, Gateway attachment and
site-specific values, including `cluster.name`, `datacenter` and `region`.
The current storage definitions are the Backplane
[storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
and [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml);
PostgreSQL host/provider selection follows those injected site values; do not
replace it with local defaults. The User API contract is defined by the
Backplane [User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
Back up both the PostgreSQL database and the
uploads PVC before migration or deletion. The StorageClass is Retain and is
site-specific; do not rename it after provisioning without planning a volume
migration.

## Development and verification

```sh
helm dependency build Personal/Tasks
helm lint Personal/Tasks
helm template core-business-tasks Personal/Tasks --namespace core-tasks-prod \
  >/tmp/core-business-tasks.yaml
git diff --check
```

Review the rendered output for the image digest, private route labels, OIDC
and database Secret references, User resource provider names and the target
namespace before adding the ApplicationSet. After reconciliation, verify the
PostgreSQL/User and Authentik Workspace conditions, OIDC login, task creation,
logout/login, and database persistence.
