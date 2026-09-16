# K-FOSS/CoRE-Business Tools/Sharing Stack

This chart is a generic home for public sharing applications. Kutt is the
first enabled workload: a self-hosted URL shortener using the official
[Kutt image](https://hub.docker.com/r/kutt/kutt), backed by PostgreSQL and the
site-local [Dragonfly](https://www.dragonflydb.io/) service. It is exposed at
`snd.fyi` and has Authentik OIDC configured for the `Sharing Users` group.

The chart is intended to be owned by a Backplane ApplicationSet. Its injected
cluster, datacenter, region, gateway and PostgreSQL provider values are part of
the deployment contract; this directory has no active owner in the current
checkout, so it is not independently deployable yet.

The `mylogin.space/v1alpha1` [User resource](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
creates Kutt's PostgreSQL role/database and writes its connection Secret.
PostgreSQL is reached through the site-local endpoint from the [PostgreSQL
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
Dragonfly credentials are read from the platform Vault path used by the
[Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml).

`sharing.kutt.jwtSecret.name` must reference an externally managed Secret. No
passwords or JWT material belong in values. The Authentik Workspace generates
OIDC client credentials into a connection Secret consumed by Kutt. Kutt
documents Redis configuration but does not document a Redis TLS environment
variable; verify the deployed Dragonfly listener/client compatibility before
enabling this in production.

Kutt is exposed through a Gateway API HTTPRoute and the public Forecastle
dashboard. Before deployment, add an active Backplane owner, inject site-local
values, resolve the common-library dependency, run `helm lint`, and render the
Lovely composition with those injected values. After reconciliation, check the
User, ExternalSecret, database and Dragonfly conditions, then test login and
link creation.

Upstream references: [Kutt documentation](https://docs.kutt.to/), [Kutt
source](https://github.com/thedevs-network/kutt), [BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/),
[Gateway API](https://gateway-api.sigs.k8s.io/), and [External Secrets](https://external-secrets.io/).
