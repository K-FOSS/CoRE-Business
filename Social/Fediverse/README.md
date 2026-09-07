# CoRE-Business/Social/Fediverse

This chart deploys the official [Mastodon](https://joinmastodon.org/) image as a
small Kubernetes instance using the [BJW-S Common library
chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/) 5.0.1.
Mastodon web, streaming, Sidekiq and database migrations are rendered through
Common. The public [Gateway API](https://gateway-api.sigs.k8s.io/) route sends
`/api/v1/streaming` to Mastodon’s streaming process and all other paths to web.
The web, Sidekiq and migration workloads use the Mastodon 4.7.0 image pinned to
an immutable GHCR manifest digest. Streaming uses Mastodon’s separate
`mastodon-streaming` 4.7.0 image, also pinned to its immutable digest; the
official container documentation uses that image for the streaming process.

## Ownership and activation

The active owner is the [Fediverse ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Social/Fediverse.yaml)
in CoRE-Backplane. Its merge generator selects `core-home1-talos-prod` when the
cluster has tenant `core.mylogin.space`, bare-metal infrastructure and region
`yvr`; it renders this repository at `targetRevision: HEAD` with the
`argocd-lovely-plugin`, targets namespace `core-prod`, and preserves resources
when the ApplicationSet is deleted. The ApplicationSet currently supplies the
environment, cluster, datacenter, region, `mastodon.mylogin.space` hostname,
`main-gw`/`https-myloginspace` Gateway attachment, and the PostgreSQL and S3
provider names. `examples/site.yaml` mirrors those production merge values for
local rendering; it contains no credentials.

The PostgreSQL and object-storage prerequisites are owned by the
[storage PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
and [storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).
The claim follows the current [mylogin.space User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
Those prerequisites must be healthy before the application can become ready:
the `User` claim creates the `mastodon_production` database and
`mastodon-media` bucket, then writes PostgreSQL/S3 connection material to
namespace-local Secrets.

The chart renders the following application resources in `core-prod`: web,
streaming and Sidekiq Deployments; a migration Job and one-shot VAPID/encryption
bootstrap Job; the web and streaming Services; an `HTTPRoute`; the
`mylogin.space/v1alpha1` `User`; an Authentik Crossplane `Workspace`; External
Secrets, PushSecrets and a Password generator; and the VAPID ServiceAccount,
Role and RoleBinding. The checked-in chart is the complete rendering unit, so
changes to routing, persistence, secrets or identity should be reviewed against
all of these resources rather than against `templates/` in isolation.

## Secrets and identity

No credentials are generated in Helm values. Following the [Backplane Dragonfly
secret pattern](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Storage/Dragonfly/CoRE/templates),
External Secrets uses a `Password` generator and a `CreatedOnce` generator-backed
ExternalSecret to create a one-time bootstrap Secret containing Mastodon
`SECRET_KEY_BASE` and `OTP_SECRET`. PushSecret persists them to the configured
Vault path, and another ExternalSecret recreates the runtime Secret from Vault.
A one-shot
Mastodon bootstrap Job runs the official VAPID generator, writes the valid key
pair to a namespace-local bootstrap Secret, and PushSecret persists that pair
to the same Vault record. External Secrets then recreates the runtime Secret
from Vault. The Vault record uses
`Social/Fediverse/<region>/<datacenter>/<cluster>/Mastodon` by default.
The same one-shot bootstrap runs Mastodon’s `db:encryption:init` task and
stores `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`,
`ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, and
`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` in that Vault record; these values must
never be regenerated for an existing database.

The Dragonfly password is pulled from the site-local path published by the
[CoRE Dragonfly chart](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Storage/Dragonfly/CoRE):
`Storage/DragonFly/CoRE/<region>/<datacenter>/<cluster>/Creds`. No runtime
Secret values belong in Git.

The `User` claim writes PostgreSQL `username` and `password` to
`mastodon.user.connectionSecretName`; the database name is the explicit
`mastodon.psql.database` value. Its service-account S3 credentials are
written to `mastodon.user.s3CredentialsSecretName` as `AccessKey` and
`SecretAccessKey`. Do not copy those values into Git or logs.
Mastodon uses Authentik's OIDC `preferred_username` claim as the external
identity key, while email and profile data come from the `email` and `profile`
scopes. It reuses the User claim's LDAP username and password for SMTP
authentication against `mail.mylogin.space` on implicit-TLS port 465; the
runtime Secret does not contain separate mail credentials.
`PREPARED_STATEMENTS=false` is set because the site PostgreSQL connection may
pass through transaction pooling; Mastodon documents that prepared statements
are incompatible with that mode.

The PostgreSQL hostname is automatically formed as
`psql-local.<cluster>.<datacenter>.<region>.mylogin.space`; the Dragonfly
hostname is automatically formed as
`dragonfly.<cluster>.<datacenter>.<region>.mylogin.space`. Both can be explicitly
overridden through `mastodon.psql.host` or `redis.host` when a site topology
requires it.
All Mastodon Redis clients use the TLS-enabled `rediss://` URL, Ruby Redis
driver, and the Secret-backed Dragonfly password; this includes Rails cache,
websocket/streaming, Sidekiq and migrations. Mastodon requires this URL scheme
and driver combination for Redis TLS.

The S3 endpoint and public media hostname are automatically formed as
`s3.<cluster>.<datacenter>.<region>.mylogin.space` and use HTTPS; S3 credentials
remain sourced from the generated service-account Secret. Requests use
path-style bucket URLs (`/bucket/key`) rather than bucket subdomains. Mastodon
4.7.0 inverts `S3_OVERRIDE_PATH_STYLE` when passing this option to the AWS SDK,
so the chart deliberately sets it to `false`.
`S3_PERMISSION` is empty so Mastodon does not send a `public-read` object ACL;
the Backplane-managed bucket policy provides object access without ACL APIs.

The official Mastodon image requires its `/opt/mastodon` working directory to be
writable, so its containers retain a writable root filesystem while running
non-root with dropped capabilities, RuntimeDefault seccomp and an isolated
`/tmp` volume. The VAPID bootstrap ServiceAccount is bound to the namespace
Secret Role using the name generated by BJW-S Common.
Argo CD orders platform prerequisites and generators at wave `-10`, runs the
VAPID bootstrap Sync hook at `-5`, publishes and pulls generated Secrets at
waves `0` and `5`, runs database initialization at `10`, and starts the web,
streaming and Sidekiq Deployments at `20`. This ensures the init Job consumes
the generated runtime Secrets.
Web, streaming and Sidekiq use `RollingUpdate` with `maxUnavailable: 0` and
`maxSurge: 1`. Web and streaming expose HTTP startup/readiness/liveness checks;
the streaming Service port advertises `appProtocol: kubernetes.io/ws` so the
Envoy Gateway preserves websocket upgrades.
Sidekiq uses a process-existence startup/readiness/liveness check modeled on
Mastodon’s container deployment guidance.

The Authentik [Terraform provider](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs)
is reconciled by a Crossplane `tf.upbound.io/v1beta1` `Workspace`. It creates a
confidential OIDC provider, application, `Mastodon Users` group, entitlement and
bindings. The generated client values are consumed from the Workspace
connection Secret. `OMNIAUTH_ONLY` is enabled by default, so membership in the
Authentik access group is the login path; add users to that group deliberately.
The callback is `https://<domain>/auth/auth/openid_connect/callback`.

Mastodon’s public federation and API paths must remain reachable without an
Authentik gateway policy. The application itself enforces OIDC login. If
`oidc.assumeEmailIsVerified` is enabled, only do so when the identity provider
authoritatively verifies email addresses.

## Storage and lifecycle

PostgreSQL is the durable application store and S3 is the durable media store;
there is intentionally no application PVC. Mastodon requires S3-compatible
access to the bucket, and the selected provider must support the configured
signature/path-style behavior and public media reads as described in the
[Mastodon object-storage documentation](https://docs.joinmastodon.org/admin/optional/object-storage/).
The `/tmp` `emptyDir` only holds transient upload and processing files and is
safe to lose during a rollout; a media RWO/RWX volume would not replace S3.
The User claim and S3 credential Secret have Argo `Prune=false,Delete=false`
semantics so removing the application does not implicitly delete identity or
data. Deliberately decommission the database, bucket and credentials only after
an explicit backup and retention review.

The `mastodon` User also enables the XRD's separate S3 credential-generation
path and writes its result to `mastodon-s3-user-generated`. That Secret is a
diagnostic comparison only; Mastodon continues using the service-account
credentials in `mastodon-s3-user`.

The migration Job must complete before web/streaming/Sidekiq is considered
healthy. Database migrations can be irreversible across releases: back up the
PostgreSQL database and retain the generated Mastodon Vault record before
upgrades. The bootstrap Job is intentionally idempotent: it exits when the
VAPID bootstrap Secret already exists, preserving VAPID and Active Record
encryption keys. Never delete or regenerate that Secret or its Vault record for
an existing database. Follow Mastodon’s
[backup](https://docs.joinmastodon.org/admin/backups/) and
[upgrade](https://docs.joinmastodon.org/admin/upgrading/) guidance.

For a failed rollout, inspect the migration Job and the generated Secret
conditions before restarting workloads. Restore PostgreSQL and the retained
Vault record together when recovering an instance; restoring the database
without its Mastodon encryption keys can make encrypted application data
unreadable. If the application is deliberately decommissioned, preserve the
`User`, database, bucket and Vault record until backups and retention have been
verified. The ApplicationSets preserve their resources on deletion, and the
chart marks the identity/data resources and generated secrets as retained, so
cleanup is an explicit storage and identity operation rather than an Argo prune
side effect.

## Validation

From this directory:

```sh
helm dependency build .
helm lint . -f examples/site.yaml
helm template mastodon . --namespace core-prod -f examples/site.yaml \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute >/tmp/mastodon-rendered.yaml
git diff --check
```

Inspect the complete render for the destination namespace, gateway listener,
Secret references, public route, provider names and absence of literal Secret
data. After Argo CD applies the active ApplicationSet, verify the User claim,
PostgreSQL Role/Database, S3 bucket/service account, Authentik Workspace,
HTTPRoute `Accepted`/`ResolvedRefs`, migration Job and all workload probes.
Then verify trusted TLS, OIDC login, email confirmation, media upload, and
remote ActivityPub federation from an unrelated account.

The upstream references for this stack are [Mastodon source and releases](https://github.com/mastodon/mastodon),
[Mastodon configuration](https://docs.joinmastodon.org/admin/config/),
[External Secrets Operator generators](https://external-secrets.io/latest/api/generator/password/)
and [PushSecret](https://external-secrets.io/latest/api/pushsecret/),
[Crossplane](https://www.crossplane.io/docs/),
[Crossplane Terraform provider](https://github.com/crossplane-contrib/provider-terraform),
[Authentik](https://goauthentik.io/) and [its OIDC provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/).
