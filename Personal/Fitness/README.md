# openGym

This live chart deploys [openGym](https://opengym.duarte-santos.ch/), a
self-hosted workout and body-weight tracker, with the
[BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It serves `gym.mylogin.space` through a Gateway API HTTPRoute and uses openGym's
own passkey login. The web container proxies `/api` to the internal API Service,
so WebAuthn remains on one HTTPS origin.

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

The chart overrides the image's Docker-only `127.0.0.11` resolver with the
site's cluster DNS endpoint, `10.44.4.10`. The owning ApplicationSet
must override `clusterDNS` when targeting a different cluster.

The live ApplicationSet injects `cluster.name`, `datacenter` and `region`, and
selects the target namespace and renderer. Resources use the stable `fitness`
fullname so site-qualified release names cannot create invalid Service names.
The web route is protected by the site Authentik
forward-auth outpost through an Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/latest/api/gateway_api/v1alpha1/securitypolicy/);
the policy fails closed and forwards Authentik session and identity headers to
openGym. The Backplane Authentik proxy Service must remain
available as `aaa-myloginspace-proxy` in `core-prod`. The chart's
`<release-name>-authentik` Terraform Workspace creates the forward-auth
provider and application through the Backplane `authentik` ProviderConfig. The
chart does not use PostgreSQL, External Secrets or the Backplane `User` resource.

openGym passkeys are bound to the exact `gym.mylogin.space` RP ID. Do not
change the hostname after profiles are created without re-registering their
passkeys. The current route is labeled public/private for the site gateway and
is not exposed through Forecastle; review the gateway's inherited access policy
before activation.

```sh
helm dependency build Personal/Fitness
helm lint Personal/Fitness --set cluster.name=core-home1-talos-prod --set datacenter=yvr --set region=yvr
helm template core-business-fitness Personal/Fitness --namespace core-prod \
  --set cluster.name=core-home1-talos-prod --set datacenter=yvr --set region=yvr \
  >/tmp/core-business-fitness.yaml
```

Review the upstream [openGym source repository](https://github.com/alexpcosta/opengym),
[self-hosting guide](https://github.com/alexpcosta/opengym/blob/main/docs/SELF_HOSTING.md),
[Authentik forward-auth documentation](https://docs.goauthentik.io/add-secure-apps/providers/proxy/forward_auth/),
[BJW-S Common](https://github.com/bjw-s-labs/helm-charts/tree/main/charts/library/common),
[Envoy Gateway SecurityPolicy documentation](https://gateway.envoyproxy.io/latest/api/gateway_api/v1alpha1/securitypolicy/),
and [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) documentation.
Verify the live route, `/api/health`, profile creation, passkey sign-in from a
second device, media loading and restore of both PVCs. The ApplicationSet keeps
resources on deletion; treat both retained claims as production data and back
them up before migration or removal.
