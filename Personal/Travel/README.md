# K-FOSS/CoRE-Business Personal/Travel

This directory contains personal travel, flight, routing, adventure planning,
logging, and tracking applications for
[K-FOSS/CoRE-Business](https://github.com/K-FOSS/CoRE-Business).

The current stack is AdventureLog, a personal
[BJW-S Common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
AdventureLog is the [self-hosted travel tracker and trip planner](https://adventurelog.app/)
from [seanmorley15/AdventureLog](https://github.com/seanmorley15/AdventureLog), pinned here
to v0.13.0.

The chart runs AdventureLog's split frontend and backend images behind the
`main-gw` Gateway. The frontend is exposed at `adventurelog.mylogin.space` and
the backend/API at `adventurelog-api.mylogin.space`; uploaded media is stored in
a retained Longhorn PVC mounted only by the backend. PostgreSQL is supplied by
the site's shared Backplane database service through a
`mylogin.space/v1alpha1 User` resource, and the chart enables the required
PostGIS extension with Crossplane.
The relevant site services are owned by the Backplane
[`Storage/Base.yaml`](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
and [`Storage/PSQL.yaml`](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
ApplicationSets; the database user contract is defined by the
[Backplane User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
The generated Django secret and first-admin password are retained by External
Secrets; no credential values are committed.

The current Backplane tree does not yet contain an owning AdventureLog
ApplicationSet. Add one under
[`Apps/Business/Personal/`](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Apps/Business/Personal)
before expecting Argo CD to deploy this directory. That ApplicationSet must
inject `cluster.name`, `datacenter`, `region`, and the environment-specific
PostgreSQL provider names, and must render this directory through the
[Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin).

The first-admin password is generated into the `adventurelog-admin` Secret and
must be retrieved through the cluster's approved secret-access workflow. User
registration is disabled; create additional users after signing in as the
generated admin.

## TODO

- [ ] Add a flight tracker/logging service alongside AdventureLog. Evaluate:
  - [AirTrail](https://airtrail.johan.ohly.dk/), a self-hosted open-source
    personal flight-tracking system and the strongest initial fit for this
    stack.
  - [Jetlog](https://github.com/pbogre/jetlog), a self-hosted flight log with
    map/statistics views and import/export support; review its authentication,
    image pinning, and external API behavior before deployment.
  - A small companion service backed by the [OpenSky Network API](https://openskynetwork.github.io/opensky-api/)
    for live aircraft positions. OpenSky is suitable for research and
    non-commercial use, but does not provide commercial schedules or delay
    data.
  - [FlightAware AeroAPI](https://www.flightaware.com/commercial/aeroapi/)
    for richer flight status, ETA, history, and alerts if paid API access is
    justified; [ADS-B Exchange](https://www.adsbexchange.com/data-products/)
    is an alternative for live positional data.
- [ ] Decide whether the requirement is primarily personal flight history,
  flight-status notifications, or a live aircraft map before choosing the
  deployment.
- [ ] Verify the selected project supports the repository's BJW-S, Lovely,
  Backplane PostgreSQL, private Gateway, and Authentik conventions, then add
  its own chart and ApplicationSet rather than coupling it to AdventureLog.
