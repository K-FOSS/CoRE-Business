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

The active [Office chart](../Office/README.md), owned by the
[NextCloud ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml),
uses the CoRE `User` resource's temporary S3 access key, secret key and session
token to authenticate a Crossplane Terraform Workspace. The Workspace creates
a durable MinIO service account and publishes its generated key pair to the
Secret consumed by Nextcloud. The Workspace uses an `Orphan` deletion policy,
so permanent removal requires explicit service-account revocation.

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

## Repository status

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
