# Repository and deployment guide

CoRE Business is organized by application domain. Most top-level deployment
directories are Helm charts, but some also include Kustomize input or raw
Kubernetes resources. The corresponding Argo CD ApplicationSets live in the
separate CoRE Backplane repository.

## Finding deployment ownership

For a path such as `Office`:

1. Search `CoRE-Backplane/Apps/Business/` for the CoRE Business repository URL
   or `path: Office`.
2. Read the ApplicationSet generators and cluster-label selectors.
3. Record `targetRevision`, destination namespace and whether Lovely is used.
4. Read all values and patches injected by the ApplicationSet.
5. Inspect the whole local path, including Helm, Kustomize, remote resources
   and raw YAML.

From a sibling checkout of CoRE Backplane, useful searches include:

```sh
rg -n 'K-FOSS/CoRE-Business|path: Office' Apps/Business
rg -n 'argocd-lovely-plugin|namespace:|targetRevision:' Apps/Business
```

A search result is only a possible owner. Confirm the entry is active and its
generator selects the intended registered cluster. References under
`Apps/Business/Legacy/` identify legacy deployment paths.

## Configuration layers

A deployed resource may be affected by:

1. This repository's `values.yaml` and templates.
2. A chart dependency and its defaults.
3. Values injected by the Backplane ApplicationSet.
4. Local or remote Kustomize resources and patches.
5. The Lovely renderer's composition order.
6. Admission webhooks and application-specific operators.
7. Crossplane resources that create identities, databases or secrets.

Inspect every applicable layer. A successful render with only local default
values does not show what Argo CD will deploy.

## Common integration patterns

### Secrets

The repository uses `ExternalSecret` to read from platform secret stores and
`PushSecret` or Crossplane connection secrets to publish generated material.
Store references are environment-specific. Do not replace them with literal
credentials for convenience, and do not expose rendered Secret data in logs or
reviews.

### Identity

Custom `mylogin.space/v1alpha1` `User` resources, Authentik Terraform
workspaces, LDAP configuration and OIDC settings participate in the same
identity flow. Review redirect URIs, group/entitlement bindings and service
accounts together.

The active [AI chart](../AI/README.md), owned by the
[AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml)
and
[AINode2 ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AINode2.yaml),
creates GPUStack's Authentik OIDC provider and application through a Crossplane
Terraform Workspace. Access is limited to the managed `GPUStack Users` group;
the generated client credentials are delivered to the GPUStack server through
a connection Secret rather than stored in Git. The chart can also reconcile
named GPUStack API keys from Kubernetes-generated Secrets. This workflow
requires a separately managed, management-scoped bootstrap API key and keeps
consumer token values out of Git and controller logs.

The active [Desktop chart](../Desktop/README.md), owned by the
[Desktops ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Desktops.yaml),
creates Authentik single-application proxy providers through a Crossplane
Terraform Workspace. Provider attachment is deliberately manual so an identity
operator can review the target outpost. Envoy Gateway SecurityPolicies use
fail-closed external-authorization checks against the configured outpost to
protect each desktop HTTPRoute; access is granted through the `Desktop Users`
Authentik group after attachment. The OrcaSlicer and Steam workloads fix the
Selkies stream target at 120 FPS; achieving a visible 120 Hz refresh also
depends on client display and browser support and sufficient network and GPU
capacity. The NVIDIA Steam instance uses a 250 GiB RWO game volume; the Intel
instance uses a dedicated 300 GiB `desktop-rwx` RWX volume. Both use a
container-scoped unconfined seccomp profile required by game sandboxing. The
NVIDIA instance's blanket toleration accepts all node taints, subject to its
AMD64, CUDA 13 and GPU scheduling constraints. It starts Steam in Big Picture
mode and locks the Selkies stream to the H.264 encoder and streaming mode.

### Networking

Newer paths generally expose HTTP services through Gateway API `HTTPRoute`
resources. Confirm the referenced gateway, namespace permissions, listener
section, hostname, TLS certificate and security policy. Older paths may still
contain Ingress, Istio `VirtualService`, LoadBalancer annotations or raw
service exposure.

### Data services

Applications commonly rely on shared PostgreSQL, Redis/Dragonfly and
S3-compatible object storage. Review database ownership, credentials, bucket
policy, persistence, backup coverage and deletion semantics before changing a
connection or resource identity.

The active, multi-site [Mail chart](../Mail/README.md), owned by the
[Mail ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Mail.yaml),
uses the current
[`mylogin.space` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
to provision Maddy's PostgreSQL database and S3 service account. Its merge
generator targets the approved `dc1-k3s-node1`, `core-dc1-talos-prod` and
`core-home1-talos-prod` clusters. Lovely injects each cluster's DNS domain,
LDAP endpoint, site-local PostgreSQL and Dragonfly endpoints, and PostgreSQL/S3
provider names into Maddy, Postfix, Dovecot and Rspamd. Those dependencies are
defined by the
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml),
[storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml),
and
[Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml).
Dragonfly credentials remain platform-managed and are rendered into Rspamd's
configuration by External Secrets rather than committed to this repository.
The checked-in values remain DC1 K3s defaults; validate a render with every
target's injected values before changing this production stack.
The selected Mail credential hub exclusively owns the generated Postfix,
Maddy and optional SimpleLogin identities and publishes their connection
fields below its cluster path in the shared Vault store. Other Mail targets
pull from that selected hub path into workload-local Secrets. Chart deletion
retains both the remote records and the last spoke copies, so credential
decommissioning and rotation remain explicit operator actions.
The hub also owns Mail's `DKIMKey` and publishes its generated private key
below the selected cluster path; spokes recreate the expected local DKIM Secret
through External Secrets and do not generate independent signing identities.
The Mail chart selects `dc1-k3s-node1` as that credential hub and uses the
[BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
to generate its standard workloads, Services, persistence and optional route;
operator-specific custom resources remain explicit Helm templates.

The active [Office chart](../Office/README.md), owned by the
[NextCloud ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml),
uses the CoRE `User` resource's temporary S3 access key, secret key and session
token to authenticate a Crossplane Terraform Workspace. The Workspace creates
a durable MinIO service account and publishes its generated key pair to the
Secret consumed by Nextcloud. The Workspace uses an `Orphan` deletion policy,
so permanent removal requires explicit service-account revocation.

The active [Vaultwarden chart](../Passwords/VaultWarden/README.md), owned by the
[VaultWarden ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/VaultWarden.yaml),
runs the upstream Vaultwarden image through the BJW-S common library chart. A
hub-only [`mylogin.space` User
claim](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
provisions its stable PostgreSQL role and `bitwarden` database with the site's
providers, while the workload connects through the target's site-local PGPool
endpoint defined by the [PostgreSQL
ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
The owning ApplicationSet must inject cluster/site identity, the PGPool host
and the hub-only User enablement; the chart verifies that the enabled claim is
rendering on the configured hub cluster. A hub-only External Secrets
`PushSecret` publishes the generated connection fields to the shared Vault
store, and spoke-only `ExternalSecret` resources recreate the workload Secret
without duplicating the User claim or database role.

The active AI chart provisions OpenWebUI's database identity on the site-local
`psql-<datacenter>-<region>` providers and connects it to the corresponding
`psql-local.<cluster>.<datacenter>.<region>.mylogin.space` endpoint. OpenWebUI
uses the same site's TLS-enabled Dragonfly service for its cache and websocket
manager, with namespace-local credentials synchronized through External
Secrets and explicit logical database allocations `150` and `151`.

The AI chart's separate CPU and NVIDIA CUDA Speaches backends share their
downloaded model cache using a chart-managed Longhorn ReadWriteMany
StorageClass. The StorageClass disables Longhorn volume migration and retains
the underlying PV after claim deletion; operators must deliberately recover or
delete that retained data when removing the backends. The `core-speaches-cpu` and
`core-speaches-cuda` Services are exported as Cilium ClusterMesh global
services from each target cluster and prefer healthy local backends, falling
back to shared remote backends only when local endpoints are unavailable.
The Gateway distributes traffic evenly between CPU and CUDA by default.
Kubernetes `ClientIP` affinity pins direct clients, while the Gateway policy
uses a generated secure cookie for per-session consistent hashing and disables
HTTP stream timeouts. The CUDA backend has a blanket `operator: Exists`
toleration and can therefore tolerate every node taint when its shared-GPU
resource and remaining scheduling constraints match.

## Active SnapOtter conversions

[SnapOtter conversions](../Tools/Conversions/README.md) uses BJW-S Common 5.0.1
for a non-root workload, Service, retained Longhorn PVC and private
Authentik-secured Gateway API route at `conotter.mylogin.space`. It is owned by
the [Conversions ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Conversions.yaml),
which selects `core-home1-talos-prod`, deploys to `core-prod` and renders with
Lovely. The ApplicationSet injects `cluster.name`, `datacenter` and `region`,
and preserves resources on deletion.

Following GPUStack in the [AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml),
the chart automates an Authentik OAuth2 provider/application, `SnapOtter Users`
group and entitlement bindings through a Crossplane Terraform Workspace.
Generated OIDC credentials go directly to a connection Secret. SSO creates
ordinary users with email auto-linking disabled; local login remains
available for recovery. A CoRE User claim provisions the PostgreSQL role and
owned database using the selected site's `psql-<datacenter>-<region>`
providers. The app uses the matching `psql-local` endpoint from the
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
Missing site identity fails rendering. An ExternalSecret reads the selected
site's Dragonfly password from `corevault-rootsecrets` at
`Storage/DragonFly/CoRE/<region>/<datacenter>/<cluster.name>/Creds`, as published
by the [Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml).
It builds a TLS URL on logical database 152 and Reloader restarts the workload
on Secret changes. All BullMQ pools use the `{snapotter}` hashtag for the
shared server's existing hashtag locking. The separate `snapotter-runtime`
Secret now only supplies bootstrap-password and cookie-secret fields by
default. Logical database selection does not isolate shared credentials;
queue compatibility and recovery must be verified after reconciliation.

See the component README for provisioning, allowed/denied SSO verification,
operator conditions and recovery. Argo removal retains the data PVC and User
claim; the User composition also orphans SQL roles/databases. OIDC Workspace
removal deletes its managed Authentik resources. Removing group membership
does not revoke existing SnapOtter sessions or local accounts.

## Active OpenProject

[OpenProject](../Projects/README.md) is owned by the
[Projects ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Projects.yaml),
which selects `core-home1-talos-prod`, deploys to `core-prod`, and renders the
chart through Lovely. The chart uses BJW-S Common rather than the previous
third-party OpenProject chart. It consumes the current
[`mylogin.space` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
for the existing PostgreSQL database and S3 bucket. Temporary S3 credentials
are written to an explicit namespace-local Secret and loaded by the workload;
the old Vault-backed OpenProject S3 Secret is no longer rendered.

The User Composition refreshes temporary S3 credentials, and the workload has
Reloader annotations for both the User connection Secret and S3 credential
Secret. Removing the chart does not delete the orphaned PostgreSQL or S3 data;
verify downstream User, provider, Secret and storage conditions before testing
the public route.

## Active Landing

[CoRE Landing](../Landing/README.md) publishes Forecastle as the application
launchpad at `mylogin.space`. It is owned by the [Landing ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Landing.yaml),
which selects the `core.mylogin.space` tenant's bare-metal infrastructure
cluster in `yvr` and deploys to `core-prod` with direct Helm rendering at
`targetRevision: HEAD`. The ApplicationSet enables namespace creation and
server-side apply and preserves resources when the generated Argo CD
Application is deleted.

The chart uses its local `prod` values for the `core-prod` namespace, `main-gw`
Gateway and `https-myloginspace` listener. Forecastle reads annotated Ingress,
HTTPRoute and `ForecastleApp` resources cluster-wide through the upstream chart's
RBAC, but displays only the configured `core-prod` namespace. Authentication is
not provisioned by this chart; review any gateway policy before exposing the
launchpad. Verify the route, `/healthz`, namespace-scoped discovery and CRD
discovery after reconciliation.

## Active Fediverse social stack

[Fediverse social](../Social/Fediverse/README.md) is the repository's federated-
social stack. Its current production component runs the official Mastodon image
with BJW-S Common 5.0.1, separate web, streaming and Sidekiq Deployments, a
migration hook, and a public Gateway API HTTPRoute. It is live
at `mastodon.mylogin.space` and owned
by the [Fediverse ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Social/Fediverse.yaml),
whose merge generator selects `core-home1-talos-prod` for the `yvr` bare-metal
site and deploys to `core-prod` with Lovely at `targetRevision: HEAD`.

The chart also contains optional Bluesky PDS support under the `bluesky` values
tree. PeerTube, Lemmy and similar federated services are planned additions to
this stack; they are not represented as active workloads until their own value
layers and deployment resources are added.

The current ApplicationSet injects `env`, `datacenter`, `region`, cluster
identity, the `mastodon.mylogin.space` hostname, the `main-gw` /
`https-myloginspace` Gateway attachment, and the PostgreSQL/S3 provider names.

The chart follows the current
[`mylogin.space` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
to provision PostgreSQL and an S3 bucket/service account, using the selected
site's [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
and [storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).
Crossplane Terraform creates the Authentik OIDC provider, application, access
group and entitlement bindings. The chart intentionally has no application PVC:
PostgreSQL and S3 are durable stores, while Mastodon signing/session keys are
generated once, pushed to Vault and restored through External Secrets.
`OMNIAUTH_ONLY` defaults to true, so group
membership and email-verification policy must be reviewed before exposing the
public route.

## Repository status

The live [openGym chart](../Personal/Fitness/README.md) is owned by the
[Fitness ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Personal/Fitness.yaml).
It deploys through Lovely to `core-fitness-prod` on
`core-home1-talos-prod`, with a Gateway API route at `gym.mylogin.space`,
retained Longhorn data and exercise-media claims, and Authentik forward-auth.
The ApplicationSet preserves resources on deletion; back up both claims before
maintenance, migration or removal. Verify `/api/health`, profile creation,
passkey sign-in from a second device and exercise-media loading after
reconciliation.

The prepared [LinkStack chart](../Social/Links/README.md) has no active
Backplane owner. It follows the current single-replica, retained-Longhorn and
Gateway API pattern, but must not be treated as deployed until a non-legacy
ApplicationSet references `Social/Links` and supplies its site values.

Use these as working heuristics, not a formal lifecycle contract:

- An active Backplane `Apps/Business/` reference is the strongest indicator of
  an actively deployed path.
- A reference under `Apps/Business/Legacy/` is transitional or legacy.
- `TMP/` and `Testing/` are experimental and must not be assumed safe for
  production.
- `Apps/`, `Avatars/`, `HPSchool/` and `LocalAI/` contain standalone or earlier
  layouts that may not follow current chart conventions.
- A chart without a Backplane reference may be inactive, manual, a dependency,
  or planned work.

## Validation baseline

For a conventional Helm-only chart:

```sh
chart='AI'
helm dependency build "$chart"
helm lint "$chart"
helm template core-business "$chart" --values "$chart/values.yaml" >/tmp/core-business-rendered.yaml
git diff --check
```

Add representative ApplicationSet-injected values. Validate Kustomize/Lovely
output where used, and validate embedded configuration with its own parser.
Dependency builds may create ignored `charts/` directories and `Chart.lock`
files; do not force-add them.

Before completion, review both source and rendered output for:

- Secret values and unsafe defaults.
- Target namespaces, clusters and selectors.
- Public hostnames, gateway listeners and authentication policies.
- RBAC or identity entitlement expansion.
- Persistent-volume, database and object-storage changes.
- Ownership, finalizers, deletion policies and resource renames.
- Compatibility with installed CRDs and controller versions.

After reconciliation, check Argo CD and every downstream controller, then test
the actual user workflow. `Synced`, accepted YAML and ready pods are supporting
signals rather than the complete health model.
