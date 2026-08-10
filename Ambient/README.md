# CoRE Ambient

This chart deploys the Moodist ambient-sound web application using the bjw-s
common library.

[The Ambient ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/Ambient.yaml) selects explicitly listed
bare-metal infrastructure clusters, injects environment and site metadata
through Lovely, and deploys into `core-prod`. The chart exposes
`sounds.mylogin.space` with an HTTPRoute attached to the shared gateway.

The default image tag is mutable (`latest`). Review and pin an immutable image
version or digest when changing it. Confirm the gateway parent reference,
listener, hostname and public/private policy labels in the rendered output.

```sh
helm dependency build Ambient
helm lint Ambient
helm template core-business-ambient Ambient --values Ambient/values.yaml >/tmp/core-business-ambient.yaml
```

After reconciliation, verify the route from the intended network contexts and
confirm audio assets load successfully.

## Upstream projects

- [Moodist website](https://moodist.mvze.net/) and [source documentation](https://github.com/remvze/moodist)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)
