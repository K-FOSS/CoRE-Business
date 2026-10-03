# CoRE Vaultwarden

This chart deploys the upstream [Vaultwarden](https://www.vaultwarden.net/)
container with the [BJW-S common library
chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/). The active
[VaultWarden ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/VaultWarden.yaml)
renders the chart with Lovely into `core-prod` on the selected bare-metal
clusters.

The public HTTPRoute is annotated for discovery by the `core` Forecastle
instance.

## Identity and PostgreSQL

Vaultwarden uses the current [`mylogin.space/v1alpha1` User
claim](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
The claim enables PostgreSQL explicitly, grants the stable `bitwarden`
database to the stable `vaultwarden-prod` service account and selects the
site's `psql-<datacenter>-<region>` Crossplane and Terraform providers. Its
connection Secret supplies only the username, password and database name to
the workload; the chart builds `DATABASE_URL` with the target cluster's
site-local PGPool endpoint.

On the hub, a `PushSecret` publishes those three connection fields to
`vaultwarden.credentialsSync.remoteKey` in the configured ClusterSecretStore.
Spokes omit the User claim and use an `ExternalSecret` to recreate the same
local connection Secret from that remote record. The push uses `deletionPolicy:
None`, and spoke targets use `creationPolicy: Orphan` with `deletionPolicy:
Retain`, so chart removal does not delete the shared credential record or the
last locally synced credentials. Deliberate decommissioning therefore requires
deleting or revoking both copies.

The owning ApplicationSet must inject `cluster.name`, `datacenter`, `region`,
`vaultwarden.psql.host`, both optional provider overrides when their names do
not follow the site convention, and `vaultwarden.user.enabled`. Enable the
User only where `cluster.name` equals `vaultwarden.user.hubCluster`; the chart
checks both values and otherwise omits the claim. The current hub and each
site's PGPool topology are defined by the [PostgreSQL
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
Storage prerequisites remain owned by the [storage base
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).

The database role and database use orphaning provider behavior, so removing the
claim or chart does not by itself remove PostgreSQL data. Vaultwarden's `/data`
mount uses a 1 GiB Longhorn `ReadWriteOnce` PVC, which preserves its RSA private
key across pod replacement and lets mobile clients continue using their
existing sessions. Attachments, sends and icon cache also persist there. The
PVC is retained from Argo CD pruning and Application deletion; operators must
deliberately recover or delete it when decommissioning the vault. The storage
ApplicationSet configures Longhorn's site-local default backup target, but
does not select a recurring backup job for this PVC, so the volume currently
has no chart-configured backup schedule.

Public sign-up, invitations, organization creation and the public Gateway API
route remain enabled. SMTP uses `smtp-out.mylogin.space:587` with STARTTLS and
`passwords@mail.mylogin.space` as its sender address. The SMTP username and
password still come from the existing `business-vaultwarden-mail-prod` Secret;
User connection credentials also come from existing Secrets. The chart
contains no credential defaults.

## Validation

Render with representative values from the owning ApplicationSet and declare
the installed Gateway API so BJW-S emits the deployed `v1` API:

```sh
helm dependency build Passwords/VaultWarden
helm lint Passwords/VaultWarden \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set vaultwarden.user.enabled=true \
  --set vaultwarden.psql.host=psql.core-dc1-talos-prod.dc1.yxl.mylogin.space
helm template core-dc1-talos-prod-business-passwords-vaultwarden \
  Passwords/VaultWarden \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set vaultwarden.user.enabled=true \
  --set vaultwarden.psql.host=psql.core-dc1-talos-prod.dc1.yxl.mylogin.space \
  >/tmp/core-business-vaultwarden.yaml
```

Confirm that only the hub render contains `kind: User`, every workload points
at its own `psql.<cluster>.<datacenter>.<region>.mylogin.space` PGPool endpoint,
the hub render contains one `PushSecret`, the spoke render contains one
`ExternalSecret`, all resources agree on the local and remote Secret names, and
no rendered Secret data is present. After Argo CD reconciliation, follow the
User claim, PostgreSQL Role, Database, Terraform Workspace, PushSecret and
ExternalSecret conditions before testing login, invitations, SMTP delivery and
vault read/write.

## Upstream projects

- [Vaultwarden website](https://www.vaultwarden.net/), [source and release
  notes](https://github.com/dani-garcia/vaultwarden), and [configuration
  template](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template)
- [BJW-S common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [External Secrets Operator](https://external-secrets.io/)
