# PostgreSQL data model and migration proposal

**Design only: no migration files are executable or applied by this task.**
Proposed database identity `caller-intelligence` must be provisioned through a
namespaced platform `User` claim, not an application-generated password or
reuse of the SMS/voicemail database. Review the current
[PostgreSQL owner](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml),
[User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
and [Composition](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserComposition.yaml)
again before implementation. No change to registrar, voicemail or SMS schemas. Use supported
[PostgreSQL](https://www.postgresql.org/) features from its
[versioned documentation](https://www.postgresql.org/docs/) for the installed release.

## Common columns and ownership

Use application-generated UUIDs, `timestamptz` in UTC, integer version counters,
and `numeric`/integer-micros monetary values; never floating-point money.
Tenant records have `id`, `tenant_id`, `created_at`, `updated_at`,
`created_by`/`updated_by` principal reference, `version`, optional `valid_from`,
`expires_at`, `deleted_at`. Reviewed records additionally have `review_status`,
`reviewed_by`, `reviewed_at`, `review_due_at` and evidence references. Mutations
append an immutable version/audit record. Private Authentik ownership stores
`issuer` plus immutable OIDC `sub`; usernames/display names are not stable keys.

Tenant UUIDs are server mapped from the platform tenant identifier. Global
policies and explicitly shared directory records use a dedicated platform
scope with admin-only writes; do not use null tenant IDs as an accidental RLS
bypass. Cross-tenant sharing requires explicit publication and materialized
read grants. DID/extension ownership assignments have validity windows so
reassignment cannot transfer prior private policy/history permissions.

Store normalized numbers encrypted where practical and a tenant-keyed HMAC
for equality indexes; encryption/key rotation must be designed before writes.
Prefix/range matching needs controlled decrypted compiled snapshots or separate
access-controlled canonical selector storage; HMAC indexes cannot do prefix
search. Do not pretend encryption enables arbitrary SQL range queries.

## Candidate entities

All names below are proposed tables in an application-owned schema.

| Entity | Principal fields and constraints |
| --- | --- |
| `caller_numbers` | UUID; tenant; encrypted E.164 and HMAC; normalization/metadata revision; assigned region nullable; region resolution status; numbering type; first/last seen; last independently verified time. Unique `(tenant_id, number_hmac)`; valid number syntax bounded to E.164. Missing/withheld call identities are evaluation states, not fake number rows |
| `caller_businesses` | UUID; tenant/publication scope; parent branch/entity UUID; independently sourced legal/display name, aliases, category references; review/verification methods, confidence, provenance and validity. Reviewed hierarchy must be acyclic; parent reference constrained to authorized same/shared scope |
| `caller_business_numbers` | UUID; tenant; business UUID; number UUID; association status/confidence; `valid_from`/`expires_at`; branch role; independent evidence refs and review history. Prevent duplicate active identical association; retain possible conflicting candidates visibly; ambiguous active owners cannot hard-match |
| `caller_lookup_results` | UUID; tenant entitlement; number; provider/feature/API/capability/license revisions; result status; permitted minimal JSONB payload or no payload; provider reference; retrieved/observed/refresh/hard-expiry/delete times; cache permission; attribution; related usage attempt. Provider data remains separate from reviewed records |
| `caller_reputation` | Tenant; number; model revision/window; raw weighted score, calibrated risk nullable, confidence, distinct-call/report counters; last decay; source refs; expiry. Unique `(tenant_id, number_id, model_revision, window_start)`; never a cross-tenant default aggregate |
| `caller_reports` | UUID; tenant; number/business optional; reporting issuer/sub; optional evaluation ID; report category, bounded comment, evidence, status `pending/reviewed/disputed/withdrawn`; timestamps. Unique actor/evaluation/category where an evaluation exists; rate-limit reports without an evaluation |
| `caller_rules` | UUID; tenant/platform scope; selector type and validated typed selector; action; priority; mandatory/delegable status; trust/confidence requirements; active/draft state; start/expiry; reason; model/config revision. No arbitrary SQL/regex/code or redirect URI in selector/action |
| `caller_policy_assignments` | UUID; tenant; rule/policy UUID; scope enum `platform/tenant/did/extension/user`; authorized DID or extension reference; issuer/sub for user scope; delegation; version/validity. Require exactly the fields for selected scope; only platform admins assign global/mandatory rules |
| `caller_evaluation_history` | Evaluation UUID/correlation; tenant/site; transaction HMAC; called-DID and caller refs/redacted representation; selected/claimed identity provenance; auth outcome; business association/confidence; matched/shadowed symbols/evidence summaries; raw/risk score; policy/model revisions; proposed/enforced actions, fallback reason; cache/freshness; paid-used and enrichment-scheduled flags; duration/times/delete-after. No SIP payload, PIN or media |
| `caller_provider_usage` | Immutable event UUID; job/attempt/reservation IDs; provider/feature/tenant/UTC period; state transition; units; currency/estimated micros/ceiling; reconciled invoice micros/reference nullable; price revision; dispatched/completed times; uncertainty/failure classification; override reference. One charge unit per separately billed feature; do not overwrite event history |
| `caller_provider_configuration` | Provider/capability revision; feature/country enablement, approval evidence/expiry; price ceiling/source/date/currency; quota and monetary cap refs; priorities, timeout, retention/cache restrictions, health state; Vault/Secret **reference only**, never key/token/private provider settings |

Supporting tables are required for a coherent implementation, not optional
in-memory substitutes:

| Supporting entity | Purpose |
| --- | --- |
| `caller_principals`, `caller_scopes` | Tenant, issuer/sub, DID/extension ownership and delegation validity; authorization snapshot generation |
| `caller_categories`, `caller_business_categories` | Configurable taxonomy, many-to-many assignment, confidence, evidence and review |
| `caller_contacts` | Optional authorized local directory snapshot with source/version/owner; separate from public business identity |
| `caller_evidence` | Source URI/reference, evidence kind, independently collected versus provider-derived, license, confidence, verification, hard expiry; sensitive content minimized |
| `caller_policy_revisions`, `caller_record_versions`, `caller_audit_events`, `caller_outbox` | Immutable history, optimistic locking, durable invalidation and active-site acknowledgements; audit before/after must exclude secret/provider-restricted content |
| `caller_lookup_jobs` | Canonical dedup key, requested features, owner lease/epoch, dispatch token, queued/dispatched/uncertain/terminal state, next attempt and expiry; persisted outbox supports exactly-once dispatch ownership, not guaranteed exactly-once external delivery |
| `caller_budget_periods`, `caller_budget_counters`, `caller_usage_reservations` | Locked global/provider/feature/tenant/currency counters and feature reservation state; one UTC period dimension; `CHECK` nonnegative units/money, mutually exclusive accounting states |
| `caller_budget_overrides`, `caller_invoice_reconciliations` | Approved bounded extra allowance and provider invoice comparison without rewriting usage events |
| `caller_site_snapshots`, `caller_deletion_tombstones` | Version/checksum/site epoch, ack/staleness and restore-safe privacy deletions |

Composite foreign keys include tenant/scope, not only UUID. Prevent cross-tenant
business associations, rule assignments and report references even if a UUID is
known. Use database constraints plus service authorization. Row-level security
is defense in depth: runtime role is neither owner nor `BYPASSRLS`; use `FORCE
ROW LEVEL SECURITY`, per-transaction tenant context with pool reset, and a
separate migration/admin role. A platform publishing role is distinct from a
normal tenant API role. Validate those semantics on the actual PostgreSQL version.

## Index plan and retention

- B-tree unique tenant/number-HMAC, issuer/sub and versioned dedup keys; B-tree
  `(tenant_id, scope_type, scope_id, state)` for policy compilation and
  `(tenant_id, business_id, review_status)` for associations. Active expiry
  indexes use static conditions (`deleted_at IS NULL`), not volatile `now()`
  predicates; evaluate expiry at read time.
- B-tree `(tenant_id, provider, feature, number_id, retrieved_at DESC)` and
  `delete_after` for source records. Index entitlement/license revisions for purge.
- Monthly history partitions with `(tenant_id, created_at DESC, id)` cursor
  index and BRIN time index where useful; one retention cleanup task drops/purges
  old partitions. Avoid indexing every JSONB property; explicit searchable columns
  first. Reviewed aliases can use normalized text indexes, not fuzzy automatic
  identity enforcement. Bounded selector sets compile into in-process prefix/
  range structures; no per-call full table scans.
- Unique job dedup constraint over provider/feature/entitlement/number HMAC/
  freshness generation, plus immutable dispatch-attempt IDs. Ledger counter
  primary keys lock in fixed order. Unique invoice line references prevent
  double reconciliation. Store multi-feature reservations as child rows.
- Starting retention proposals: evaluation detail 30 days; reports 90 days after
  resolution; policy/directory audit 365 days; minimal usage/invoice metadata
  400 days; successfully completed job metadata 30 days, with uncertainty held
  until reconciled; expired transient error data <=5 minutes. Provider payloads
  obey the stricter source limit. Manual active rules/categories remain until
  deletion/expiry with review reminders. Legal/accounting requirements are
  implementation approval questions, not claims of compliance.

## Proposed migration sequence

| Migration | Planned change and validation |
| --- | --- |
| `001_identity_policy` | Tenant/principal/scope, number, rule, assignment, revision and audit tables; tenant isolation, expiry and ownership reassignment fixtures |
| `002_snapshot_outbox` | Transactional outbox, snapshot manifests and site acks; crash/replay and monotonic revision fixtures |
| `003_provider_accounting` | Capability configuration, jobs, counters, reservations, usage events, overrides/invoices; concurrent cap and uncertain-dispatch tests before any real provider |
| `004_business_directory` | Business/branch/category/evidence/association tables; independent versus provider provenance, review, ambiguity and reassignment tests |
| `005_reputation_history` | Report/reputation/history partitions, cleanup and tombstones; dedup, poisoning, decay and privacy restore tests |

Use expand/contract migrations, explicit checksums, advisory migration locking
and a migration role; no DDL in per-call code. Test up/down intent against an
empty database and upgrade fixtures. Reversing a release does not mean dropping
ledger or policy tables. Retain compatible columns during rollback; destructive
cleanup requires separate data-owner authorization. A new implementation must
review grants, connection-secret keys, provider conditions, backup/restore and
orphan policies before declaring readiness.
