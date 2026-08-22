# CoRE AI

This chart deploys CoRE's AI service layer: OpenWebUI-facing resources, speech
backends, MCP integrations, optional LocalAI/llama workloads, gateway routes,
identity resources and external-secret integration.

## Active deployment

Two non-legacy Backplane ApplicationSets render this same chart into
`core-ai-prod`:

- [AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml) selects YVR bare-metal infrastructure clusters,
  enables MCP, creates the AI namespace and supplies gateway tenant metadata.
- [AINode2 ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AINode2.yaml) selects bare-metal infrastructure clusters
  across sites and enables `localai` plus its llama workload.

Both inject `env`, cluster name/domain, datacentre and region through Lovely.
Do not assume the local defaults represent either deployment role.

## Integrations and generated resources

- The [bjw-s common library](https://bjw-s-labs.github.io/helm-charts/docs/) v5
  renders most workloads from `templates/common.yaml`. It requires Kubernetes
  1.31 or newer and Helm 3.18 or newer; v5 creates a dedicated unprivileged
  ServiceAccount by default and does not mount its token unless explicitly
  enabled.
- Gateway API resources expose AI, speech-to-text and text-to-speech endpoints.
- OpenWebUI identity automation creates a CoRE `User` and an Authentik
  Terraform `Workspace`.
- GPUStack v2 uses its unified, version-pinned image for the server and workers.
  A CoRE `User` provisions its PostgreSQL role and database on the site-local
  `psql-<datacenter>-<region>` cluster, writing credentials to
  `<release>-gpustack-user`. The server connects to
  `psql.<cluster>.<datacenter>.<region>.mylogin.space:5432`; both the providers
  and hostname can be overridden under `gpustack.psql`.
- MCP search credentials are read through External Secrets.
- Backend and BackendTrafficPolicy resources configure external/upstream speech
  services.
- GPU scheduling, runtime classes and node selectors are controlled by values;
  verify them against the selected cluster before enabling a backend.

## Validation and operations

```sh
helm lint AI
helm template core-business-ai AI --values AI/values.yaml >/tmp/core-business-ai.yaml
```

For a representative render, merge the values from the specific owning
ApplicationSet. Validate Gateway API, Envoy Gateway extension APIs, External
Secrets, Crossplane/Terraform provider configuration and GPU runtime support.
After sync, test the web UI, OIDC login, model/backend discovery, MCP calls and
speech endpoints rather than relying only on pod readiness. For GPUStack,
follow the `User` and PostgreSQL Crossplane conditions, verify the generated
connection Secret exists, and confirm the server completes its v2 database
migrations before testing worker registration. Roll back the image and
manifests together; deleting the `User` can delete the provisioned database
according to the platform resource's deletion policy.

## Upstream projects

- [Open WebUI website](https://openwebui.com/) and [documentation](https://docs.openwebui.com/)
- [LocalAI website](https://localai.io/) and [documentation](https://localai.io/docs/)
- [GPUStack website](https://gpustack.ai/) and [documentation](https://docs.gpustack.ai/)
- [Speaches source and documentation](https://github.com/speaches-ai/speaches)
- [Model Context Protocol website](https://modelcontextprotocol.io/) and [specification](https://modelcontextprotocol.io/specification/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
