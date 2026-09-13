# LinkStack

This chart deploys the official [LinkStack](https://linkstack.org/) link-sharing
application with the [BJW-S Common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
The container is the official [LinkStack Docker image](https://github.com/LinkStackOrg/linkstack-docker),
pinned to the 4.8.6 release's immutable multi-architecture image digest. Apache
serves HTTP inside the cluster; TLS is terminated by the site's Gateway API
listener.

## Ownership and activation

`Social/Links` is prepared but has no active CoRE Backplane ApplicationSet owner
yet. Before activation, add an owner under
[CoRE-Backplane Apps/Business](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Apps/Business)
and inject `cluster.name`, `datacenter`, `region`, `linkstack.hostname`,
`linkstack.serverAdmin` and `gateway.sectionName`. The owner must target
`core-prod`, select a single cluster, and render the complete Helm chart through
the repository's normal Argo CD path.

The [current storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
was reviewed as the source of the `longhorn` prerequisite. LinkStack uses its
bundled SQLite database and therefore does not use the site's
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
or the CoRE User XRD. The application creates its first administrator through
LinkStack's `/login` setup flow; no Authentik application or SSO claim is
created by this chart.

## Storage, access and lifecycle

One Recreate Deployment mounts a retained 10 GiB ReadWriteOnce Longhorn PVC at
`/htdocs`, which contains LinkStack's SQLite database, uploaded avatars, themes,
blocks and application files. Do not scale this workload beyond one replica:
independent SQLite writers would corrupt or diverge the instance. The PVC has
Helm keep and Argo `Prune=false,Delete=false` annotations; removing the future
ApplicationSet should remove compute and routing while preserving application
data. Retention is not backup: stop writes and take a consistent volume backup
before upgrades or decommissioning, and test restoration separately.

The route is public because profile pages and the application login are served
by LinkStack itself. The Gateway listener must cover the configured hostname and
admit the target namespace. `serverAdmin` is a notification address, not a
credential. Registration and administrator settings remain application policy;
review them after the initial setup.

## Validation

From this directory:

```sh
helm dependency build .
helm lint . -f examples/site.yaml
helm template linkstack . --namespace core-prod -f examples/site.yaml \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute >/tmp/linkstack-rendered.yaml
git diff --check
```

Inspect the full render for the namespace, gateway listener, public hostname,
single replica, retained PVC, image digest and absence of literal credentials.
After an owner is added and Argo reconciles, verify the PVC, probes and
HTTPRoute `Accepted`/`ResolvedRefs`, then complete the LinkStack setup at
`/login`, create an administrator, publish a test profile and verify avatar,
theme and link persistence across a pod restart.

## Upstream projects

- [LinkStack website and self-hosting](https://linkstack.org/)
- [LinkStack source and releases](https://github.com/LinkStackOrg/LinkStack)
- [Official Docker image](https://github.com/LinkStackOrg/linkstack-docker)
- [BJW-S Common documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [Longhorn documentation](https://longhorn.io/docs/)
