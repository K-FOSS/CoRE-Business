# CoRE Business agent guidance

This file applies to the entire repository. A more specific `AGENTS.md` may add
rules for its subtree but must not weaken these repository-wide requirements.

## Repository and deployment model

- Treat this repository as live, site-specific desired state for CoRE business
  applications, not as a collection of generic Helm examples.
- Deployment ownership lives in `K-FOSS/CoRE-Backplane`. Before changing a
  chart, find the owning ApplicationSet under `Apps/Business/`, then inspect its
  path, cluster selector, destination namespace, injected values and renderer.
- Fetch the current site-local configuration from the CoRE-Backplane
  [storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
  and [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
  before changing persistence or database behavior; do not infer site
  configuration from this repository's defaults.
- Fetch the current SSO `User` resource definition from the CoRE-Backplane
  [`mylogin.space` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
  before changing identity, access or entitlement behavior, and review it
  together with the application configuration.
- An implementation directory may combine Helm, Kustomize, raw YAML, remote
  resources and ApplicationSet-injected values. Inspect the complete rendering
  unit; do not infer deployed resources from `templates/` alone.
- A directory in this repository is not necessarily deployed. Confirm an
  active Backplane reference; paths under `Apps/Business/Legacy/`, `TMP/`, or
  without an ApplicationSet owner require extra scrutiny.
- Normal changes flow through Git and Argo CD. Direct cluster mutations are
  incident actions and must be represented in Git or deliberately removed
  after recovery.

### Lovely rendering capabilities

- The [Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin)
  is a config-management pipeline, not a Helm-only renderer. A Lovely-owned
  directory may combine a Helm chart, local or remote Kustomize resources,
  Kustomize patches, raw manifests and additional pipeline steps in one Argo
  CD Application.
- The deployed `lovely-vault-plugin` image includes Helm, Kustomize, Helmfile,
  Bash, Git and `yq`; it also resolves Vault-backed placeholders. Treat those
  tools and the plugin image as deployment inputs: inspect the owning
  ApplicationSet and the installed plugin configuration before relying on a
  feature, and do not execute arbitrary scripts or fetch mutable remote input.
- ApplicationSets can pass environment-specific Helm values and Kustomize
  overlays through `LOVELY_HELM_MERGE` and `LOVELY_KUSTOMIZE_MERGE`. These
  layers may change names, namespaces, labels, patches, enabled components and
  generated resources, so inspect them alongside the local chart and preserve
  the configured composition order.
- Lovely does not discover applications automatically. The owning Application
  must explicitly select the configured Lovely plugin, and a path with a
  `kustomization.yaml` must be rendered through Lovely to reproduce Argo CD's
  result; standalone `helm template` or `kustomize build` output is only a
  partial check.

## Documentation

- Keep `README.md`, `docs/REPOSITORY.md`, and the nearest component README in
  sync when a change alters deployment, prerequisites, access, recovery,
  storage, public endpoints, secrets, or operator workflow.
- Every reference to a specific Backplane ApplicationSet must be a Markdown
  link to that exact file in `K-FOSS/CoRE-Backplane` (normally its `blob/main`
  GitHub URL). Do not leave ApplicationSet paths as unlinked code text, even in
  tables or lists. If two ApplicationSets own one chart, link both files.
- Link external charts, images, controllers, APIs and remote manifests to their
  authoritative upstream documentation. Put links beside the behavior they
  explain and prefer component-specific documentation.
- Every documented stack must link to each principal upstream project's main
  website and authoritative documentation or source repository. Use direct
  component/chart documentation where available; a registry page alone is not
  sufficient.
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
- Prefer the [BJW-S common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
  for supported Kubernetes workloads and supporting resources, including
  controllers, Services, routes, persistence, ConfigMaps and Secrets. Before
  writing a Kubernetes resource template directly, verify whether the pinned
  BJW-S version can express it. Keep direct templates or `rawResources` for
  unsupported APIs or behavior, and document why the exception is necessary.
- Follow the local style in existing files. For new or touched YAML, prefer
  single quotes for string scalars; leave Kubernetes `apiVersion` and `kind`
  unquoted. Quote numeric-looking identifiers so they remain strings.
- Prefer values-driven templates for cluster, environment, hostname, gateway,
  namespace and secret-store differences.
- For every `Landing`/Forecastle-exposed service, add a
  `forecastle.stakater.com/appName` annotation with a friendly display name;
  do not rely on the generated resource name in the dashboard.
- Forecastle’s deployed instance name is `core`. To expose a service through
  Forecastle, add these annotations to the exposed `HTTPRoute` (or `Ingress`):
  `forecastle.stakater.com/expose: 'true'`,
  `forecastle.stakater.com/instance: 'core'`, and a friendly
  `forecastle.stakater.com/appName`. Add
  `forecastle.stakater.com/group` when the service belongs in a dashboard
  group such as `Tools` or `Security`; keep the route hostname and Gateway
  attachment valid as well.
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

## Dashboard exposure

- Forecastle is reserved for public services. Private-only services must not
  include `forecastle.stakater.com/*` annotations or be exposed in the
  Forecastle dashboard.
