# CoRE Business agent guidance

This file applies to the entire repository. A more specific `AGENTS.md` may add
rules for its subtree but must not weaken these repository-wide requirements.

The shared workflow is adapted from [CoRE Backplane agent guidance](https://github.com/K-FOSS/CoRE-Backplane/blob/main/AGENTS.md)
and its [Git and Argo CD operating procedure](https://github.com/K-FOSS/CoRE-Backplane/blob/main/docs/OPERATIONS.md#agent-git-and-argo-cd-procedure).
The combined rules below retain CoRE Business's application-specific requirements.
Refresh the upstream guidance before changing this policy; the source reviewed
for this update was Backplane commit `f2772dabc194b1e5b5f99355aedb60ea4e462ee5`.

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

## Standing Git and reconciliation authorization

- This repository adopts the Backplane workflow authorized by the repository
  owner on 2026-09-26 after the Valkey operator deployment. For requested
  implementation work, agents may validate,
  create narrowly scoped commits, and push them to the repository's intended
  branch without asking again. For deployment requests, continue through
  scoped Argo CD reconciliation and downstream verification. Do not default
  to handing Git operations back to the user. A request to review only, leave
  changes uncommitted, use a PR, or defer deployment overrides this allowance.
- Apply this authorization only to the requested task. Preserve unrelated
  staged and unstaged edits, untracked files, and unpublished commits. Inspect
  the index and outgoing commit range before publishing; use an isolated
  worktree when needed to avoid including unrelated work. Never use blanket
  staging, force-push, or rewrite another author's history under this allowance.
- Confirm the intended remote and branch, fetch before publishing, review the
  exact outgoing diff, and use a normal fast-forward push. Respect branch
  protections and required checks; use the required PR workflow when applicable.
- Keep published history immutable. Before creating a commit, refresh the
  upstream and base new commits on its current tip. Never amend or rebase a
  commit once it may have reached the remote; make corrections as follow-up
  commits. Before pushing, confirm the upstream is an ancestor of `HEAD` and
  the outgoing range contains only this task's commits. If the branch is both
  ahead and behind, reconcile the local unpublished commits with the fetched
  upstream first; do not leave the user with a non-fast-forward push.
- Reconcile the reviewed, published commit through the owning Argo CD layers.
  Select only the necessary parent ApplicationSet resources and affected child
  applications. Inspect sync hooks and dependency ordering before choosing
  resource-selective sync; it skips hooks. Do not broadly resync the fleet or
  enable automated sync as an incidental change.
- Requesting an Argo CD refresh or sync through its CLI/API or an Application
  `operation` using kubectl is permitted normal reconciliation. It is distinct
  from directly applying or modifying the managed workloads. Read-only cluster
  checks and non-persistent server dry runs are also permitted without a new
  user confirmation; existing secret-handling rules still apply.
- Diagnose failed reconciliation before retrying. A scoped retry of the same
  reviewed commit is permitted when the cause is understood and replay is safe.
  This does not authorize unidentified provisioning retries, destructive data
  actions, force/replacement syncs, bypassing protections, or broader incident
  mutations. Obtain specific authorization for actions outside the requested
  scope after preparing the concrete change and explaining its effects.
- Report the published commit, affected targets, actual verification results,
  material limitations, and any remaining blockers. Documentation-only changes
  do not require a cluster sync. Follow the detailed
  [Git and Argo CD operating procedure](https://github.com/K-FOSS/CoRE-Backplane/blob/main/docs/OPERATIONS.md#agent-git-and-argo-cd-procedure).

## Commit message conventions

- Write new commit subjects in Conventional Commit form:
  `type(scope): Summary`. Standard types include `feat`, `chore`, `fix`,
  `docs` and `test`. Use a lowercase
  standard type that describes the change. Do not copy historical typos or
  nonstandard types such as `ffix`, `temp`, or `debug`.
- Apply casing by field: keep the type lowercase; preserve the established
  capitalization of scope components; write the summary in sentence case,
  starting with an uppercase word and preserving normal product names and
  acronyms. For example:
  `fix(AVoIP.Kamailio): Correct SIP routing`. Do not lowercase the scope or
  force the summary to start lowercase.
- Include a useful summary after the colon that says what changed. Keep it
  concise and specific; summaries may use the repository's natural sentence
  style, but avoid placeholders such as `Fix`, `Tidy up`, or `Work on things`
  without the thing or outcome being identified. A commit body is optional;
  the subject must still make sense on its own. Add a body when rationale,
  operational impact, or other context needs more room.
- Use a scope that identifies the primary CoRE Business component, preserving
  its path capitalization. Use `AVoIP.Kamailio` for changes under
  `AVoIP/templates/Kamailio/`, `Social.Matrix` for `Social/Matrix/`, and
  `Repository` for repository-wide guidance. Backplane ApplicationSet changes
  belong in that repository with its own deployment-layer scope.
- When one cohesive change intentionally spans components, list their scopes
  separated by commas, for example
  `feat(Mail, Office): Coordinate database connection settings`.
  Keep the scope list limited to
  components actually changed. A primary scope is sufficient for routine
  coordinated edits when it clearly identifies the change.
- Use one subject for one cohesive change. Do not leave the type or scope out,
  and avoid bare subjects such as `fix` or `test` even though they appear in
  older history.

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

## Shared application data services

- Treat the infrastructure PostgreSQL, MySQL, MongoDB, and site-local
  `dragonfly-core` deployments as shared platform services used by deployed
  applications, not as chart-private dependencies. Start changes at their
  fleet owners in [PostgreSQL](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml),
  [MySQL](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Database/MySQL.yaml),
  [MongoDB](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Database/MongoDB.yaml), and
  [Dragonfly](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml) ApplicationSets, then trace every application consumer.
- Every deployed application service identity must be declared with the
  namespaced `User.mylogin.space/v1alpha1` claim provided by the `sso-user`
  Composition in [Backplane’s SSO User implementation](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Operations/SSO/User); do not create an unrelated database
  password or parallel identity path in an application chart. Keep the claim
  beside the consuming application, use its stable connection Secret, and
  review identity, database grants, buckets, and secret publication as one
  lifecycle.
- Do not infer database provisioning from fields merely accepted by the
  `User` XRD. The current Composition implements Authentik identity plus
  optional PostgreSQL and S3 resources; `spec.mysql` and `spec.mongodb` are
  currently schema-only. Extend and validate the Composition before relying
  on it to provision MySQL or MongoDB resources, and document current behavior
  separately from the intended shared model.
- Treat the [Backplane Dragonfly allocation registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md) as the allocation registry for
  shared Dragonfly logical databases. Every application that uses
  `dragonfly-core` must declare an explicit, unused database number where the
  client supports one and add or update the registry in the same change.
  Database `0` is legacy shared space, not the default allocation for a new
  consumer. Use a separate Dragonfly instance when credentials, capacity,
  lifecycle, recovery, or failure isolation must be independent.
- For application onboarding, changes, and removal, verify the `User` claim
  and composite, downstream provider resources, stable connection Secret,
  effective database grants, and any Dragonfly allocation. Removing a claim
  is not proof that external roles, databases, grants, buckets, or persisted
  Dragonfly data were deleted; inspect orphan and deletion policies explicitly.
- In Helm-templated configuration files, indent control directives such as
  `if`, `else`, `with`, `range`, and their closing `end` at the same column as
  the YAML, XML, or configuration block they wrap. Keep the directive's
  surrounding whitespace aligned with that block's opening and closing lines;
  do not leave template directives flush-left when the wrapped block is
  indented.


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
- Follow the local style in existing files. For new or touched YAML, use
  single quotes for string scalars, including flow sequences and mappings.
  Use double quotes when escape processing is required or single quotes would
  be materially less clear. Leave Kubernetes `apiVersion` and `kind` unquoted.
  In `Chart.yaml`, also leave `apiVersion`, `type: application`, chart `version`
  and dependency `version` values unquoted. Quote numeric-looking identifiers
  so they remain strings across templates and generated JSON.
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
- Routes intended to receive public DNS records must include
  `wan-mode: 'public'`; site ExternalDNS selects records using that label.
  Keep it off private Authentik-only routes.
- Review ownership references, finalizers, deletion policies, Argo CD preserve
  behavior, sync waves and replacement semantics before resource renames or
  lifecycle changes. Preserve recovery access and dependency ordering across
  identity, secrets, storage and site failures.
- Validate every parser boundary touched by a change: Helm, Kustomize, YAML,
  embedded Terraform, shell/config fragments and Kubernetes custom resources.
- For CI or image-build workflows triggered by a push, locate the run for the
  pushed commit and confirm its commit SHA. Poll the run until it reaches a
  terminal state; a running job or a successful early step is not completion.
  On failure, inspect the failed step's log for that attempt, fix the diagnosed
  cause, and follow the new run through completion. Do not blindly rerun a
  failed build before understanding its cause; keep log excerpts focused and
  never disclose credentials that may appear in logs.
- For Helm/Lovely changes, resolve dependencies locally, run `helm lint`,
  render with representative defaults plus Backplane-injected values and
  inspect the complete output. A default-values render alone is not proof of a
  valid deployment.
- Validate API versions and CRDs against the operators installed by Backplane.
  In particular, this repository uses Gateway API, External Secrets and CoRE
  Crossplane APIs that are not provided by a stock Kubernetes cluster.
- Run `git diff --check` scoped to task files on the final change and
  review the diff/render for
  credentials, namespaces, selectors, public exposure, privileges, persistent
  data, deletion behavior and cross-site impact.
- After Argo CD reconciliation, follow downstream operator/Crossplane
  conditions and test the user-facing workflow. `Synced` or pod readiness alone
  does not prove the application is healthy.

## Dashboard exposure

- Forecastle is reserved for public services. Private-only services must not
  include `forecastle.stakater.com/*` annotations or be exposed in the
  Forecastle dashboard.
