# CoRE Business

CoRE Business contains the application charts and manifests for the business
and personal-service layer of the CoRE platform. It includes AI services,
automation, communications, office and collaboration tools, mail, ERP,
identity-integrated utilities and several legacy or experimental workloads.

This is live, environment-specific infrastructure. Manifests contain CoRE
domains, cluster assumptions, secret-store references and custom resource
types. They should not be applied to another Kubernetes environment without a
complete review.

## Deployment model

This repository supplies application implementations; fleet deployment is
owned by [CoRE Backplane](https://github.com/K-FOSS/CoRE-Backplane). Argo CD
ApplicationSets under Backplane's `Apps/Business/` select clusters, choose a
path in this repository and inject environment-specific values. Many use the
`argocd-lovely-plugin` to combine Helm and Kustomize inputs.

```text
CoRE-Backplane Apps/Business ApplicationSet
  -> cluster-label selection
  -> path in CoRE-Business
  -> Lovely / Helm / Kustomize rendering
  -> target namespace
  -> Kubernetes resources and operators
  -> user-facing service
```

The presence of a chart here does not prove it is deployed. Start in the
Backplane repository and find the active ApplicationSet that references the
path. Some workloads are explicitly under `Apps/Business/Legacy/`; other
directories may be inactive, transitional or manually deployed.

## Repository areas

| Area | Paths | Examples |
| --- | --- | --- |
| AI and automation | `AI/`, `Automation/`, `BusinessProcesses/` | OpenWebUI, speech services, MCP integrations, n8n and workflow tooling. |
| Collaboration and productivity | `Office/`, `Communication/`, `Projects/`, `Tasks/` | Nextcloud, Collabora, Mattermost, Matrix, OpenProject and task services. |
| Identity-facing utilities | `Passwords/`, `Desktop/`, `Terminal/`, `Tools/` | Vaultwarden, Kasm, browser terminals, CyberChef and Draw.io. |
| Business systems | `ERP/`, `Finances/`, `Analytics/`, `Medical/`, `Education/` | ERPNext, finance, analytics, health and learning workloads. |
| Communications | `Mail/`, `AVoIP/`, `Voice/` | Mail, SIP, Asterisk, FreeSWITCH and conferencing. |
| Other application domains | `Family/`, `Feeds/`, `Knowledge/`, `Sharing/`, `Ambient/`, `Browsers/` | Knowledge, feeds, file sharing, ambient audio and browser automation. |
| Standalone/older manifests | `Apps/`, `Avatars/`, `HPSchool/`, `LocalAI/` | Raw manifests and earlier deployment layouts. |
| Experimental material | `Testing/`, `TMP/` | Validation workloads and temporary/legacy content. |

See the [repository guide](docs/REPOSITORY.md) for ownership discovery,
configuration layers and change validation.

## Platform integrations

Charts assume infrastructure supplied by CoRE Backplane, including:

- Argo CD and the Lovely rendering plugin.
- Gateway API and CoRE gateway/listener conventions.
- External Secrets secret stores such as `mainvault-core`,
  `corevault-rootsecrets` and older `vault-backend` references.
- CoRE Crossplane APIs such as `User` and `Database` resources.
- Authentik/OIDC, LDAP and platform-specific identity automation.
- Shared PostgreSQL, Redis/Dragonfly, S3-compatible storage, DNS, TLS,
  observability and persistent-storage services.

Secret references in Git are not secret values. Still review templates and
rendered manifests for literal passwords, tokens or deployable defaults.

## Working with a chart

Before editing a path:

1. Find its owning ApplicationSet in CoRE Backplane's `Apps/Business/` tree.
2. Record the selected clusters, destination namespace, renderer and injected
   values or patches.
3. Inspect `Chart.yaml`, `values.yaml`, `templates/`, `kustomization.yaml`, raw
   resources and any embedded configuration together.
4. Confirm the required CRDs, operators, secret stores, gateways, databases
   and storage classes exist on the target cluster.
5. Render representative output, then review secrets, routes, selectors,
   namespaces, persistent data and deletion behavior.
6. Reconcile through Argo CD and observe downstream controllers plus the
   user-facing service.

For a conventional Helm-only chart, the local baseline is:

```sh
chart='AI'
helm dependency build "$chart"
helm lint "$chart"
helm template core-business "$chart" --values "$chart/values.yaml" >/tmp/core-business-rendered.yaml
git diff --check
```

Add the value layers injected by the owning ApplicationSet before treating the
render as representative. If the path also has a `kustomization.yaml`, remote
resources or Lovely patches, reproduce that composition order and inspect the
complete result. Do not apply the temporary render directly to a cluster.

## Current limitations

- There is no repository-wide automated chart-render or schema-validation
  workflow.
- Several dependencies refer to archived chart repositories, old versions or
  version ranges and require migration before a routine upgrade.
- Active, legacy and experimental directories are not labeled consistently in
  this repository; Backplane ownership is the best deployment indicator.
- Some large values/templates contain application configuration and embedded
  languages that need validation beyond YAML parsing.
- Site-specific hostnames and platform API dependencies limit portability.

## Documentation

- [Repository and deployment guide](docs/REPOSITORY.md)
- [AI stack](AI/README.md)
- [CoRE Backplane architecture](https://github.com/K-FOSS/CoRE-Backplane/blob/main/docs/ARCHITECTURE.md)
- [CoRE Backplane operations](https://github.com/K-FOSS/CoRE-Backplane/blob/main/docs/OPERATIONS.md)

Where documentation and manifests differ, the manifests, owning Backplane
ApplicationSet and observed controller state are authoritative.
