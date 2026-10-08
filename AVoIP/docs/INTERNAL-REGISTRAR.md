# Internal Kamailio registrar: integration contract

## Current state

Backplane references below were inspected at checkout commit `d5587d0` on
2026-10-07. Refresh that repository and verify the active cluster state before
enabling an instance; network access did not permit a fresh fetch for this
review.

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects only the `carrier` Kamailio instance at DC1, Home1, and the legacy
DC1 cluster. Its public listener rejects `REGISTER` with 403. The chart's
`private-sbc` role also uses the carrier routing script and does not implement
registration or subscriber authentication. No internal registrar is enabled.

The [Backplane `User` XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
has an `AVoIP` field, but its
[Composition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserComposition.yaml)
does not issue a SIP verifier or publish extension assignments. The
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
currently makes Home1 writable and DC1 a standby; shared contact writes
cannot be assumed independently available at both sites. The
[storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
does not supply a Kamailio registration database.

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
   path. Provision a dedicated `User.mylogin.space` service claim and stable
   connection Secret for its PostgreSQL database. Use the pinned Kamailio
   6.1 schema migration for `subscriber` and `location`, not a pod startup
   script or a chart-private database. Check the database's actual write
   authority at each pilot site.
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
