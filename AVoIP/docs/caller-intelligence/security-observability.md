# Security, privacy, retention and observability

Status: proposal. Telephone numbers, calling history, contact matches and reports
are sensitive data. Collect only what supports policy and explanation; the
classifier does not ingest SIP bodies, audio, voicemail recordings, DTMF/PINs,
SMS content or provider secrets. Existing restricted Homer capture remains a
separate operational system. The budget is a hard security boundary as well as
an operating target.

## Trust, credentials and abuse controls

- Store provider credentials in [Vault](https://www.vaultproject.io/) using its
  [secrets engines](https://developer.hashicorp.com/vault/docs/secrets), delivered
  through existing [External Secrets](https://external-secrets.io/) and
  [documentation](https://external-secrets.io/latest/). Commit references only.
  Providers get distinct minimum-privilege identities, rotation and revocation;
  the management API returns redacted capability summaries, never secrets or
  private account configuration. Disable a feature if permissions/rights expire.
- Declare service identity with the platform
  [User API](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/README.md).
  Separate migration, evaluator, management and worker database/API roles.
  Evaluate [PostgreSQL RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
  and pooled connection tenant-context reset; no runtime superuser/owner bypass.
- Require mTLS and site/DID authorization for SBC evaluation, Authentik OIDC and
  per-object authorization for management. Do not trust raw SIP headers or
  browser-supplied identity, role, tenant, business status or attestation.
  Enforce CSRF/session protections and safe URL encoding. Numbers in GET URLs
  require proxy/access-log redaction; prefer POST for manual input when possible.
- Only workers can reach allowlisted provider APIs over verified HTTPS. Fix hosts
  and ports in reviewed adapter configuration. Prevent caller-supplied URLs,
  redirects, DNS rebinding, loopback/link-local/private-address fetches and
  unbounded responses. STIR certificate URLs also need a reviewed fetch policy;
  arbitrary `x5u` retrieval is an SSRF risk. Follow redirects only under explicit
  validated provider/trust-domain rules. No evaluator Internet access.
- Admit lookup intents only after carrier/source and owned-DID validation; bound
  per-tenant/DID/caller intent rate, distinct-number cardinality, queue size and
  monthly allowance. A proposed admission gate is repeat observation or an
  entitled user's explicit request, configurable independently from call admission.
  An attacker varying caller ID must not schedule one paid lookup per call.
  Withheld/malformed/ambiguous numbers do not create paid jobs. Cache hits,
  denial caches, dedup and provider approval checks precede reservation.
- Use independent report rate limits, authenticated ownership, duplicate suppression,
  review and appeal. Spoofed repeated calls must not poison a global business
  reputation. Restrict broad rules and emergency exemptions to reviewed roles.
  Narrow exact allow preferences do not bypass transport/security validation.
- Bound CPU/requests/memory, use strict JSON parsing and action enums, no arbitrary
  code in rules. Parameterize SQL. Audit control-plane changes transactionally,
  minimize raw evidence, and restrict audit reads. Bypass/observe/worker kill
  switches need authenticated roles and their own audit.

## Retention and source rights

The [data model](data-model.md) and [cache TTLs](caching.md) supply starting
retention values, subject to data-owner and provider-contract review. Separate
source licensing expiry from policy expiry and business verification review.
A reviewed block can persist as a user preference even after the original
provider evidence is deleted, but cannot retain prohibited provider content or
claim a still-valid business association without independent evidence.

Explicit controls: keyed-HMAC number IDs for equality/correlation, envelope
minimization, encryption at rest/in transit, access-controlled number reveal,
no raw numbers in metric labels/log URLs, per-tenant data export/delete review,
expiry cleanup across PostgreSQL/Redis/disk replicas and deletion tombstones on
restore. Rotate HMAC/encryption keys using a versioned migration plan; hashes of
a small telephone-number space without a secret key are easy to enumerate.

Starting proposals: 30-day evaluation history, 90 days after report resolution,
365-day policy/directory audit, 400-day minimal billing metadata; provider data
uses the stricter contractual limit, including zero storage when rights are
unconfirmed. Snapshot/feed logs are minimized; retained disk spools expire
within 24 hours or the earlier source limit. Restrict backups to an approved
retention window, separate restricted source payloads from durable first-party
records, and reapply deletion/expiry on restore. A deletion request does not
remove financial metadata needed for a reviewed accounting requirement, but
such retained records must be minimized and its legal basis approved.

Do not claim Canadian/privacy-law compliance from this design alone. Before
provider activation review permitted purpose, residency, cross-border transfers,
subprocessors, terms, deletion and attribution with the responsible owner.
Places has specific [content restrictions](https://developers.google.com/maps/documentation/places/web-service/policies);
place IDs and independently gathered records remain distinct from API content.

## Existing platform integration points

The inspected [observability overview](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Observability/README.md)
describes collector, metrics, log and trace components. Reuse them where selected
and healthy; no live ingestion test was performed here.

| Signal | Existing owner and upstream |
| --- | --- |
| Metrics/discovery | [Collectors ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Observability/Collectors.yaml), [Metrics ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Observability/Metrics.yaml); [Prometheus](https://prometheus.io/), [instrumentation docs](https://prometheus.io/docs/practices/instrumentation/), [Mimir](https://grafana.com/oss/mimir/), [docs](https://grafana.com/docs/mimir/latest/) |
| Structured logs | [Logs ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Observability/Logs.yaml); [Loki](https://grafana.com/oss/loki/), [docs](https://grafana.com/docs/loki/latest/) |
| Traces | [Traces ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Observability/Traces.yaml); [Tempo](https://grafana.com/oss/tempo/), [docs](https://grafana.com/docs/tempo/latest/), [OpenTelemetry](https://opentelemetry.io/), [Go docs](https://opentelemetry.io/docs/languages/go/) |
| SIP correlation | Existing [Homer configuration and verification](../HOMER.md); [HOMER](https://www.sipcapture.org/), [source/docs](https://github.com/sipcapture/homer) |

Use local collector endpoints supplied by Backplane; do not invent stable remote
URLs or assume Prometheus Operator CRDs exist without inspection. Export metrics
on a private listener. Avoid introducing another collector or backend deployment.

## Proposed telemetry

| Metric family | Measurements and labels |
| --- | --- |
| `caller_cache_requests_total` | hit/miss/stale/error, source class, site; derive cache hit ratio |
| `caller_external_requests_total`, `caller_billable_features_total` | HTTP requests versus billed feature units, provider/feature/outcome; no numbers |
| `caller_lookup_cost_micros_total` | Estimated/reconciled separately, provider/feature/currency; do not sum unlike currencies |
| `caller_provider_duration_seconds`, `caller_provider_errors_total` | Provider latency, timeout/permission/unsupported/rate/error classes |
| `caller_evaluation_duration_seconds` | End-to-end local histogram, site/mode/degraded; compare p95/p99 targets |
| `caller_decisions_total` | Suggested and enforced separately, bounded action/reason class/site; rejection, voicemail and IVR challenge counts |
| `caller_policy_changes_total`, `caller_policy_revision_lag_seconds` | Change type and site convergence, not arbitrary policy UUID labels |
| `caller_quota_units` | Limit/consumed/reserved/uncertain/remaining for global/provider/feature; UTC period exposed without unbounded label history |
| `caller_snapshot_age_seconds`, `caller_degraded_evaluations_total` | Feed freshness, fallback reason and local-snapshot usage |
| `caller_jobs_total`, `caller_audit_dropped_events_total` | Queue depth/state/age and dropped evaluation events; management change audit cannot be silently dropped |

Labels are bounded enum/provider/site/feature dimensions; no caller number,
Call-ID, correlation UUID, user ID or arbitrary evidence/rule text in metrics.
For classification reasons export bounded symbol families, not every custom
rule UUID. Counter resets and late invoice adjustments must not fabricate a
negative cost; use adjustment events/gauges where appropriate.

Structured logs include correlation UUID, transaction HMAC, tenant-scoped opaque
ID, site/role, policy/model revision, action, matched symbol IDs, cache state,
duration and degraded reason. Authorized detailed history resolves evidence;
ordinary logs use HMAC/redacted numbers. No Authorization headers, provider
payload dumps, SIP bodies, DTMF, PINs or secret values. Redact provider URLs that
contain numbers. Audit before/after includes safe changed fields, actor,
scope and reason, with tamper-evident append access and protected retention.

Trace spans cover SBC local HTTP, evaluation/rules/cache and asynchronous
job/provider/ledger operations. Correlate jobs by links; never hold the SIP span
open until enrichment completes. Only an authenticated internal component may
supply tracing context. Keep a restricted mapping from correlation UUID to
original Call-ID for Homer, preserving inter-site provenance; general traces
use HMAC. Define authorized troubleshooting access and deletion together.

Proposed alerts: evaluation p99 >50 ms/timeout rate, snapshot lag >30 s,
invalidations >2 s online, policy unavailable/bypass, provider error/approval
failure, quota 80%/95%/100%, uncertain reservations, invoice discrepancy,
action-rate change and queue growth. Alert degradation separately from spam.
Dashboards show mode, denominators, stale status and proposed versus enforced
actions so observe-only results cannot be mistaken for blocked calls.
