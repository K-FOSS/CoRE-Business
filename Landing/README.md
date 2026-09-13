# CoRE Landing

CoRE Landing publishes [Forecastle](https://github.com/stakater/Forecastle), a
Kubernetes application launchpad, at `mylogin.space`. Forecastle discovers
applications from annotated `Ingress` and `HTTPRoute` resources and from the
optional `ForecastleApp` custom resource.

## Deployment ownership

The [Landing ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Landing.yaml)
selects the `core.mylogin.space` tenant's bare-metal infrastructure cluster in
the `yvr` region and deploys to `core-prod`. It renders this chart directly
with Helm at `targetRevision: HEAD`, creates the namespace with server-side
apply, and preserves chart resources when the Argo CD Application is deleted.
The ApplicationSet supplies cluster identity and `prod` as generator values;
the chart's site-specific route and namespace values remain in this chart.

The overlay must provide the environment, cluster and site-specific Gateway
values under `forecastle.forecastle.httpRoute`. Extend
`forecastle.forecastle.config.namespaceSelector.matchNames` deliberately when
new application namespaces should appear. The chart's upstream ClusterRole can read namespaces,
Ingresses, HTTPRoutes and ForecastleApps cluster-wide; the selector limits what
Forecastle displays, not the RBAC verbs granted by the upstream chart.

## Configuration and access

- Public endpoint: `https://mylogin.space/` through the configured Gateway API
  `HTTPRoute`.
- Discovery: `forecastle.stakater.com/expose: 'true'` annotations or
  `forecastle.stakater.com/v1alpha1` `ForecastleApp` resources in selected
  namespaces.
- Authentication is not bundled. Coordinate any OIDC or gateway policy with
  the owning Backplane ApplicationSet before exposing the dashboard publicly.
- No application data or persistent volume is created. Removing the release
  normally removes the Deployment, Service, route, RBAC and chart-managed CRD
  resources; the owning ApplicationSet preserves resources on application
  deletion, and discovered applications remain owned by their source resources.

## Prerequisites

- Argo CD with the Lovely renderer and Helm support.
- Gateway API CRDs and a Gateway that accepts the configured parent reference.
- Forecastle's CRD support is enabled by this chart; the CRD must be permitted
  by the cluster's deployment policy.

## Validation

```sh
helm dependency build Landing
helm lint Landing
helm template core-business-landing Landing --values Landing/values.yaml >/tmp/core-business-landing.yaml
git diff --check -- Landing
```

Render again with the exact Backplane-injected values before enabling the
ApplicationSet. Inspect the complete output for route parent references,
namespace scope, RBAC, image tag and public access policy. After reconciliation,
verify the Gateway route, `/healthz`, discovery of one annotated application,
and the `ForecastleApp` CRD path if it is used.

## Upstream projects

- [Forecastle website and source](https://github.com/stakater/Forecastle)
- [Forecastle Helm chart](https://github.com/stakater/Forecastle/tree/master/deployments/kubernetes/chart/forecastle)
- [Forecastle icon collection](https://github.com/stakater/ForecastleIcons)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
