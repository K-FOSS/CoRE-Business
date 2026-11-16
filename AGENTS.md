# CoRE Business agent guidance

This file applies to the entire repository. A more specific `AGENTS.md` may add
rules for its subtree but must not weaken these repository-wide requirements.

The shared workflow is adapted from [CoRE Backplane agent guidance](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/AGENTS.md)
and its [Git and Argo CD operating procedure](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/docs/OPERATIONS.md#agent-git-and-argo-cd-procedure).
The combined rules below retain CoRE Business's application-specific requirements.
Refresh the upstream guidance before changing this policy; the source reviewed
for this update was Backplane commit `1f6fbe47178090d7d83da59cc9c2531db35c644a`.

## Repository and deployment model

- Treat this repository as live, site-specific desired state for CoRE business
  applications, not as a collection of generic Helm examples.
- Deployment ownership lives in `K-FOSS/CoRE-Backplane`. Before changing a
  chart, find the owning ApplicationSet under `Apps/Business/`, then inspect its
  path, cluster selector, destination namespace, injected values and renderer.
- Fetch the current site-local configuration from the CoRE-Backplane
  [storage ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Base.yaml)
  and [PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
  before changing persistence or database behavior; do not infer site
  configuration from this repository's defaults.
- Fetch the current SSO `User` resource definition from the CoRE-Backplane
  [`mylogin.space` User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
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

- For requested implementation work, agents may inspect, edit, and validate the
  requested files, but must leave review and Git publication to the user by
  default. Do not stage, commit, push, or create a PR unless the user explicitly
  requests that Git operation in the current task. If the user explicitly
  requests deployment, continue through scoped Argo CD reconciliation and
  downstream verification; otherwise stop after validation with the changes
  available for review.
- Apply this authorization only to the requested task. Preserve unrelated
  staged and unstaged edits, untracked files, and unpublished commits. Inspect
  the index and outgoing commit range before publishing; use an isolated
  worktree when needed to avoid including unrelated work. Never use blanket
  staging, force-push, or rewrite another author's history under this allowance.
- Confirm the intended remote and branch, fetch before publishing, review the
  exact outgoing diff, and use a normal fast-forward push. Respect branch
  protections and required checks; use the required PR workflow when applicable.
- Keep published history immutable. Never amend or rebase a commit that may
  have reached a remote; publish corrections as follow-up commits. After
  fetching, confirm the intended upstream tip is an ancestor of `HEAD` and
  review the complete outgoing range to ensure it contains only this task's
  commits. If the upstream is not an ancestor of `HEAD`, follow the canonical
  checkout procedure in Backplane's `docs/OPERATIONS.md`; do not force-push or
  rewrite published history.
- Use the canonical workspace's configured Git authentication and askpass
  flow. Never print, read, copy, or replace stored credentials, disable
  askpass, or switch credential helpers to work around a missing prompt. If
  the configured askpass integration cannot communicate, stop retrying,
  preserve outgoing commits, and report that the workspace authentication
  prompt must be restored.
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
  [Git and Argo CD operating procedure](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/docs/OPERATIONS.md#agent-git-and-argo-cd-procedure).

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
- Stack READMEs should start with a concise purpose statement and link to their
  owner and parent overview. Organize task-focused sections around ownership,
  targets and rendering; architecture and data flow; operations and
  verification; and security and recovery where relevant. Use specific
  headings, relative links for repository files and direct upstream links for
  dependencies. Describe observed current behavior before separate desired
  behavior or TODOs.
- For internal CoRE repositories, link to `slop.writemy.codes` rather than the
  GitHub mirror. Use Forgejo file links in the form
  `https://slop.writemy.codes/<owner>/<repo>/src/branch/<branch>/<path>`;
  use a commit-specific route when the reference must stay pinned to a revision.
- Every reference to a specific Backplane ApplicationSet must be a Markdown
  link to that exact file in `K-FOSS/CoRE-Backplane` using the Forgejo URL on
  `slop.writemy.codes`. Do not leave ApplicationSet paths as unlinked code
  text, even in tables or lists. If two ApplicationSets own one chart, link
  both files.
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
- Prefer Vault/CoreVault references, External Secrets, PushSecret and
  Crossplane connection secrets. A secret-store reference may be committed,
  but inspect rendered output for literal or generated credential disclosure.
- Preserve emergency access paths that do not depend on Authentik, Eclipse
  Che, public ingress/DNS, Vault application credentials, a single cluster or
  a single site.
- Do not add deployable placeholder/default passwords. Required secret
  references should fail validation when absent.
- Review Authentik applications/groups, `mylogin.space/v1alpha1` users,
  Gateway API routes/policies, OIDC redirects and entitlements as one access
  path. Coordinated changes can cause privilege expansion or lockout.

## Shared application data services

- Treat the infrastructure PostgreSQL, MySQL, MongoDB, and site-local
  `dragonfly-core` deployments as shared platform services used by deployed
  applications, not as chart-private dependencies. Start changes at their
  fleet owners in [PostgreSQL](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml),
  [MySQL](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Database/MySQL.yaml),
  [MongoDB](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Database/MongoDB.yaml), and
  [Dragonfly](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Dragonfly/CoRE.yaml) ApplicationSets, then trace every application consumer.
- Every deployed application service identity must be declared with the
  namespaced `User.mylogin.space/v1alpha1` claim provided by the `sso-user`
  Composition in [Backplane’s SSO User implementation](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User); do not create an unrelated database
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
- Treat the [Backplane Dragonfly allocation registry](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Storage/Dragonfly/CoRE/README.md) as the allocation registry for
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

- Pin Helm dependencies, images, operators, downloaded tools and remote
  resources to immutable versions or digests where supported. Avoid version
  ranges, moving branches and `latest` tags unless their mutability is
  intentional and documented.
- Verify versions, values and migration behavior against authoritative chart
  indexes, releases, source and documentation before updating them.
- `Chart.lock` and `charts/` are ignored globally, although older tracked
  artifacts exist in some charts. Do not force-add newly generated dependency
  artifacts or modify existing tracked archives unless the task requires it.
- Treat remote Kustomize resources and the Lovely renderer as supply-chain
  inputs. Review their source, mutability and rendering order.

## Implementation and validation

- Preserve unrelated worktree changes. Do not reformat, revert, stage or
  include another author's edits.
- Keep the repository's local phone-number Git hooks enabled for this checkout
  when committing; see [the phone-number commit guard](docs/PHONE-NUMBER-GUARD.md).
- Prefer the [BJW-S common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
  for supported Kubernetes workloads and supporting resources, including
  controllers, Services, routes, persistence, ConfigMaps and Secrets. Before
  writing a Kubernetes resource template directly, verify whether the pinned
  BJW-S version can express it. Keep direct templates or `rawResources` for
  unsupported APIs or behavior, and document why the exception is necessary.
- Before adding a custom Helm template or helper for behavior that BJW-S Common Chart may
  support, check its chart values, including file-backed resources and built-in
  rollout/checksum behavior. Keep direct manifests for unsupported APIs or
  when BJW-S cannot preserve required identity, lifecycle, ordering or security
  semantics, and document the reason.
- Follow the local style in existing files. For new or touched YAML, use
  single quotes for string scalars, including flow sequences and mappings.
  Use double quotes when escape processing is required or single quotes would
  be materially less clear. Leave Kubernetes `apiVersion` and `kind` unquoted.
  In `Chart.yaml`, also leave `apiVersion`, `type: application`, chart `version`
  and dependency `version` values unquoted. Quote numeric-looking identifiers
  so they remain strings across templates and generated JSON.
- Prefer values-driven templates for cluster, environment, hostname, gateway,
  namespace and secret-store differences.
- Grafana dashboard ConfigMaps consumed by the dashboard syncer must include
  the `grafana_dashboard` label. Repository-managed dashboards should use
  `grafana_dashboard: 'true'`; the syncer currently watches `core-prod`,
  `kube-system` and `longhorn-system` through namespace-scoped Roles and
  RoleBindings. Use its existing folder annotation for non-root dashboards.
  Prefer, in order, a supported upstream chart integration, an immutable
  upstream Kustomize resource, then a repository ConfigMap from an upstream or
  trusted community dashboard. Preserve provenance, normalize datasource IDs
  and scope, and document local overlays.
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
- If an ApplicationSet supplies `LOVELY_KUSTOMIZE_MERGE`, ensure its source
  directory contains a `kustomization.yaml` or `Kustomization` marker so Lovely
  executes that stage; preserve the marker when adding injected patches.
- Validate every parser boundary touched by a change: Helm, Kustomize, YAML,
  embedded Terraform, shell/config fragments and Kubernetes custom resources.
- For CI or image-build workflows triggered by a push, locate the run for the
  pushed commit and confirm its commit SHA. Poll the run until it reaches a
  terminal state; a running job or a successful early step is not completion.
  On failure, inspect the failed step's log for that attempt, fix the diagnosed
  cause, and follow the new run through completion. Do not blindly rerun a
  failed build before understanding its cause; keep log excerpts focused and
  never disclose credentials that may appear in logs.
- To inspect a Forgejo Actions run, start from its UI URL, for example
  `https://forge.example/OWNER/REPO/actions/runs/RUN_ID/jobs/JOB_ID/attempt/ATTEMPT`.
  The run page is `/OWNER/REPO/actions/runs/RUN_ID`; its job page adds
  `/jobs/JOB_ID/attempt/ATTEMPT`, and the job log view adds `/logs`. Preserve
  the attempt number when opening logs so a rerun is not confused with an older
  attempt. Derive owner, repository, run ID, job ID and attempt from the URL and
  page links/data; do not guess numeric IDs. Check the run's displayed commit
  SHA before treating it as the build for the current change.
- For programmatic inspection, the Forgejo API base is the instance origin plus
  `/api/v1` (Forgejo exposes this as `FORGEJO_API_URL` in workflow jobs). Check
  that instance's API/OpenAPI documentation for the installed version and
  available Actions endpoints before constructing a request; API support can
  differ by version. Use an authorized token via a protected environment
  variable or credential helper, never put it in a URL, command history,
  committed script or printed output. If the API does not expose the required
  run/job/log data, use the UI routes above and inspect the page's links or
  network requests to determine the instance-specific path.
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

## Live application investigations

- For live Kubernetes inspection, the configured `kubectl` context `logged-user`
  targets the YVR/Home1 cluster. Use it for YVR application checks; do not
  substitute the DC1 context when investigating a YVR incident.

- When a live reproduction is useful and authorized log access is available,
  inspect and monitor the relevant service logs directly; do not ask the user
  to run console commands or collect and paste log output.
- If a test call or other user action is needed, ask the user to perform that
  action and provide a time window or correlation identifier. Monitor the
  relevant logs around that window and correlate events across services
  yourself.
- If direct log access is unavailable, state that limitation plainly. Do not
  imply that logs are being monitored or shift log collection to the user;
  request only the user action needed for a reproduction when it can still
  provide useful evidence.
- Keep live observations read-only unless the user has authorized a specific
  operational change. Redact secrets and avoid requesting credentials or
  sensitive call content.

## Dashboard exposure

- Forecastle is reserved for public services. Private-only services must not
  include `forecastle.stakater.com/*` annotations or be exposed in the
  Forecastle dashboard.
