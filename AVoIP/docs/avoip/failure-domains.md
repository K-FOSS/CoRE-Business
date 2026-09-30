# Failure domains

| Layer | Current scope | Replication / limitation |
| --- | --- | --- |
| Envoy | Site public SIP VIP | Site-local replica count remains deployment-controlled; TCP/TLS connections may terminate on pod loss. |
| Kamailio | Site SIP border | Chart target is three replicas per site with anti-affinity, hostname spread, PDB minAvailable 2, and site-local TOPOS state in Dragonfly. Transactions and TCP/TLS connections remain pod-local. |
| FreeSWITCH | Site B2BUA | One replica; dialogs are process-local and require affinity before scaling. |
| Asterisk | Internal application/fax peer | Reached through FreeSWITCH, never public by default. |
| RTPEngine | Site media anchor | One replica by default; Valkey recovery does not prove UDP takeover. |
| Dragonfly | Site-local topology state | DB 51 is independent of RTPEngine Valkey and is not cross-site replicated. |

Site-local HA must pass disruption testing before duplicating the pattern at a
second site. New dialogs may use health-aware DNS or anycast later; established
dialogs must retain their site identity and route/media ownership.
