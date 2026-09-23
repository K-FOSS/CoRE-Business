# CoRE-Business Social/Matrix

This chart deploys the [Element Synapse homeserver](https://github.com/element-hq/synapse)
with the [BJW-S Common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It also deploys the [Element Web client](https://github.com/element-hq/element-web)
at `element.mylogin.space`, preconfigured for the local Synapse server at
`matrix.mylogin.space`.
It creates a `mylogin.space/v1alpha1` `User` service account and a retained
`synapse` database on the Backplane global PostgreSQL provider. The database
endpoint is intentionally `psql-int...`, never the site-local `psql-local...`
service; update the provider and host together through the owning ApplicationSet.

OIDC is provisioned through Authentik using the same Crossplane Terraform
`Workspace` pattern as the [Fediverse stack](https://github.com/K-FOSS/CoRE-Business/tree/main/Social/Fediverse).
The default login path is Authentik OIDC, which can in turn use CoRE LDAP.
Synapse's optional [LDAP password provider](https://github.com/matrix-org/matrix-synapse-ldap3)
is disabled by default and requires a separately managed bind-password Secret.

The future/live owner must be an explicit Backplane ApplicationSet using the
[global PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
and the [storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).
The `User` claim follows the current [mylogin.space User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).

Synapse signing keys and media are retained on Longhorn. Before activation,
add an owner under `Apps/Business/Social/` and inject `cluster.name`,
`datacenter`, `region`, the global PostgreSQL values, and the target Gateway.
Verify the User/XR conditions, PostgreSQL Role/Database, Authentik Workspace,
OIDC callback, federation port policy, and a real Element login after Argo CD
reconciliation. Synapse recommends PostgreSQL for production deployments and
documents federation and reverse-proxy requirements in its [installation guide](https://github.com/element-hq/synapse/blob/develop/docs/setup/installation.md).

The chart currently sets Synapse's `allow_unsafe_locale` because the existing
global PostgreSQL database was created with `en_US.UTF-8` collation. Synapse
documents this as a compatibility override; the safest permanent remediation
is to stop the service, dump the database, and recreate it with UTF-8,
`LC_COLLATE=C`, `LC_CTYPE=C`, and `template0`, then restore it. Do not drop the
database or change its locale in place without a tested backup.
