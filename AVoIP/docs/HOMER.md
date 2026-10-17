# Homer 11 SIP monitoring

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml) renders this chart through Lovely into `core-prod`. The chart enables [Homer 11](https://sipcapture.github.io/homer/) on the DC1 hub and Home1 spoke, where Kamailio is enabled. `homer.disabledClusters` excludes `dc1-k3s-node1`, which has no Longhorn provisioner. Each enabled site has its own capture data and UI. See the [source repository](https://github.com/sipcapture/homer) for the upstream all-in-one server.

## Capture and access

[Kamailio SIP trace](https://www.kamailio.org/docs/modules/stable/modules/siptrace.html) sends HEPv3 SIP requests and replies from carrier and private SBC instances to the site-local Homer TCP listener on `9061`. It also sends `hlog()` HEP events correlated by Call-ID when Kamailio selects a backend, Asterisk SIP Core, the authenticated outbound carrier path, or a carrier dialog route. Those events include the decision label, SIP method and CSeq, source socket, selected destination URI, request URI, and transport; they do not copy SIP headers or message bodies. Homer can therefore show routing decisions alongside the SIP ladder. The internal FreeSWITCH Kamailio profile sends SIP messages and FreeSWITCH channel metadata over HEPv3/UDP to port `9060`, using FreeSWITCH's [Homer HEP capture agent](https://github.com/sipcapture/homer/wiki/Examples%3A-FreeSwitch); the public/Flowroute profile remains excluded. [RTPEngine Homer capture](https://github.com/sipwise/rtpengine/blob/master/docs/rtpengine.md) sends RTCP statistics and NG control metadata to the listener when RTPEngine is enabled. RTPEngine binds its NG listener to the pod IP so NG traces use that address instead of the unspecified `0.0.0.0` listener address; the pod IP changes when the pod is replaced. The cluster-only capture Service also exposes metrics TCP `9096`. The ingest HTTP listener uses container port `9080`; the coordinator UI and v4 API use container port `8080` behind the web Service on port `80`. The HEP and metrics ports have no public route.

Kamailio's default `listeners.bindAddress: ''` selects the pod's `status.podIP` through the Downward API. Its preprocessor substitutes only the listener token, preserving SIP script variables. Concrete listeners give outbound SIP traces and [`hlog()` events](https://github.com/kamailio/kamailio/blob/6.1/src/modules/siptrace/siptrace_hep.c) the emitting pod's IP in their HEP source field. Received SIP traces retain the original peer's source address. Public and private SIP advertised identities remain configured independently. An explicit `listeners.bindAddress` overrides this default; a wildcard override can reintroduce unspecified HEP addresses. RTPEngine's UDP NG and optional HTTP/WebSocket listeners also bind to `status.podIP`. Replacement pods automatically use their new addresses. Previously stored traces retain their original metadata.

Homer stores signaling and diagnostic metadata. It does not store RTP payload audio. The separate [FreeSWITCH recording player](HOMER-AUDIO.md) serves WAV files under `/recordings/` on the Homer hostname, but the Homer call-flow view does not automatically attach a WAV to its Call-ID.

AVoIP preserves each B2BUA leg's native SIP `Call-ID`. For SIP Core call
signaling (not REGISTER/OPTIONS), the trusted internal Kamailio edge removes
caller-supplied correlation headers and sets `X-Call-ID` to that dialog's
existing `$ci` value. Asterisk copies the trusted value to its outbound
FreeSWITCH channel; FreeSWITCH exports it to the carrier leg. Kamailio also
echoes the trusted alias in SIP Core responses. Thus forwarded internal and
carrier HEP messages resolve to the same `cid` / `data_extra.x_call_id`, while
each dialog retains its native `session_id`. The initial client packet may be
captured before Kamailio adds the alias; its forwarded transaction and reply
records carry it. No Call-ID, tag, CSeq, Via, Route, or Record-Route is
rewritten. `X-Core-Call-Linkedid` and
`X-Core-Origin-Uniqueid` continue to carry Asterisk's linked ID and originating
channel ID for diagnostics; they are not overwritten by the Homer alias.

Homer's `ingest.sip.aleg_ids` maps `X-Call-ID` into HEP `cid`; its custom-header
list retains the Core linked/origin IDs in `data_extra`. The SIP table's
`uuid` is a per-record identifier, not the logical call key. `session_id` is
the native SIP Call-ID and `cid` is the correlation alias. Homer 11's
coordinator correlation engine seeds the B2B Lua script disabled by default.
The live coordinator reported zero active scripts, so an administrator must
enable the `1_call` SIP correlation script once in **Settings → Scripts** (or
through the Homer scripts API). Once enabled, its lookup of
`data_extra.x_call_id` against the selected native `session_id` joins the
dialogs without merging them. Unrelated dialogs, including a later dialog
with a different originating Call-ID, remain separate.

The repository setting cannot activate this Homer script declaratively: Homer
11's `seed_default` creates inactive rows, and active script state is stored in
Homer's persistent settings database. No storage/schema migration is required.
Existing captures are not rewritten; verify new calls after enabling the
script and reconciling this chart.

The default hostname is `homer.<cluster>.<datacenter>.<region>.resolvemy.host`; `homer.hostname` can override it. The hub and Home1 therefore have separate URLs and separate Authentik applications. The [HTTPRoute](../templates/Homer/HomerRoute.yaml) applies Gateway Forward Auth to the UI and recordings. Only the exact OIDC callback path `/api/v4/auth/oauth2/authentik/callback` bypasses that outer check so Homer can exchange the authorization code.

Homer uses Authentik OIDC with PKCE and OAuth-only login. Its site-specific callback URL is `https://<homer-hostname>/api/v4/auth/oauth2/authentik/callback`. The chart's Authentik Workspaces create the OIDC client and Forward Auth application for the `Home Users` group; the OIDC client credentials and generated JWT secret reach the pod through the Workspace connection Secret. Homer 7's old login URLs redirect to the Homer 11 root login page.

## Storage and retention

The pinned `ghcr.io/sipcapture/homer:11.0.350` image writes its SQLite DuckLake catalog, DuckDB settings catalog, Parquet files, and spill data under `/data/homer`. The new dedicated 10 GiB Longhorn RWX claim started empty because Homer 7 traces were not copied. Homer runs one pod with a `Recreate` rollout to keep a single catalog writer. `homer.storage.retentionDays` controls Homer trace compaction and defaults to 14 days; recording cleanup is separate. See [Homer storage and recovery](HOMER-STORAGE.md).

Homer 11 does not use the old Homer 7 PostgreSQL databases or `heplify-server` schema. The old database resources and claims were retained for recovery, with no automatic trace migration. Review their data and deletion policies through the site storage and PostgreSQL workflows before removing them.

## Verification

After the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml) and site application reconcile:

1. Confirm both Authentik Workspaces and their connection Secret are ready without printing Secret data.
2. Confirm the site Homer PVC is `Bound`, the share manager is ready, and the single Homer pod starts without catalog or filesystem errors.
3. Confirm private and carrier Kamailio, FreeSWITCH, and RTPEngine HEP delivery to the site-local Service. Search a new internal call by Call-ID in that site's Homer UI and verify SIP messages, Kamailio routing-decision events, FreeSWITCH channel events, and the available RTCP/NG diagnostics. Compare locally emitted SIP and routing-event source IPs with the emitting pod's `status.podIP`; received SIP sources should remain the original peer. Check new traces after a rollout, since stored traces are not rewritten.
4. Verify an unauthenticated UI or `/recordings/` request is challenged by Authentik. Verify the OIDC callback returns to the same site hostname and that Homer queries use `/api/v4`.

For the DC1 hub, inspect resource status and logs without exposing Secret values:

```sh
kubectl --context core-dc1-talos-prod -n core-prod get pod,svc,pvc \
  -l app.kubernetes.io/instance=core-dc1-talos-prod-business-avoip-prod
kubectl --context core-dc1-talos-prod -n core-prod logs \
  deploy/core-dc1-talos-prod-business-avoip-prod-avoip-homer-web -c homer
```

Deleting the application does not delete the retained Homer RWX claim or its Longhorn volume. Follow [Homer storage and recovery](HOMER-STORAGE.md) before any manual removal.
