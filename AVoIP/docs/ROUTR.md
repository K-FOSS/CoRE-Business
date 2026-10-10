# Routr Connect pilot

AVoIP contains an opt-in rendering of the upstream [Routr Connect chart source](https://github.com/fonoster/routr/tree/v2.13.6/ops/charts/connect), adapted to the existing [BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/). Routr is disabled by default. Asterisk remains the only active registrar and SIP authentication authority.

## Shared services and ownership

When enabled, Routr uses the site-local shared PostgreSQL service through a [`User.mylogin.space/v1alpha1` claim](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml). The User Composition provisions the service identity and database and publishes its connection Secret; the chart injects `psqlURI` only into the Routr API server and migration Job. PostgreSQL is owned by [Backplane's PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml). Routr uses the shared Dragonfly TLS endpoint and existing CoreVault password reference. Dragonfly is owned by [Backplane's Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml). Location uses Dragonfly logical database 155 and Registry uses database 156.

Routr 2.13.6 does not expose a Redis database selector in its Location or Registry configuration parser. The version-controlled [patch](../image/routr-db-selection.patch) adds `dbNumber` and appends it to the Redis URL. The [Forgejo build](../../.forgejo/workflows/routr-db-selection.yaml) uses a digest-pinned [official Node container](https://github.com/nodejs/docker-node) so JavaScript Actions such as checkout have a runtime before build steps start. It selects Node 20 for the Routr build, fetches pinned source commit `978336c7e0625fa5cb36a4db57acbf45b977c900`, applies the patch, runs focused tests, builds amd64 images from the same source tree, and publishes immutable commit-tagged images. The rendered chart requires their image digests before it can be enabled.

The shared Dragonfly logical database allocation registry is in [CoRE-Backplane](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md); commit [`427b9b5b`](https://github.com/K-FOSS/CoRE-Backplane/commit/427b9b5b) reserves 155 for Routr Location and 156 for Routr Registry. These numbers are site-local logical databases, not isolation boundaries. They share Dragonfly capacity, credentials, persistence, and failure domain.

The chart does not deploy the upstream PostgreSQL or Redis subcharts. Routr's upstream [PostgreSQL](https://github.com/fonoster/routr/tree/v2.13.6/ops/charts/connect/charts/postgresql) and [Redis](https://github.com/fonoster/routr/tree/v2.13.6/ops/charts/connect/charts/redis) dependencies are intentionally excluded so the pilot uses shared platform services.

## Current pilot boundaries

The chart renders the Routr API server, Connect, Dispatcher, Location, Registry, Requester, and database migration Job when `routr.enabled` is true. EdgePort is not rendered unless a transport is requested. The current templates reject EdgePort transports because cert-manager PKCS#12 material, an explicit SIP ingress policy, and any gateway/backend integration are not wired. The defaults expose no SIP listener and create no public Service or HTTPRoute.

This is a disabled pilot scaffold, not a production SIP cutover. No current SIP route points to Routr. Existing carrier, Asterisk, Kamailio, FreeSWITCH, RTPEngine, and Envoy paths are unchanged. Do not enable Routr until image digests are published, the DB allocations are registered, the migration Job and shared services have been checked against the target site, and the EdgePort certificate and ingress design is completed.

## Values example for a staged internal pilot

Use this only in a site-specific values layer after the checks above. Replace the digest values with the exact digests reported by the successful Forgejo workflow. Keep all EdgePort transports disabled until certificate and network ingress support is implemented.

```yaml
routr:
  enabled: true
  imageVersion: '2.13.6'
  imageDigests:
    location: 'sha256:REPLACE_WITH_PUBLISHED_LOCATION_DIGEST'
    registry: 'sha256:REPLACE_WITH_PUBLISHED_REGISTRY_DIGEST'
  database:
    username: routr
    connectionSecret: ''
    host: ''
    terraformProvider: ''
    crossplaneProvider: ''
  redis:
    host: ''
    port: 6379
    secretStore: corevault-rootsecrets
    secretKey: ''
    locationDatabase: 155
    registryDatabase: 156
  edgeport:
    udp: {enabled: false, port: 5060}
    tcp: {enabled: false, port: 5060}
    tls: {enabled: false, port: 5061}
    ws: {enabled: false, port: 5062}
    wss: {enabled: false, port: 5063}
```

Empty host, Secret, and provider values resolve from the release's site values using the existing AVoIP conventions. Do not put database passwords or Dragonfly credentials in Helm values. The Redis ExternalSecret renders a Kubernetes Secret mounted only by Location and Registry; no Redis credential is placed in a ConfigMap.

## Render and image checks

Run:

```sh
helm lint AVoIP
AVoIP/tests/routr-connect-render.sh
```

The test confirms no Routr resources render by default, verifies the shared-service connection and DB numbers in the opt-in render, and checks that missing image digests or changed DB allocations fail rendering. It does not contact PostgreSQL or Dragonfly, run the Prisma migration, test SIP signaling, validate the certificate chain, or exercise live gateway routing.

Before enabling, use the workflow summary's exact digest values in the site-local values layer and render with the actual Backplane-injected values. Confirm the `User` claim produces `psqlURI`, the SecretStore resolves the Dragonfly password, Cilium allows the intended shared-service connections, and the migration Job reaches success. Run a separate SIP pilot only after EdgePort ingress and TLS are implemented.

## Rollback

Routr is off by default, so rollback from an unconnected pilot is to set `routr.enabled: false` and reconcile AVoIP. This removes the Routr workloads and Secrets managed by the chart; the User claim's Crossplane and external database deletion behavior must be inspected before removing the claim. Do not delete the shared Dragonfly instance or its logical databases during application rollback. Preserve the allocation registry until Routr data has been deliberately retired.
