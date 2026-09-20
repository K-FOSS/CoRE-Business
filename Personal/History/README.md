# Personal History

This prepared chart deploys [Dawarich](https://dawarich.app/), a self-hosted
location-history application, using the [BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It runs Dawarich's web and Sidekiq processes, publishes
`dawarich.mylogin.space` through a Gateway API HTTPRoute, and retains imports,
exports and application storage on Longhorn PVCs.

The app Pod has a dedicated migration init container using Dawarich's official
`web-entrypoint.sh`; it waits for PostgreSQL, runs primary/data migrations and
seeds before the web container starts. Dawarich's web entrypoint remains on the
web container as an idempotent upgrade safeguard, while Sidekiq waits for the
same database to become available.

The chart uses the pinned upstream `freikin/dawarich:1.14.5` image. PostgreSQL
is provisioned through the CoRE `User` resource: the composition creates a
username-owned database and the chart uses the generated `username` Secret key
as `DATABASE_NAME`. It uses the automatically derived site-local
`psql-<datacenter>-<region>` providers and does not deploy a database. Dawarich
connects to the matching
`psql-local.<cluster>.<datacenter>.<region>.mylogin.space` endpoint. Redis is the existing site-local
Dragonfly service. The chart reads the Dragonfly password from the Backplane
Vault secret store and constructs a TLS Redis URL for logical database 152.
The owning deployment must ensure the [Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml)
and [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
are active for the selected cluster.

Authentik OAuth2/OIDC is created by a Crossplane Terraform `Workspace` using
the site `authentik` ProviderConfig. The generated client credentials are
written to the Workspace connection Secret and consumed by both Dawarich
containers. The callback is
`https://dawarich.mylogin.space/users/auth/openid_connect/callback`; the
application is configured for OIDC-only login and automatic account creation.
Review the access group and issuer values before activation.

There is currently no active [Personal History ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Apps/Business/Personal)
referencing `Personal/History`, so this is prepared desired state. A future
owner must inject `cluster.name`, `datacenter`, `region`, destination namespace
and the Lovely renderer. It must also
confirm the `main-gw` / `https-myloginspace` listener and the target cluster's
Dragonfly Vault path.

Build and render with representative site values:

```sh
helm dependency build Personal/History
helm lint Personal/History \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=home1 \
  --set region=yvr
helm template core-business-history Personal/History --namespace core-history-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=home1 \
  --set region=yvr \
  >/tmp/core-business-history.yaml
```

Review the [Dawarich self-hosting guide](https://dawarich.app/docs/self-hosting/introduction/),
[Dawarich environment variables](https://dawarich.app/docs/self-hosting/environment-variables/),
[Dawarich OIDC guide](https://dawarich.app/docs/self-hosting/configuration/oidc-authentication/),
[Dawarich source repository](https://github.com/Freika/dawarich),
[Authentik OAuth2 provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/),
[Crossplane Terraform Workspace](https://marketplace.upbound.io/providers/upbound/provider-terraform),
[Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/), and
[External Secrets](https://external-secrets.io/latest/).

After activation, verify the User and Workspace conditions, ExternalSecret
readiness, PostgreSQL migrations, Dragonfly TLS connectivity, OIDC callback,
location import, background processing and restoration of all three PVCs.
Removing the chart preserves the PVCs, generated runtime secret and database
connection Secret; treat those retained resources as a deliberate migration
and deletion decision.
