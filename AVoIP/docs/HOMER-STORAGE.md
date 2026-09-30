# Homer storage

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
renders this chart through Lovely into `core-prod`. Homer is enabled on the
`core-dc1-talos-prod` and `core-home1-talos-prod` clusters. It is disabled on
`dc1-k3s-node1` through `homer.disabledClusters` because that cluster does not
have the Longhorn provisioner owned by the [Backplane storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).

Each enabled cluster gets the chart-owned `avoip-homer-rwx` StorageClass and a
10 GiB `ReadWriteMany` Homer PVC. The class uses [Longhorn RWX volumes](https://longhorn.io/docs/1.12.0/nodes-and-volumes/volumes/rwx-volumes/)
with `numberOfReplicas: '2'`, `migratable: 'false'`, the `default` backup target,
and a retained volume. Homer remains at one replica and uses a Recreate rollout
because its SQLite and DuckDB catalogs have one writer. StorageClass is a
cluster-scoped resource; the claim, deployment and Homer data remain in
`core-prod`.

The previous `longhorn` `ReadWriteOnce` PVC cannot change access mode or
StorageClass in place. The new claim uses a new `-homer-rwx` name and starts
empty. Existing `-homer-data` claims and their Longhorn volumes are retained;
their earlier call traces do not appear in the new Homer UI. Do not delete the
old claims as part of this rollout. They can be mounted separately for recovery
if those traces are needed. The new claim also has retention annotations so
removing this chart does not delete its data. A rollback to the old claim would
switch Homer back to the old dataset, not merge the two datasets.

Before reconciling, render the hub, Home1, and k3s value layers. Confirm only
the first two render `avoip-homer-rwx`, a new RWX PVC, and the Homer deployment;
the k3s render must omit all Homer resources and Kamailio Homer HEP settings.
After a scoped Argo CD sync, confirm the StorageClass parameters, new PVC
`Bound` state, Longhorn share manager, and Homer pod readiness. Place a call
and confirm new SIP messages appear in Homer. Check the old PVCs remain bound.
