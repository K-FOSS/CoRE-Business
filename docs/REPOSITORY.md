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
