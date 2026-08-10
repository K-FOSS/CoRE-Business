# CoRE Desktop

This chart deploys browser-accessible LinuxServer desktop workloads. Current
values define Dolphin and OrcaSlicer desktops, request the NVIDIA runtime and
select CUDA 12-capable nodes. Kasm-specific resources are disabled by default.

[The Desktops ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Desktops.yaml) selects the YVR bare-metal
infrastructure cluster, injects environment/site metadata through Lovely and
deploys the chart into `kube-system`. That destination makes namespace, RBAC
and naming changes especially sensitive.

Images currently use mutable `latest` tags. Pin reviewed versions/digests when
updating them. Confirm runtime classes, GPU node labels, storage size/mounts and
the external hostname before reconciliation.

```sh
helm dependency build Desktop
helm lint Desktop
helm template core-business-desktop Desktop --values Desktop/values.yaml >/tmp/core-business-desktop.yaml
```

After sync, verify GPU allocation, persistent desktop state, web access and
that workloads cannot gain unintended privileges from the target namespace.

## Upstream projects

- [LinuxServer.io website](https://www.linuxserver.io/) and [container documentation](https://docs.linuxserver.io/)
- [Dolphin container documentation](https://docs.linuxserver.io/images/docker-dolphin/)
- [OrcaSlicer website](https://www.orcaslicer.com/) and [source/documentation](https://github.com/SoftFever/OrcaSlicer)
- [NVIDIA Container Toolkit documentation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
