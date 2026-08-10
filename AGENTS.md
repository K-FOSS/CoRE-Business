# CoRE Business agent guidance

This file applies to the entire repository. A more specific `AGENTS.md` may add
rules for its subtree but must not weaken these repository-wide requirements.

## Repository and deployment model

- Treat this repository as live, site-specific desired state for CoRE business
  applications, not as a collection of generic Helm examples.
- Deployment ownership lives in `K-FOSS/CoRE-Backplane`. Before changing a
  chart, find the owning ApplicationSet under `Apps/Business/`, then inspect its
  path, cluster selector, destination namespace, injected values and renderer.
- An implementation directory may combine Helm, Kustomize, raw YAML, remote
  resources and ApplicationSet-injected values. Inspect the complete rendering
  unit; do not infer deployed resources from `templates/` alone.
- A directory in this repository is not necessarily deployed. Confirm an
  active Backplane reference; paths under `Apps/Business/Legacy/`, `TMP/`, or
  without an ApplicationSet owner require extra scrutiny.
- Normal changes flow through Git and Argo CD. Direct cluster mutations are
  incident actions and must be represented in Git or deliberately removed
  after recovery.

## Documentation

- Keep `README.md`, `docs/REPOSITORY.md`, and the nearest component README in
  sync when a change alters deployment, prerequisites, access, recovery,
  storage, public endpoints, secrets, or operator workflow.
- Link external charts, images, controllers, APIs and remote manifests to their
  authoritative upstream documentation. Put links beside the behavior they
  explain and prefer component-specific documentation.
- Separate current behavior from intended behavior. Manifests, the owning
  Backplane ApplicationSet and observed controller state are authoritative.
- Document required value layers, generated resources, target namespaces,
  verification, rollback/deletion effects and non-obvious security impact.

## Secrets and identity

- Never add, decode, print, log, document or commit production credentials,
  tokens, private keys, Secret values or private provider configuration.
- Prefer External Secrets, PushSecret and Crossplane connection secrets. A
  secret-store reference may be committed, but inspect rendered output for
  literal or generated credential disclosure.
- Do not add deployable placeholder/default passwords. Required secret
  references should fail validation when absent.
- Review Authentik applications/groups, `mylogin.space/v1alpha1` users,
  Gateway API routes/policies, OIDC redirects and entitlements as one access
  path. Coordinated changes can cause privilege expansion or lockout.

## Dependencies and generated files

- Pin Helm dependencies, images and remote resources to immutable versions or
  digests where supported. Avoid version ranges, moving branches and `latest`
  tags unless their mutability is intentional and documented.
- Verify dependency versions and values against authoritative release notes,
  chart indexes and documentation before updating them.
- `Chart.lock` and `charts/` are ignored globally, although older tracked
  artifacts exist in some charts. Do not force-add newly generated dependency
  artifacts or modify existing tracked archives unless the task requires it.
- Treat remote Kustomize resources and the Lovely renderer as supply-chain
  inputs. Review their source, mutability and rendering order.

## Implementation and validation

- Preserve unrelated worktree changes. Do not reformat, revert, stage or
  include another author's edits.
- Follow the local style in existing files. For new or touched YAML, prefer
  single quotes for string scalars; leave Kubernetes `apiVersion` and `kind`
  unquoted. Quote numeric-looking identifiers so they remain strings.
- Prefer values-driven templates for cluster, environment, hostname, gateway,
  namespace and secret-store differences.
- Validate every parser boundary touched by a change: Helm, Kustomize, YAML,
  embedded Terraform, shell/config fragments and Kubernetes custom resources.
- For Helm/Lovely changes, resolve dependencies locally, run `helm lint`,
  render with representative defaults plus Backplane-injected values and
  inspect the complete output. A default-values render alone is not proof of a
  valid deployment.
- Validate API versions and CRDs against the operators installed by Backplane.
  In particular, this repository uses Gateway API, External Secrets and CoRE
  Crossplane APIs that are not provided by a stock Kubernetes cluster.
- Run `git diff --check` on the final change and review the diff/render for
  credentials, namespaces, selectors, public exposure, privileges, persistent
  data, deletion behavior and cross-site impact.
- After Argo CD reconciliation, follow downstream operator/Crossplane
  conditions and test the user-facing workflow. `Synced` or pod readiness alone
  does not prove the application is healthy.
