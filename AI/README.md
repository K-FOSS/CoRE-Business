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
  Terraform `Workspace`. Its `User` provisions the PostgreSQL role and database
  on the site-local `psql-<datacenter>-<region>` cluster and writes the
  connection Secret to `<release>-openwebui-user`. OpenWebUI connects to
  `psql-local.<cluster>.<datacenter>.<region>.mylogin.space:5432`; the provider
  names and hostname can be overridden under `owui.psql`.
  OpenWebUI also uses the site-local, TLS-enabled
  [Dragonfly](https://www.dragonflydb.io/docs/category/managing-dragonfly)
  endpoint for its cache and websocket manager. An `ExternalSecret` copies the
  generated platform password from `Storage/DragonFly/CoRE/Creds` into
  `openwebui-dragonfly`; logical databases `150` and `151` are configured under
  `owui.redis`, along with the endpoint and secret references.
- GPUStack v2 uses its unified, version-pinned image for the server and workers.
  Its Authentik Terraform `Workspace` creates a confidential OIDC provider,
  application, `GPUStack Users` access group and entitlement. The generated
  client credentials are written to `<release>-gpustack-oidc`; the server uses
  them with the exact `<external-url>/auth/oidc/callback` redirect URI required
  by [GPUStack SSO](https://docs.gpustack.ai/2.0/user-guide/sso/). OIDC settings,
  including the Authentik provider reference and issuer URL, are configured
  under `gpustack.oidc`; the public URL is `gpustack.server.externalUrl`. The
  inline module pins the
  [Authentik Terraform provider](https://registry.terraform.io/providers/goauthentik/authentik/2026.5.1)
  and [random provider](https://registry.terraform.io/providers/hashicorp/random/3.9.0).
  The same HTTPS `externalUrl` is passed as GPUStack's
  [`server-external-url`](https://docs.gpustack.ai/2.0/cli-reference/start/), so
  generated worker-registration and other advertised URLs do not inherit the
  chart's internal HTTP transport.
  A CoRE `User` provisions its PostgreSQL role and database on the site-local
  `psql-<datacenter>-<region>` cluster, writing credentials to
  `<release>-gpustack-user`. The server connects to
  `psql-local.<cluster>.<datacenter>.<region>.mylogin.space:5432`; both the
  providers and hostname can be overridden under `gpustack.psql`.
  Optional declarative API-key provisioning under `gpustack.tokens` uses
  [GPUStack's API-key API](https://docs.gpustack.ai/2.0/user-guide/api-key-management/).
  External Secrets generates each custom token once and retains it in the
  configured Kubernetes Secret. A CronJob reconciles named keys and their
  `management`/`inference` scopes and model allowlists through `/v2/api-keys`.
  The reconciler requires a pre-existing management-scoped GPUStack API key in
  `gpustack.tokens.auth.existingSecret`; deliver this bootstrap credential
  through the platform secret workflow before enabling provisioning. Token
  values are mounted from Secrets and never included in rendered manifests or
  reconciliation logs.
- MCP search credentials are read through External Secrets.
- Backend and BackendTrafficPolicy resources configure external/upstream speech
  services.
- Speaches runs separate CPU and NVIDIA CUDA backends. The CPU backend uses the
  pinned `0.8.3-cpu` image and runs as a two-replica StatefulSet with one pod on
  each of `srv2` and `srv3`; each replica receives four CPU cores and uses
  `int8` inference. The CUDA backend uses the pinned
  `0.8.3-cuda-12.6.3` image, requests one `nvidia.com/gpu.shared`, uses the
  `nvidia` RuntimeClass and performs `float16` inference. Its blanket
  `operator: Exists` toleration permits scheduling across every node taint
  when the shared-GPU resource and other scheduling constraints match, so new
  cluster taints must be reviewed with this exception in mind. All replicas
  preload `Systran/faster-whisper-small` and share a
  10 GiB ReadWriteMany Hugging Face cache through the chart-managed
  `speaches-longhorn-rwx` [Longhorn](https://longhorn.io/docs/) StorageClass.
  The class uses two Longhorn replicas, sets `migratable` to `false`, and uses
  a `Retain` reclaim policy so deleting the workload claim does not
  automatically delete the model-cache volume. The `core-speaches-cpu` and
  `core-speaches-cuda` Services are shared
  [Cilium ClusterMesh global services](https://docs.cilium.io/en/stable/network/clustermesh/services/)
  with [local service affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/):
  healthy local endpoints are preferred and remote-cluster endpoints provide
  failover. Every participating cluster must deploy the Services with these
  exact names in `core-ai-prod` and have a working ClusterMesh connection.
  Direct Service clients use Kubernetes `ClientIP` session affinity for three
  hours. Gateway clients receive a secure `core-speaches-session` cookie used
  by Envoy's consistent-hash load balancer, keeping subsequent requests on the
  same healthy backend. The Gateway route gives the CPU and CUDA Services equal
  weight; adjust each backend's `service.weight` when a different traffic split
  is required. The Speaches BackendTrafficPolicy disables request,
  maximum-stream and stream-idle timeouts so long-running transcription streams
  are not terminated by Envoy Gateway.
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
follow both Terraform `Workspace` and `User` conditions, verify the generated
OIDC and PostgreSQL connection Secrets exist, confirm a member of `GPUStack
Users` can complete login, and confirm the server completes its v2 database
migrations before testing worker registration. When token provisioning is
enabled, confirm the Password generator and `ExternalSecret` are Ready, the
provisioner CronJob completes, and the generated key can access only its
configured scopes and model allowlist. The reconciler creates missing keys and
updates metadata and permissions, but intentionally does not replace the value
of an existing named key. Rotate a token by deleting the GPUStack key and its
generated Kubernetes Secret, then allow External Secrets and the CronJob to
recreate them; coordinate consumers to avoid an outage. Removing the OIDC
Workspace deletes its Authentik application, provider and access bindings. Roll back the
image and manifests together; deleting the `User` can delete the provisioned
database according to the platform resource's deletion policy.
For OpenWebUI, follow its `User` and `ExternalSecret` conditions, confirm the
database host resolves to the selected site's local PostgreSQL service, and
test both normal cache operations and websocket updates over TLS. Removing the
chart removes the namespace-local connection Secrets and `User` claim but does
not prove that its external PostgreSQL database or Dragonfly keys were deleted;
verify the platform deletion policies and clear logical databases `150` and
`151` deliberately when decommissioning the service.
For Speaches, verify that its PVC is `Bound` as ReadWriteMany, the CPU
StatefulSet places exactly one pod on each requested host, and the CUDA pod is
scheduled on a matching NVIDIA node with one GPU allocated. Confirm every pod
completes model preload, CUDA logs report GPU inference, and
`/v1/audio/transcriptions` accepts `Systran/faster-whisper-small`. Verify
`core-speaches-cpu` and `core-speaches-cuda` appear as global, shared Cilium
services and that local backends are preferred before testing remote failover.
Confirm the Gateway response sets
`core-speaches-session`, repeat requests reach the same pod, and a streaming
transcription remains connected for longer than the former five-minute idle
window. Removing the chart removes its local ClusterMesh backends but leaves
the Longhorn PV for manual recovery or deletion because its reclaim policy is
`Retain`.

## Upstream projects

- [Open WebUI website](https://openwebui.com/) and [documentation](https://docs.openwebui.com/)
- [LocalAI website](https://localai.io/) and [documentation](https://localai.io/docs/)
- [GPUStack website](https://gpustack.ai/) and [documentation](https://docs.gpustack.ai/)
- [Speaches website and documentation](https://speaches.ai/) and
  [source repository](https://github.com/speaches-ai/speaches)
- [Model Context Protocol website](https://modelcontextprotocol.io/) and [specification](https://modelcontextprotocol.io/specification/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
