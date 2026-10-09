# SIP switchboard and availability options

This is a decision guide for the next AVoIP chart changes. The current and
target call paths are in [SIP routing architecture](SIP-ROUTING-ARCHITECTURE.md).
For the stateful routing, replica balancing and multisite upgrade, use the
[phased architecture plan](SIP-STATEFUL-HA.md) and [TODO tracker](../TODO.md)
as the implementation and acceptance sequence; the options below are inputs
to its open decisions, not completed capabilities.
The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects each site's cluster identity, SIP hostname, media address and range,
and DID values through Lovely. No DID belongs in this repository.

## Current public SIP topology

The current public SIP border is the `carrier` Kamailio instance. The
ApplicationSet configures three carrier replicas at each deployed site, and
Home1 currently reports three desired and three ready carrier pods. Public SIP
TLS and the site's enabled UDP/TCP listeners attach to this carrier service.
Home1's private `internal` Kamailio instance is a separate one-replica service
for private application signaling; it is not the public SIP entry point.

The three carrier replicas provide same-site availability for new SIP
requests. A failed pod's in-flight transaction or established TCP/TLS
connection does not move to a peer, and the replica count does not provide
cross-site active-call migration. The public and private roles have separate
Services, listeners, and routing policies.

## Decide which failure to survive

| Goal | What can handle it | Remaining dependency |
| --- | --- | --- |
| A Kamailio pod fails inside one site | The other Kamailio replica can process a new SIP request using the carried Route set and identical script | The peer must reconnect or retry; an in-flight transaction and TLS connection cannot move |
| A backend service pod fails before a call is answered | A shared registration/contact directory and selection of another healthy backend | Backend health, capacity, authentication, and retry behavior must be defined |
| The site's ingress fails | K8GB and the other site's Gateway can accept **new** calls | Public DNS health, TTL, SNI fallback, certificates, and a healthy local SIP/media stack |
| The serving site fails during an answered call | Another site can identify the dialog owner if routing metadata is portable | The original PBX channel, peer media destination, and RTP session would also need a tested takeover mechanism; DNS and a shared Kamailio database do not recreate them |

The recommended first availability target is **new-call failover plus
same-site Kamailio replica failover**. Do not describe the stack as supporting
seamless cross-site active-call migration until SIP, call-control, and media
takeover have all been demonstrated with a real call.

## Where to keep registrations and routing data

| Option | Suitable use | Limitation or prerequisite | Decision |
| --- | --- | --- | --- |
| PostgreSQL `usrloc` in database-only mode | Service contacts visible to both Kamailio replicas in a single site; site-qualified Asterisk registration is the first pilot | Needs a `User.mylogin.space` claim and connection Secret, pinned Kamailio schema migration, bounded database latency and TLS. The current Home1-writable/DC1-standby topology cannot establish independent site writes during a partition. | Single-site pilot candidate; select a site-local write authority before multisite user registration |
| Backplane `dragonfly-core` | Site-local directory cache or short-lived presence after a separate database number is registered | YVR and YXL instances do not replicate one another; a cache cannot be the only cross-site dialog owner | Optional later |
| A dedicated SIP Valkey/Redis instance | Fast, independently owned transient routing state if a measured need exceeds PostgreSQL | Requires its own credentials, persistence policy, failure tests, and lifecycle; it must not share RTPEngine keys | Consider only with a concrete need |
| AVoIP's current Valkey | RTPEngine media-session recovery | Database `0` and the primary-aware proxy are owned by RTPEngine; SIP registration would mix lifecycles and failure domains | Do not reuse |
| Kamailio `dialog` DMQ alone | Limited dialog/profile synchronization | [Kamailio documents](https://kamailio.org/docs/modules/stable/modules/dialog.html) that its DMQ dialog information is insufficient to send in-dialog requests through another proxy | Do not use as the takeover design |

The [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
currently selects home1 as the writable hub and DC1 as a standby. A database
row can survive a Kamailio pod restart, but this topology must be tested for
promotion and client reconnection before the registrar is declared
cross-site writable. The [Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml)
creates independent site instances. Any new Dragonfly consumer needs a unique
number in the [allocation registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md).

## How services should authenticate

The first REGISTER client should be the existing Asterisk service, which
already has a `User.mylogin.space` claim and runtime credentials. Keep the
private registrar separate from the Flowroute listener. Each site's Asterisk
must have a site-qualified SIP realm and address of record so matching
extensions in YVR and YXL do not overwrite one another's Contacts.

| Option | Use it when | Work required |
| --- | --- | --- |
| Dedicated SIP digest credential, provisioned from the service identity | Asterisk or another SIP client supports ordinary REGISTER digest; this is the recommended first path | Generate a realm-specific verifier without putting the password in Helm output; store/rotate/revoke it through a controlled `User` or Secret lifecycle; verify REGISTER against it |
| Mutual TLS client certificate | Both SIP peers can present and validate a distinct client certificate | Define issuance, identity-to-extension mapping, revocation, and Kamailio listener policy; a server-only TLS certificate does not authenticate the client |
| LDAP lookup of a SIP HA1 attribute | Authentik actually publishes and rotates the attribute for each service | Verify the attribute and bind policy in the deployed directory; the current FreeSWITCH mapping is configuration, not proof that the value exists |
| Direct Authentik RADIUS | The provider verifies the SIP digest exchange end to end | No such path is demonstrated. [Authentik's RADIUS provider](https://docs.goauthentik.io/add-secure-apps/providers/radius/) documents PAP and EAP-TLS password authentication, so do not assume its [Kamailio RADIUS integration](https://kamailio.org/docs/modules/stable/modules/auth_radius.html) can verify a SIP digest |

The Backplane [User implementation](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/README.md)
states that its `AVoIP` claim field is currently unconsumed. The existing
Asterisk claim provides a service account, but extension/HA1 provisioning
must be built and checked explicitly. Register only over private TLS, require
authentication, limit source networks, and keep credentials out of logs.

## Where to make the extension decision

| Option | Benefit | Limit | Suggested role |
| --- | --- | --- | --- |
| Kamailio registrar plus routing at the site border | One place for REGISTER, health-aware initial selection, public topology boundary, and Record-Route | Needs shared contacts, verified service identity, per-dialog backend affinity, and clear separation of carrier and private ACLs | Preferred long-term SIP routing plane |
| Directory-driven switchboard service | Dynamic authorized identities, groups, extensions, queues and operator controls | Adds a critical policy service and lookup path; needs per-site availability, access controls and fail-closed behavior | Evaluate in [Phase 9](../TODO.md) |

For whichever option selects a backend, ACK, BYE, UPDATE, re-INVITE, INFO,
REFER, and other in-dialog requests must return to the backend that owns the
call. A [Kamailio dispatcher](https://kamailio.org/docs/modules/stable/modules/dispatcher.html)
can choose among healthy workers for an initial request, but selection alone
does not provide dialog affinity or restore a FreeSWITCH channel. Keep the
carrier-facing Contact and Record-Route on the public SIP identity; no
Kubernetes Service hostname should be required by the carrier.

## Dialog routing across sites

The current site-specific public Route set keeps an established call at its
originating site. K8GB global DNS can select a different site for a later
request; switching the public Record-Route to `sip.resolvemy.host` therefore
needs an explicit owner lookup or a provider guarantee that the dialog stays
on the original site. The two implementation options are:

1. Put an opaque, integrity-protected site/backend token in the public
   Record-Route URI. Both sites decode it and forward toward the surviving
   owner through a private path. Version the token and its signing-key
   rotation. The owner site must still be reachable.
2. Keep a small dialog-owner registry in a cross-site HA datastore. Key it by
   the full SIP dialog identity and retain owner site, backend, and expiry.
   Make creation visible before an answer can trigger an ACK, and test
   cleanup/retries. PostgreSQL is the candidate; its failover must be proven.

The route token reduces database lookups for in-dialog SIP and is the first
design to evaluate. A registry is appropriate when the route needs mutable
ownership or cannot fit safely in a token. Neither choice migrates the
answered PBX channel.

## Media availability

Keep each site's RTPEngine public media address, Service provider policy, and
UDP range under that site's chart-user values. The active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
currently supplies different DC1 and home1 media addresses and provider
settings. Increasing RTPEngine replicas requires testing that shared Valkey
state, UDP Service flow selection, the advertised address, and port ownership
let a second instance handle packets for the same call. Cross-site DNS
failover selects media for new calls; an answered peer keeps sending RTP to
the address and port negotiated in SDP until another negotiation succeeds.
No codec, fax DSP, T.38, or media-address change is part of the registrar work.

## Recommended order and proof

1. Keep site-specific Flowroute targets while validating the current TLS,
   Record-Route, ACK, and 60-second call path at both sites. Confirm the
   serving Kamailio pod can be replaced and later in-dialog requests reach
   the surviving pod and the original backend.
2. Implement a private Kamailio registrar for Asterisk using a dedicated SIP
   verifier and PostgreSQL `usrloc` database-only mode. Provision the
   [version-matched location schema](https://github.com/kamailio/kamailio/blob/6.1/utils/kamctl/postgres/usrloc-create.sql)
   through a migration, and verify the connection Secret, TLS, REGISTER
   challenge, expiry, revocation, and lookup on both replicas. No public
   Gateway route should attach to this listener.
3. Route one test extension to the registered Asterisk contact. Trace the
   complete INVITE/200/ACK/BYE dialog and fail one Kamailio replica during
   an answered call. Keep current DID and fax rules unchanged.
4. Prove PostgreSQL writable failover and decide whether a route token or
   dialog-owner registry is needed before advertising one global dialog URI
   through K8GB. Test what happens if the original site disappears after an
   answer; record signaling and media outcomes separately.
5. Add backend health selection, more named services, and optional site-local
   Dragonfly cache only after registration and dialog affinity pass. Test
   RTPEngine replica failover with packet captures before claiming media HA.

Static rendering verifies templates and TLS identities. Acceptance of each
phase requires a live SIP trace with Call-ID/tags/CSeq, ACK reaching the
selected backend, no 200 OK retransmissions or ACK Timeout, and a normal
manual BYE/200 exchange. Site and media failover each require separate live
tests; a short fax call cannot prove dialog stability.
