# CoRE CyberChef

This chart deploys CyberChef through the bjw-s common library. It runs two
replicas behind a ClusterIP Service and exposes `cyberchef.mylogin.space` with
a Gateway API HTTPRoute carrying public and private network-policy labels.

[The Cyberchef ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Cyberchef.yaml) selects YVR bare-metal
infrastructure clusters and deploys to `core-prod` without Lovely-injected
values. Site-specific gateway, domain, replica, image and resource settings are
kept in `values.yaml`; the rendered workload configuration lives in
`templates/common.yaml`. The image uses a digest-qualified `latest` reference;
preserve digest pinning when updating it. The chart does not create a dedicated
ServiceAccount and does not mount the namespace default ServiceAccount token.
The pod and container use a non-root, RuntimeDefault seccomp profile with
privilege escalation and Linux capabilities disabled. Probes are currently
disabled.

The pinned bjw-s common chart 5.0.1 requires Kubernetes 1.31 or newer and Helm
3.18 or newer in the deployment renderer; see the upstream
[v4-to-v5 upgrade guide](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/4-to-5/).

```sh
helm dependency build Tools/CyberChef
helm lint Tools/CyberChef
helm template core-business-cyberchef Tools/CyberChef --values Tools/CyberChef/values.yaml >/tmp/core-business-cyberchef.yaml
```

Review the upstream [CyberChef project](https://github.com/gchq/CyberChef) and
[bjw-s common chart](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common).
Validate the gateway parent/listener, service target port, replica disruption
behavior and browser functionality after deployment.

## Upstream projects

- [CyberChef website](https://gchq.github.io/CyberChef/) and [source/documentation](https://github.com/gchq/CyberChef)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
