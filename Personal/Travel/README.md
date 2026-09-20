# K-FOSS/CoRE-Business Personal/Travel

This directory contains personal travel, flight, routing, adventure planning,
logging, and tracking applications for
[K-FOSS/CoRE-Business](https://github.com/K-FOSS/CoRE-Business).

The current stack is AdventureLog, a personal
[BJW-S Common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
AdventureLog is the [self-hosted travel tracker and trip planner](https://adventurelog.app/)
from [seanmorley15/AdventureLog](https://github.com/seanmorley15/AdventureLog), pinned here
to v0.13.0.

The chart runs AdventureLog's all-in-one image behind the `main-gw` Gateway and
stores uploaded media in a retained Longhorn PVC. PostgreSQL is supplied by the
site's shared Backplane database service through a `mylogin.space/v1alpha1 User`
resource, and the chart enables the required PostGIS extension with Crossplane.
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
