# CoRE Desktop

This chart deploys browser-accessible Linux GUI applications using
[LinuxServer.io Selkies containers](https://github.com/linuxserver/docker-baseimage-selkies).
The active defaults run Dolphin, allocate Intel i915 device-plugin GPUs to
OrcaSlicer and an Intel Steam instance, and place a second Steam instance on
NVIDIA CUDA 13 nodes. OrcaSlicer's and both Steam streams are locked to 120 FPS
with `SELKIES_FRAMERATE`; the browser and display must also support a 120 Hz
refresh rate to present every streamed frame.
Each desktop has its own controller, ClusterIP Service, persistent `/config`
volume, memory-backed `/dev/shm`, Gateway API HTTPRoute and Authentik proxy
authorization policy.

[The Desktops ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Desktops.yaml)
selects the YVR bare-metal infrastructure cluster, injects environment/site
metadata through Lovely and deploys the chart into `kube-system`. That
destination makes namespace, RBAC, identity and naming changes especially
sensitive.

## Access and identity

The shared `main-gw` Gateway terminates HTTPS and forwards each hostname to
the matching HTTP service on Selkies port `3000`. An Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
calls the Authentik embedded outpost for every protected request. A Crossplane
Terraform Workspace creates one single-application forward-auth proxy provider
per desktop and binds the applications to the `Desktop Users` group. It
deliberately does not attach providers to an outpost. An Authentik operator must
review and attach each provider to the intended outpost before the route can
authenticate. Authentik owns login and session cookies; no default or literal
password is deployed.

The desktop routes remain protected and external authorization is explicitly
fail-closed. The configured outpost Service is
`ak-outpost-authentik-embedded-outpost.authentik:9000`; change `auth.outpost`
if the deployed Authentik release uses another name or namespace.

Only members of `Desktop Users` are entitled to the Authentik application.
Public hostnames are configured per desktop in `values.yaml` and are not
reproduced here.

| Desktop | Persistent path |
| --- | --- |
| [Dolphin](https://docs.linuxserver.io/images/docker-dolphin/) | `/config` |
| [OrcaSlicer](https://docs.linuxserver.io/images/docker-orcaslicer/) | `/config` |
| [Steam (NVIDIA)](https://docs.linuxserver.io/images/docker-steam/) | `/config` on a 250 GiB RWO volume |
| [Steam (Intel)](https://docs.linuxserver.io/images/docker-steam/) | `/config` on a 300 GiB `desktop-rwx` RWX volume |

Proxy authentication is fail-closed: newly created routes return an
authorization failure until all generated providers are manually attached to
the configured outpost. Do not consider a route available until the Terraform
Workspace is ready, the outpost has loaded all providers, and each
SecurityPolicy reports `Accepted`. Removing the Workspace
removes the managed Authentik objects and invalidates subsequent login;
removing a PVC deletes
that desktop's settings and files according to storage-class reclaim policy.

## Configuration and rendering

Each `desktops` entry controls the image, internal port, hostname, environment,
GPU placement, persistence and shared memory. `resourceName` provides a short
Kubernetes identifier when the ApplicationSet release name would otherwise
exceed the 63-character DNS-label limit; the OrcaSlicer entry uses `orca`.
The Dolphin and OrcaSlicer entries currently carry mutable `latest` tags;
Steam is pinned to the reviewed `8beba5cd-ls35` image release. Pin reviewed
versions or digests when updating them.
See [the desktop application catalog](docs/DESKTOP-APPS.md) before adding a
workload.

The NVIDIA Steam instance requests one `nvidia.com/gpu`, uses the `nvidia`
RuntimeClass and selects CUDA 13-capable nodes. Its blanket `operator: Exists`
toleration permits it to schedule across every node taint when the other
scheduling constraints match; review new cluster taints with this exception in
mind. It mounts a chart-managed Labwc autostart file that launches Steam with
`-bigpicture`, restricts the Selkies encoder to `x264enc`, and locks H.264
streaming mode on with `SELKIES_H264_STREAMING_MODE=true|locked`. The Intel
Steam instance requests one `gpu.intel.com/i915` and stores its
configuration and games on a 300 GiB ReadWriteMany PVC provisioned by
`desktop-rwx`. Longhorn serves this generic RWX filesystem through a share
manager; see its [RWX volume documentation](https://longhorn.io/docs/1.12.0/nodes-and-volumes/volumes/rwx-volumes/).

```sh
helm dependency build .
helm lint .
helm template core-business-desktop . --values values.yaml >/tmp/core-business-desktop.yaml
```

Render with the values injected by the owning ApplicationSet as well as the
defaults. Inspect the complete output for secrets, hostnames, route targets,
namespaces and GPU selectors. After Argo CD reconciliation, verify:

1. The Terraform Workspace is ready and all proxy providers were reviewed and
   manually attached to the intended Authentik outpost.
2. The HTTPRoutes and SecurityPolicies are accepted by their controllers.
3. An unauthenticated request redirects to Authentik.
4. A non-member is denied and a `Desktop Users` member can connect.
5. WebSocket/video, clipboard and file transfer work through the gateway.
6. OrcaSlicer and both Steam instances report a 120 FPS stream in Selkies statistics on a
   120 Hz client.
7. Steam and the launched game have their display refresh rate, VSync and any
   frame limiter set for 120 Hz/FPS; these application settings persist in
   `/config` and are not controlled by Selkies.
8. Steam audio and browser gamepad input work in a launched game.
9. GPU allocation and `/config` persistence survive a pod restart.

Rollback through Git and Argo CD. A rollback that restores the old port
`8080` or `/root` mount is incompatible with current Selkies images and can
make the service unavailable or hide persisted state.

## Upstream projects

- [LinuxServer.io](https://www.linuxserver.io/) and its [container documentation](https://docs.linuxserver.io/)
- [Selkies](https://github.com/selkies-project/selkies) and the [LinuxServer Selkies base image](https://github.com/linuxserver/docker-baseimage-selkies)
- [Dolphin](https://apps.kde.org/dolphin/) and its [LinuxServer container](https://docs.linuxserver.io/images/docker-dolphin/)
- [OrcaSlicer](https://www.orcaslicer.com/) and its [source](https://github.com/SoftFever/OrcaSlicer)
- [Steam](https://store.steampowered.com/) and its [LinuxServer container documentation](https://docs.linuxserver.io/images/docker-steam/)
- [Envoy Gateway](https://gateway.envoyproxy.io/) and [external-authorization SecurityPolicy documentation](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
- [Authentik](https://goauthentik.io/) and its [proxy-provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/proxy/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [Intel device plugins for Kubernetes](https://intel.github.io/intel-device-plugins-for-kubernetes/)
- [Longhorn](https://longhorn.io/) and its [RWX volume documentation](https://longhorn.io/docs/1.12.0/nodes-and-volumes/volumes/rwx-volumes/)
- [bjw-s common chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
