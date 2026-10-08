# Internal Kamailio registrar: integration contract

## Current state

Backplane references below were inspected at commit
`df212a6f87c83b330380de2073b3ce3b2c287347` on 2026-10-07. Verify the
active cluster state before enabling an instance.

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects only the `carrier` Kamailio instance at DC1, Home1, and the legacy
DC1 cluster. Its public listener rejects `REGISTER` with 403. The chart's
`private-sbc` role now contains a disabled-by-default registrar pilot with
mutual-TLS ingress, Digest checks, exact allowed AoRs, database-only contact
storage and a dedicated Cilium policy. No internal registrar is deployed.

The [Backplane `User` XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
has an `AVoIP` field, but its
[Composition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserComposition.yaml)
does not issue a SIP verifier or publish extension assignments. The
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
currently makes Home1 writable and DC1 a standby; shared contact writes
cannot be assumed independently available at both sites. The
[storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
does not supply a Kamailio registration database.

## Implemented opt-in pilot and safety boundary

Set `registrar.enabled: true` on one named `private-sbc` instance only after
providing `realm`, `accessPeerName`, `allowedUsers`, and the
`registrar.database` host, username and Secret name. The mTLS access peer must
also appear in `privateRouting.peers` with its exact source CIDR, certificate
DNS SAN and pod controller label. Keep the carrier entry in the complete
`kamailio.instances[]` list. Home1 is the initial writable PostgreSQL site;
the [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
shows DC1 as a standby, so do not enable a DC1 registrar against that writer.

When enabled, the chart creates a per-instance private Deployment, TLS
Service/certificate, a `User.mylogin.space` PostgreSQL service claim, a
stable connection Secret reference, a BJW-S migration Job and two Cilium
policies. The Job applies the pinned Kamailio 6.1.4 `standard`, `auth_db` and
`usrloc` PostgreSQL schemas under an advisory transaction lock; it checks
schema versions and fails instead of silently replacing unknown tables.
Argo CD runs the claim at wave -2, migration at wave 0 and registrar Deployment
at wave 1. Resource-selective sync skips hooks: use a scoped full application
sync when first provisioning the schema. The database and claim can outlive
the registrar workload; deleting an instance is not credential revocation.

The pilot requires a verified TLS peer and exact source CIDR before any
REGISTER or initial INVITE. `auth_db` verifies a precomputed realm-specific
HA1 in `subscriber`; the client authenticates REGISTER and initial INVITE,
and the authenticated username must match the To/From AoR. Only explicitly
listed pilot users may register or call another listed registered AoR.
`registrar` limits contacts and expiry; `usrloc` mode 3 reads/writes the
site-local PostgreSQL `location` table. No browser ingress, public route,
Flowroute ACL addition, PSTN entitlement or second media anchor is created.
The Kamailio connector and migration client require hostname-verified TLS to
PostgreSQL; confirm the site-local `psql-int` certificate chain and hostname
are trusted by the pinned container before attempting to enable the pilot.
Raw SIP logging is disabled and rejected for an enabled registrar so Digest
responses are not written to pod logs. Module behavior follows the pinned
[Kamailio `auth_db`](https://www.kamailio.org/docs/modules/6.1.x/modules/auth_db.html),
[`registrar`](https://www.kamailio.org/docs/modules/6.1.x/modules/registrar.html),
and [`usrloc`](https://www.kamailio.org/docs/modules/6.1.x/modules/usrloc.html)
documentation.

This is **not yet an operational user registrar**. There is no SIP HA1
credential broker, immutable-user mapping, credential expiry or automated
revocation/contact invalidation. The Backplane `User` claim provisions only
the database identity, not SIP subscribers. WSS Path/connection ownership,
keepalives and reconnection are untested, so the pilot must remain off in
production until these gaps are closed. Do not insert primary LDAP passwords
into `subscriber`. Rollback is to disable the named instance in the owning
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
allow contacts to expire, and explicitly audit the retained database, Secret
and service identity before any deletion. Carrier and fax resources remain
separate.

CI-safe checks are `helm lint AVoIP`,
`./AVoIP/tests/kamailio-instances.sh`,
`./AVoIP/tests/sip-security-render.sh` and
`./AVoIP/tests/sip-registrar-render.sh`. On 2026-10-07 the opt-in private
configuration also passed `kamailio -c` in the pinned 6.1.4 image (only the
expected networkless Service DNS warning). The rendered Cilium policies
passed a server-side dry run against the DC1 CRD. The generated schema Job
was executed twice against an isolated PostgreSQL 17 container: the first
run created `version`, `subscriber`, `location`, and `location_attrs`, and the
second committed without recreating them. The disposable container was
stopped. These checks do not prove live Home1 database provisioning, SIP
Digest acceptance, contact routing, reconnection or call audio.

## Required identity and data contract

The preferred GitOps API is a small set of namespaced claims, following the
existing `User.mylogin.space` pattern:

| Claim | Owns | References |
| --- | --- | --- |
| Existing `User` | Identity, active/suspended state, groups and service-account status | None; its immutable identity is the principal key. |
| Proposed `AVoIPLine` | DID or trunk-facing service number, site, routing destination and lifecycle | The owning service `User` and its destination policy. |
| Proposed `AVoIPExtension` | Unique site-qualified extension, display name, owner and call permissions | A human or service `User`; optionally an `AVoIPLine`. |
| Proposed `AVoIPDevice` | One endpoint's SIP AoR, credential reference, registration policy and revocation | One `User` and one or more authorized extensions. |

The `User` claim's existing `spec.AVoIP` field is currently schema-only for
voicemail and is not consumed by its Composition. Extend it with an AVoIP
entitlement or stable identity reference, then add the number/extension/device
claims at the Backplane API owner. A single large `User.spec.AVoIP` list is
possible for a one-device pilot but makes shared lines, extension reassignment,
and per-device credential rotation hard to reconcile safely. PostgreSQL should
be a reconciled read model for Kamailio, with claim status reporting which
projection and credential version are ready.

Use an immutable subject or service identity as the account key.
Keep the SIP address of record, site-qualified realm, extension, display name,
device ID, and call permissions as separate fields. An extension transfer must
revoke the previous owner's SIP credentials and contacts before assigning the
number to a new identity. Suspension must deny new REGISTER and authenticated
INVITE requests and remove or expire existing contacts.

The first supported authentication design should issue a separate random SIP
secret per device or service after authorization checks. The issuer must store
a realm-specific HA1 verifier, return the secret only to the authorized
device, and support rotation and revocation. Kamailio 6.1's
[`auth_db`](https://www.kamailio.org/docs/modules/6.1.x/modules/auth_db.html)
can verify a precomputed HA1 in PostgreSQL; the registrar can store contacts
with [`registrar`](https://www.kamailio.org/docs/modules/6.1.x/modules/registrar.html)
and [`usrloc`](https://www.kamailio.org/docs/modules/6.1.x/modules/usrloc.html).
Never put a plaintext SIP password in Helm values, SIP logs, or the extension
directory.

Store extension ownership and permissions in a versioned, access-controlled
directory view, initially PostgreSQL. The credential verifier and extension
view must use the same immutable identity and site-qualified realm. A
successful Digest check alone does not grant outbound calling: the request
must also match the active identity, extension, destination permission, and
site policy. Missing directory data or a failed lookup must deny the request.
The current `User` Composition does not implement this projection, so its
schema must be extended or a controlled reconciler added before live use.

## Build and rollout order

1. Confirm a pilot identity, its immutable ID, the site-qualified SIP
   realm/AoR, allowed source network, extension and outbound permission.
   Confirm whether devices can use separate SIP credentials. Do not enable
   the registrar until this contract is fixed.
2. Implement the credential issuer and extension projection with a revocation
   path. The dedicated `User.mylogin.space` database claim and pinned schema
   migration now render but have not been reconciled. Check the database's
   actual write authority at the pilot site before enabling the instance.
3. Add a named internal registrar role with only private TLS ingress, a
   distinct Service and certificate, narrowly scoped NetworkPolicy and source
   authorization, `auth_db`/`registrar`/`usrloc` configuration, and no public
   Gateway route. Keep the carrier role and its ACL unchanged. Start with one
   pilot site and one test AoR. Require authenticated REGISTER and initial
   INVITE, separate extension permission lookup, and fail-closed database
   errors. Decide connection ownership and contact flow handling before
   increasing replicas.
4. In an isolated test deployment, check unauthenticated, invalid, revoked,
   and wrong-realm REGISTER and INVITE responses; none may create a contact or
   a backend or carrier INVITE. Check valid registration, refresh, expiry,
   deregistration, multiple contacts, and one permitted internal call. Verify
   `ACK` and `BYE` follow the selected backend and source ACLs still reject
   carrier REGISTER. Correlate the same Call-ID across both Kamailio legs and
   FreeSWITCH.
5. Publish a reviewed GitOps commit, then reconcile only the pilot AVoIP
   application. Confirm the `User` claim, composite, database grants, Secret,
   schema version, registrar readiness, and SIP behavior. Only then add more
   identities or replicas. Roll back by stopping new registration and routing,
   letting existing contacts expire or deregistering them, and reverting the
   owning ApplicationSet instance entry and chart commit. Retained database
   and Secret data require explicit lifecycle review; resource deletion alone
   is not a credential revocation check.

## Evidence still required

- The approved credential-issuance and verifier path for the pilot, including
  its realm, rotation, revocation and audit behavior.
- The approved pilot AoR, site, extension, private ingress network, and
  outbound permissions, plus a writable PostgreSQL target for that site.

These are implementation prerequisites, not evidence that live SIP
registration has been enabled or validated.
