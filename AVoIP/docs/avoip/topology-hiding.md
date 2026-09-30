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

`contact_mode=1` retains each side's meaningful Contact user and places the
opaque TOPOS lookup key in the `tps` URI parameter. The Contact itself uses the
site-specific public identity toward Flowroute and the private Kamailio Service
identity toward FreeSWITCH. TOPOS owns Contact and Record-Route hiding; the
old manual `remove_hf_match` and `subst_hf` transformations must not be
reintroduced. Caller E.164, called DID, trusted PAI, timers, and RTPEngine-
rewritten SDP remain useful call identity. Carrier Via, Contact, route sets,
and SBC addresses must remain outside FreeSWITCH.

The paired RR set is the authoritative public/private interface map. The
carrier-to-backend helper orders outbound `private_tls` then inbound
`public_tls`; the backend-to-carrier helper reverses that order. `rr` adds
socket-name metadata, and `r2=on` lets normal loose routing consume the pair
as a unit. Dialog Contact identities remain site-pinned even when the global
SIP name is used for new-call discovery. Kamailio owns Flowroute's configured
TLS egress target; FreeSWITCH does not select a carrier.

A successful INVITE's 2xx ACK is a separate SIP transaction: it must be
accepted through dialog/TOPOS routing even when `t_check_trans()` cannot find
the original INVITE transaction. Transaction matching is reserved for ACKs
to non-2xx final responses.

The topology store is site-local. It supports another Kamailio replica in the
same site, but does not make FreeSWITCH dialogs or RTPEngine UDP ownership
portable across sites.
