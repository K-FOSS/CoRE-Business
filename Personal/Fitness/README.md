# K-FOSS/CoRE-Business Personal/Fitness

This chart is the home for personal health and fitness services: workout
tracking, Apple Health imports, analysis and related personal tools. openGym is
the first deployed service, but it is a component of the stack rather than the
stack's identity. Future services should be able to consume shared health data
without making openGym their system of record.

## Current deployment

The live chart deploys [openGym](https://opengym.duarte-santos.ch/), a
self-hosted workout and body-weight tracker, with the
[BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It serves `gym.mylogin.space` through a Gateway API HTTPRoute. The web
container proxies `/api` to the internal API Service so openGym's WebAuthn
passkey flow remains on one HTTPS origin.

The owning [Fitness ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Personal/Fitness.yaml)
selects `core-home1-talos-prod`, deploys to `core-fitness-prod`, and renders
this path with the [Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin).
It injects the cluster identity and the `main-gw` / `https-myloginspace` Gateway
attachment. The live endpoint is `https://gym.mylogin.space`.

The chart uses the upstream `1.3.5` web and API images and initializes the
exercise media PVC from a pinned commit of the
[exercise dataset](https://github.com/hasaneyldrm/exercises-dataset). User
profiles, passkeys, workout history, session state and generated notification
keys are retained on a 10Gi Longhorn PVC at `/data`; the media PVC is retained
separately. Back up both claims before removal or migration.

The web container drops all Linux capabilities except `CHOWN`, `SETGID` and
`SETUID`. These narrow exceptions are required because the upstream
[Nginx web image](https://github.com/DuarteSantos8/openGym/blob/main/web/Dockerfile)
changes ownership of `/var/cache/nginx/client_temp` and drops workers to UID/GID
101 during startup.

The web container's Docker-only `127.0.0.11` resolver is overridden with the
site's cluster DNS endpoint, currently `k0s.resolvemy.host` (resolved in-cluster
to `10.44.4.10`). The owning ApplicationSet must override `clusterDNS` when
targeting a different cluster; this is a required deployment input, not a
portable chart default.

Access is protected by the site Authentik forward-auth outpost through an
Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/latest/api/gateway_api/v1alpha1/securitypolicy/);
the policy fails closed and forwards Authentik session and identity headers to
openGym. The Backplane Authentik proxy Service must remain available as
`aaa-myloginspace-proxy` in `core-prod`. The chart's
`<release-name>-authentik` Terraform Workspace creates the forward-auth
provider and application through the Backplane `authentik` ProviderConfig.
The chart does not currently use PostgreSQL, External Secrets or the Backplane
`User` resource.

openGym passkeys are bound to the exact `gym.mylogin.space` RP ID. Do not
change the hostname after profiles are created without re-registering their
passkeys. The route is labeled public/private for the site gateway and is not
exposed through Forecastle; review the gateway's inherited access policy before
activation.

## Apple Health direction

Apple Health importing is planned, not deployed by this chart yet. The intended
boundary is a separate ingestion and dashboard component alongside openGym:

```text
Health Auto Export on iPhone
        -> versioned JSON/CSV over REST API (or an initial file drop)
        -> authenticated ingestion endpoint and durable health-data store
        -> private dashboard and analysis services
```

[Health Auto Export](https://github.com/Lybron/health-auto-export) supports
Apple Health metrics and workouts, versioned JSON/CSV exports, and automated
delivery to REST APIs and other destinations. Its [JSON export
documentation](https://github.com/Lybron/health-auto-export/wiki/JSON-Format)
should be treated as an external input contract and pinned/validated by the
future importer. The importer should be idempotent, retain the original export
or a recovery copy, record the source/export version, and normalize timestamps,
units and workout identifiers before exposing data to dashboards.

The future importer must have its own persistence and API boundary rather than
writing into openGym's `/data` claim. The dashboard should be private behind
the same site access controls, with a separate hostname and Authentik
application when it is introduced. Do not add a public or Forecastle route for
health data. Health exports can contain sensitive activity, medication,
location, ECG and mental-health information; do not log payloads or commit
sample exports, credentials or REST API tokens. Apple documents that HealthKit
access is permissioned per data type and that users can export their Health data
from the Health app, so the importer must make scope and retention explicit:
[Apple Health privacy](https://www.apple.com/legal/privacy/data/en/health-app/)
and [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).

Until that component exists, use Health Auto Export's manual or external export
destinations for experiments and keep them outside this chart's deployed
resources. Adding the importer will require a new workload, API authentication
and secret handling, persistence sizing/backups, a dedicated route and an
updated owning ApplicationSet; none of those are implied by the current
openGym deployment.

## Development and verification

```sh
helm dependency build Personal/Fitness
helm lint Personal/Fitness \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set clusterDNS=k0s.resolvemy.host
helm template core-business-fitness Personal/Fitness --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set clusterDNS=k0s.resolvemy.host \
  >/tmp/core-business-fitness.yaml
```

Review the upstream [openGym source repository](https://github.com/alexpcosta/opengym),
[self-hosting guide](https://github.com/alexpcosta/opengym/blob/main/docs/SELF_HOSTING.md),
[Health Auto Export project](https://github.com/Lybron/health-auto-export),
[Authentik forward-auth documentation](https://docs.goauthentik.io/add-secure-apps/providers/proxy/forward_auth/),
[BJW-S Common](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common),
[Envoy Gateway SecurityPolicy documentation](https://gateway.envoyproxy.io/latest/api/gateway_api/v1alpha1/securitypolicy/),
and [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) documentation.
Verify the live route, `/api/health`, profile creation, passkey sign-in from a
second device, media loading and restore of both PVCs. The ApplicationSet keeps
resources on deletion; treat both retained claims as production data and back
them up before migration or removal.
