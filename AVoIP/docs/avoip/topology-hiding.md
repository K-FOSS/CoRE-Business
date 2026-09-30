# SIP topology hiding

When enabled, Kamailio loads `ndb_redis`, `topos`, and `topos_redis`. The
topology state is stored in the site-local `dragonfly-core` Redis-compatible
cluster, using logical database `51`; it is not shared with RTPEngine's
Valkey state. The [Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml)
and its [allocation registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md)
are authoritative for that service and allocation.

The chart creates `avoip-kamailio-topos` through External Secrets. Its `server`
key contains the ndb_redis definition with TLS, the site Dragonfly endpoint,
DB 51, and the Vault-sourced password. Kamailio receives that value only via
`TOPOS_REDIS_SERVER`.

`contact_mode=3` gives the carrier/public and FreeSWITCH/private sides
different Contact domains. TOPOS owns Contact and Record-Route hiding; the
old manual `remove_hf_match` and `subst_hf` transformations must not be
reintroduced. Caller E.164, called DID, trusted PAI, timers, and RTPEngine-
rewritten SDP remain useful call identity. Carrier Via, Contact, route sets,
and SBC addresses must remain outside FreeSWITCH.

The topology store is site-local. It supports another Kamailio replica in the
same site, but does not make FreeSWITCH dialogs or RTPEngine UDP ownership
portable across sites.
