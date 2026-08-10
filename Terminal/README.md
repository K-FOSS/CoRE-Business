# CoRE Terminal

This chart deploys the browser-accessible terminal workload. Its local
`values.yaml` is intentionally empty and the implementation is currently held
in `templates/common.yaml`, so review that template directly before changes.

[The Terminal ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Terminal.yaml) selects the YVR bare-metal
infrastructure cluster and deploys to `core-prod`. Unlike most active business
charts, this ApplicationSet does not currently inject Lovely values or name a
renderer plugin.

```sh
helm lint Terminal
helm template core-business-terminal Terminal >/tmp/core-business-terminal.yaml
```

Pay particular attention to the terminal image, command, security context,
service account, mounted credentials and HTTPRoute. A web terminal is a remote
execution boundary: verify authentication policy and network exposure from an
unauthorized client as well as successful authorized access.

## Upstream projects

- [Termix website](https://termix.site/), [documentation](https://docs.termix.site/) and [source](https://github.com/LukeGus/Termix)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
