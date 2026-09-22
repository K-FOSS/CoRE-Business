# K-FOSS/CoRE-Business Personal/Tasks

This chart starts the personal task stack with
[Donetick](https://github.com/donetick/donetick), a self-hosted task and chore
manager, and [HabitSync](https://github.com/jofoerster/habitsync), a
self-hosted habit tracker, rendered through the
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
only for the provider/application identity and redirect registration. Donetick's
web redirect URI is `/auth/oauth2`; the frontend exchanges the returned code
with the API at `/api/v1/auth/oauth2/callback`.

HabitSync is deployed at `habits.mylogin.space` using the pinned upstream
`0.19.3` image. It uses PostgreSQL through its own Backplane User resource;
the generated connection Secret's `username` is used as both the PostgreSQL
username and database name. Its Authentik provider is a public PKCE client
with the strict redirect URI `https://habits.mylogin.space/auth-callback`,
restricted to `Home Users`. HabitSync uses its own retained JWT Secret and
does not share Donetick's credentials. Its upstream entrypoint must start as
root to create UID/GID `6842`, repair `/data` ownership, and then drop to that
UID/GID with `su-exec`; the chart grants only the required bootstrap
capabilities and keeps the application process unprivileged.
The HabitSync issuer URL intentionally retains Authentik's trailing `/` so
Spring Security's issuer validation matches the discovery document.

Both HTTPRoutes are protected by Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/latest/api/gateway_api/v1alpha1/securitypolicy/)
resources using
the site Authentik forward-auth outpost Service
[`aaa-myloginspace-proxy`](https://docs.goauthentik.io/add-secure-apps/providers/proxy/forward_auth/)
in `core-prod`. The policies fail closed and forward
the Authentik session and identity headers to the applications. The outpost
must remain available for either application to be reachable.
Dedicated Authentik forward-auth Workspaces create `forward_single` proxy
providers for both hostnames and bind access to `Home Users`; the OIDC
Workspaces remain separate application login clients. The forward-auth
applications set Authentik's `meta_hide` flag, so they do not appear in users'
Application Dashboard while remaining available to the outpost.

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
Back up both application databases and the
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

Review the rendered output for both image digests, private route labels, OIDC
and database Secret references, User resource provider names and the target
namespace before adding the ApplicationSet. After reconciliation, verify both
PostgreSQL/User and Authentik Workspace conditions, OIDC login, task/habit
creation, logout/login, and database persistence.

HabitSync’s upstream [deployment and OIDC configuration](https://github.com/jofoerster/habitsync#docker-compose-recommended-for-production-use)
and [PostgreSQL settings](https://github.com/jofoerster/habitsync#database-and-backups)
are the application contract used by this chart.
