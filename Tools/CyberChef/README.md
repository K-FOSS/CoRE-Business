# CoRE CyberChef

This chart deploys CyberChef through the bjw-s common library. It runs two
replicas behind a ClusterIP Service and exposes `cyberchef.mylogin.space` with
a Gateway API HTTPRoute carrying public and private network-policy labels.

[The Cyberchef ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Cyberchef.yaml) selects YVR bare-metal
infrastructure clusters and deploys to `core-prod` without Lovely-injected
values. Site-specific gateway, domain, replica, image and resource settings are
kept in `values.yaml`; the rendered workload configuration lives in
`templates/common.yaml`. The image uses a digest-qualified `latest` reference;
preserve digest pinning when updating it. The chart creates a dedicated
ServiceAccount but does not mount its token. The pod and container use a
non-root, RuntimeDefault seccomp profile with privilege escalation and Linux
capabilities disabled. HTTP startup, readiness and liveness probes check the
web server directly on port 8000. Resource requests and limits protect node
capacity, and rolling updates retain both available replicas while a new pod
starts. A soft hostname topology-spread constraint prefers separate nodes
without preventing scheduling on a single-node site. Because the container is
a static web server and requires no runtime network access, an egress
NetworkPolicy denies all outbound connections from its pods.

The pinned bjw-s common chart 5.0.1 requires Kubernetes 1.31 or newer and Helm
3.18 or newer in the deployment renderer; see the upstream
[v4-to-v5 upgrade guide](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/4-to-5/).

```sh
helm dependency build Tools/CyberChef
helm lint Tools/CyberChef
helm template core-business-cyberchef Tools/CyberChef --namespace core-prod --values Tools/CyberChef/values.yaml >/tmp/core-business-cyberchef.yaml
```

Review the upstream [CyberChef project](https://github.com/gchq/CyberChef) and
[bjw-s common chart](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common).
Validate the gateway parent/listener, service target port, probes, replica
distribution and disruption behavior after deployment. Test browser loading,
web workers, uploads, downloads and representative recipes while the egress
policy is enforced.

## Upstream projects

- [CyberChef website](https://gchq.github.io/CyberChef/) and [source/documentation](https://github.com/gchq/CyberChef)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
