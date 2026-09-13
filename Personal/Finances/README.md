# Firefly III

This prepared chart deploys [Firefly III](https://www.firefly-iii.org/), a
self-hosted personal finance manager, with the
[BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It serves `firefly.mylogin.space` through a Gateway API HTTPRoute and uses the
upstream Firefly III container image at version `6.6.6`. Access is protected by
Authentik forward authentication.

## Access and identity

The route is protected fail-closed by an Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
that forwards requests to the site Authentik outpost Service
`aaa-myloginspace-proxy` in `core-prod`. A Crossplane Terraform `Workspace`
creates the Authentik forward-single proxy provider and application through the
`authentik` ProviderConfig. Authentik owns login and session cookies; the route
is intentionally not exposed through Forecastle because Forecastle is reserved
for public services.

The pattern follows the existing
[Office ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml)
and [Fitness Authentik configuration](https://github.com/K-FOSS/CoRE-Business/blob/main/Personal/Fitness/templates/Authentik.yaml).

Firefly III creates its PostgreSQL role and database through the current
[Backplane `mylogin.space` User resource definition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml),
using the generated connection Secret for `DB_DATABASE`, `DB_USERNAME` and
`DB_PASSWORD`; Backplane
auto-generates the username and matching database name. The future owner must
provide an externally managed Secret containing Firefly's `APP_KEY`; no
credentials are stored in this repository. The 10Gi Longhorn upload PVC is
retained across chart removal and must be backed up alongside the PostgreSQL
database.

There is currently no active Firefly owner in the
[CoRE-Backplane Apps/Business tree](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Apps/Business),
so this is prepared desired state and will not deploy until an ApplicationSet
explicitly references `Personal/Finances`. Its future owner must inject
`cluster.name`, `datacenter`, `region`, `firefly.appKeySecret`, and both Firefly
PostgreSQL provider references, select
the target namespace and renderer, and confirm the `main-gw` /
`https-myloginspace` listener. The generated database role and name are
retained by the Backplane database resources.

The chart includes a per-minute Firefly scheduler CronJob. Review its inherited
Gateway access policy before activation; the route is labeled public/private.

```sh
helm dependency build Personal/Finances
helm lint Personal/Finances \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set firefly.appKeySecret=firefly-app-key \
  --set firefly.database.crossplane.crossplaneProvider=psql-home1-yvr \
  --set firefly.database.crossplane.terraformProvider=psql-home1-yvr
helm template core-business-firefly Personal/Finances --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set firefly.appKeySecret=firefly-app-key \
  --set firefly.database.crossplane.crossplaneProvider=psql-home1-yvr \
  --set firefly.database.crossplane.terraformProvider=psql-home1-yvr \
  >/tmp/core-business-firefly.yaml
```

Review the upstream [Firefly III source repository](https://github.com/firefly-iii/firefly-iii),
[installation documentation](https://docs.firefly-iii.org/references/faq/install/),
[Kubernetes support repository](https://github.com/firefly-iii/kubernetes),
[Authentik proxy-provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/proxy/),
[Envoy Gateway external-authorization documentation](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/),
[Crossplane Terraform provider documentation](https://marketplace.upbound.io/providers/upbound/provider-terraform),
[BJW-S Common](https://bjw-s-labs.github.io/helm-charts/tree/main/charts/library/common),
and [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) documentation.
After activation, verify PostgreSQL connectivity, the `/health` endpoint, login
and transaction creation, scheduler completion, route policy behavior, and
restore of both the database and upload PVC.
