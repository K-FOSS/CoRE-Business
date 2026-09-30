# Homer storage

The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
renders this chart through Lovely into `core-prod`. Homer is enabled on the
`core-dc1-talos-prod` and `core-home1-talos-prod` clusters. It is disabled on
`dc1-k3s-node1` through `homer.disabledClusters` because that cluster does not
have the Longhorn provisioner owned by the [Backplane storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).

Each enabled cluster gets the chart-owned `avoip-homer-rwx` StorageClass and a
10 GiB `ReadWriteMany` Homer PVC named `<release>-homer-rwx`. The class uses
[Longhorn RWX volumes](https://longhorn.io/docs/1.12.0/nodes-and-volumes/volumes/rwx-volumes/)
with `numberOfReplicas: '2'`, `migratable: 'false'`, the `default` backup target,
and a retained volume. The Longhorn replica count describes storage copies;
Homer itself runs one pod with a `Recreate` rollout because its SQLite and
DuckDB catalogs have one writer. The StorageClass is cluster-scoped, while the
claim and data stay in each site's `core-prod` namespace. The sites do not
share a catalog or recordings. The configured backup target does not itself
confirm that a backup has completed.

The previous `longhorn` `ReadWriteOnce` PVC cannot change access mode or
StorageClass in place. The new `-homer-rwx` claim started empty; existing
`-homer-data` claims and Longhorn volumes were retained without copying their
traces. Earlier calls therefore do not appear in the new Homer UI. The old
claims can be mounted separately for recovery. The new claim has
`Prune=false,Delete=false` annotations, so removing the chart does not delete
its data. A rollback to an old claim selects its old dataset; it does not merge
the datasets.

`homer.storage.retentionDays` defaults to 14 days for Homer trace compaction.
The separate [call recording player](HOMER-AUDIO.md) cleans WAV files from the
FreeSWITCH fax spool after 2 days by default. The Homer RWX claim does not hold
those WAVs or fax TIFFs.

Before reconciling, render the hub, Home1, and k3s value layers. Confirm only
the first two render `avoip-homer-rwx`, a new RWX PVC, and the Homer deployment;
the k3s render must omit all Homer resources and Kamailio Homer HEP settings.
After a scoped Argo CD sync, confirm the StorageClass parameters, new PVC
`Bound` state, Longhorn share manager, and Homer pod readiness. Place a call
and confirm new SIP messages appear in that site's Homer UI. Check the old
claims remain available for recovery and verify an actual Longhorn backup
before relying on backup-based restoration.
