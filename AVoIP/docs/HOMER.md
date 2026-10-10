# Homer 11 SIP monitoring

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml) renders this chart through Lovely into `core-prod`. The chart enables [Homer 11](https://sipcapture.github.io/homer/) on the DC1 hub and Home1 spoke, where Kamailio is enabled. `homer.disabledClusters` excludes `dc1-k3s-node1`, which has no Longhorn provisioner. Each enabled site has its own capture data and UI. See the [source repository](https://github.com/sipcapture/homer) for the upstream all-in-one server.

## Capture and access

[Kamailio SIP trace](https://www.kamailio.org/docs/modules/stable/modules/siptrace.html) sends HEPv3 SIP requests and replies from carrier and private SBC instances to the site-local Homer TCP listener on `9061`. The internal FreeSWITCH Kamailio profile sends SIP messages and FreeSWITCH channel metadata over HEPv3/UDP to port `9060`, using FreeSWITCH's [Homer HEP capture agent](https://github.com/sipcapture/homer/wiki/Examples%3A-FreeSwitch); the public/Flowroute profile remains excluded. [RTPEngine Homer capture](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md) sends RTCP statistics and NG control metadata to the listener when RTPEngine is enabled. The cluster-only capture Service also exposes metrics TCP `9096`. The ingest HTTP listener uses container port `9080`; the coordinator UI and v4 API use container port `8080` behind the web Service on port `80`. The HEP and metrics ports have no public route.

Homer stores signaling and diagnostic metadata. It does not store RTP payload audio. The separate [FreeSWITCH recording player](HOMER-AUDIO.md) serves WAV files under `/recordings/` on the Homer hostname, but the Homer call-flow view does not automatically attach a WAV to its Call-ID.

The default hostname is `homer.<cluster>.<datacenter>.<region>.resolvemy.host`; `homer.hostname` can override it. The hub and Home1 therefore have separate URLs and separate Authentik applications. The [HTTPRoute](../templates/Homer/HomerRoute.yaml) applies Gateway Forward Auth to the UI and recordings. Only the exact OIDC callback path `/api/v4/auth/oauth2/authentik/callback` bypasses that outer check so Homer can exchange the authorization code.

Homer uses Authentik OIDC with PKCE and OAuth-only login. Its site-specific callback URL is `https://<homer-hostname>/api/v4/auth/oauth2/authentik/callback`. The chart's Authentik Workspaces create the OIDC client and Forward Auth application for the `Home Users` group; the OIDC client credentials and generated JWT secret reach the pod through the Workspace connection Secret. Homer 7's old login URLs redirect to the Homer 11 root login page.

## Storage and retention

The pinned `ghcr.io/sipcapture/homer:11.0.350` image writes its SQLite DuckLake catalog, DuckDB settings catalog, Parquet files, and spill data under `/data/homer`. The new dedicated 10 GiB Longhorn RWX claim started empty because Homer 7 traces were not copied. Homer runs one pod with a `Recreate` rollout to keep a single catalog writer. `homer.storage.retentionDays` controls Homer trace compaction and defaults to 14 days; recording cleanup is separate. See [Homer storage and recovery](HOMER-STORAGE.md).

Homer 11 does not use the old Homer 7 PostgreSQL databases or `heplify-server` schema. The old database resources and claims were retained for recovery, with no automatic trace migration. Review their data and deletion policies through the site storage and PostgreSQL workflows before removing them.

## Verification

After the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml) and site application reconcile:

1. Confirm both Authentik Workspaces and their connection Secret are ready without printing Secret data.
2. Confirm the site Homer PVC is `Bound`, the share manager is ready, and the single Homer pod starts without catalog or filesystem errors.
3. Confirm private and carrier Kamailio, FreeSWITCH, and RTPEngine HEP delivery to the site-local Service. Search a new internal call by Call-ID in that site's Homer UI and verify SIP messages, FreeSWITCH channel events, and the available RTCP/NG diagnostics.
4. Verify an unauthenticated UI or `/recordings/` request is challenged by Authentik. Verify the OIDC callback returns to the same site hostname and that Homer queries use `/api/v4`.

For the DC1 hub, inspect resource status and logs without exposing Secret values:

```sh
kubectl --context core-dc1-talos-prod -n core-prod get pod,svc,pvc \
  -l app.kubernetes.io/instance=core-dc1-talos-prod-business-avoip-prod
kubectl --context core-dc1-talos-prod -n core-prod logs \
  deploy/core-dc1-talos-prod-business-avoip-prod-avoip-homer-web -c homer
```

Deleting the application does not delete the retained Homer RWX claim or its Longhorn volume. Follow [Homer storage and recovery](HOMER-STORAGE.md) before any manual removal.
