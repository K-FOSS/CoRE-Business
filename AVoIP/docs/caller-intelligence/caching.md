# Redis/Dragonfly cache specification

Status: proposal. PostgreSQL owns durable records; site-local Redis/Dragonfly
owns disposable shared cache entries. Every evaluator also holds immutable
local policy/contact/directory snapshots. Neither a remote cache nor a remote
PostgreSQL primary is required on each call. Refer to the platform
[Dragonfly allocation registry](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Storage/Dragonfly/CoRE/README.md)
before implementation: reserve a new explicit unused database in the same
implementation change. Do not share existing TOPOS, Rspamd or RTPEngine state.
Logical database separation is not access isolation. Upstream references:
[Redis](https://redis.io/) and [command documentation](https://redis.io/docs/latest/commands/);
[Dragonfly](https://www.dragonflydb.io/) and [documentation](https://www.dragonflydb.io/docs/).

## Starting TTLs and hard expiry

| Intelligence | Proposed refresh TTL | Restrictions and durable lifetime |
| --- | --- | --- |
| Number formatting metadata | 90 days | Include pinned metadata version; rebuild/invalidate on version change |
| Carrier and line type | 7 days | Shorter source permission wins; reassignment may invalidate earlier |
| Business association | 7 days where permitted | Provider evidence must expire; independently reviewed records have their own review/validity dates; Places content excluded by default |
| Spam reputation | 6 hours | Decay runs independently; no stale high-impact action after evidence hard expiry |
| Manual category classification | Until changed or explicitly expired | Revision invalidation and periodic review; no provider license laundering |
| Negative lookup | 24 hours | Only authoritative no-result; scope by provider/feature/country; US Caller Name can still have a billed negative |
| Provider outage/error | 1–5 minutes with jitter | Circuit-breaker suppression, not “number has no data”; approval denial disables the feature until configuration changes |
| Explicit user allow/block rules | Until deleted or expiration | Durable rule lifetime, not unlimited decision-cache lifetime; snapshots preserve absolute expiry |
| Reusable policy decision | At most 30 seconds | Earlier policy/source expiry and invalidation always win |
| INVITE transaction result | At least the configured SIP transaction/retransmission lifetime | Isolated from number cache; bounded memory, no action reapplication; implementation derives duration from actual timers |

Separate `refresh_after`, `source_expires_at`, `policy_expires_at`,
`decision_expires_at` and `delete_after`. TTL is an upper bound and never extends
license rights. Seven days is a freshness proposal, not permission to store.
Unconfirmed retention rights disable provider-data persistence/cache. Cache
metadata can remain for audit only where it does not retain prohibited content.

## Keys and envelopes

Proposed key families: `ci:v1:{tenant}:fact:{feature}:{source}:{subject_hmac}`,
`ci:v1:{tenant}:decision:{scope}:{policy_revision}:{context_hmac}`,
`ci:v1:{tenant}:flight:{provider}:{feature}:{subject_hmac}` and
`ci:v1:{tenant}:transaction:{transaction_hmac}`. Include entitlement scope,
normalization/metadata revision, provider capability revision, model revision,
authentication-state fingerprint and relevant DID/user scope in context hashes.
Use server-derived tenant IDs and a keyed HMAC, not unkeyed phone hashes or raw
telephone numbers. All list/query APIs enforce tenant scope before cache reads.
Shared source facts may be reused across tenants only with explicit license and
privacy approval; private contact, policy and report data never cross tenants.

Envelope contains schema/version, provenance and source record references,
retrieved/observed times, refresh/hard-expiry/delete times, license revision,
confidence, state (`positive`, `negative`, `error`), payload and checksum.
Authentication outcomes are call-specific and cannot be cached by number alone.
Reject incompatible versions, invalid timestamps and oversized payloads.

## Positive, negative and stale reads

A positive hit is usable only within rights and hard expiry. A negative is
specific to one feature/provider/query and never asserts that no business or
reputation exists elsewhere. Errors have their own suppression keys. A cache
miss schedules best-effort enrichment and returns local evidence immediately.

Stale-while-revalidate is permitted only between refresh and hard expiry, and
only for approved source classes. Starting proposal: at most 24 hours beyond
refresh for licensed carrier/directory facts and 1 hour for reputation, bounded
by contractual retention. Stale information is labeled. Do not make a new hard
reject solely from stale risk or an expired business association. Exact local
policy remains independently enforceable until its absolute expiry.
Places content receives no generic stale window.

## Distributed single-flight

Use `SET NX PX` with a random owner token and compare-and-delete Lua unlock;
leases bound abandoned cache locks and use jittered expiry. A non-owner returns
local/stale data without waiting for the external lookup. Owner renewal must
check its token. Test the exact commands against pinned Dragonfly and Redis
versions, not just an in-memory fake. Avoid `KEYS`, broad `FLUSHDB`, or scripts
whose atomicity depends on unsupported cluster behavior.

A Redis lock is only a performance hint. A durable unique job and PostgreSQL
reservation/dispatch fencing prevent duplicate paid requests if a lock expires,
Redis fails over, or multiple sites enqueue the same number. Do not replay an
uncertain dispatched job. Only one budget authority may dispatch globally;
site-local Redis instances cannot independently enforce the 100-unit cap.
Dedup spans all three SBC replicas and all service replicas.

## Invalidation and convergence

A policy edit transaction writes the rule, monotonically increasing scoped
revision, audit event and outbox invalidation together. Site consumers apply
revision events idempotently, replace immutable snapshots atomically, and
acknowledge active revision. Poll revisions at a proposed 5-second interval as
backup to delivery. Never rely only on Redis Pub/Sub, which can lose messages.
Invalidate business memberships, country metadata, provider rights and report
withdrawals using the same scheme. Absolute expiry is checked on every evaluation.

Target online invalidation <=2 seconds. API mutation responses distinguish
`pending` from `active`; UI must not claim immediate fleet enforcement before
all selected sites acknowledge. For urgent false-positive corrections, mark
that scope's cached decisions unusable immediately; sites missing the required
revision bypass optional enforcement when notified. A disconnected site cannot
promise immediate invalidation; it reports stale status and uses the documented
snapshot-age limit. Rejoining sites catch up revisions before enforcement.

## Sites, expiry and garbage collection

YVR and YXL each use local caches and evaluator snapshots. Distribute permitted
facts and policy through an authenticated versioned feed, not shared cross-site
per-call cache reads. Preserve original source timestamps on replication;
replication never refreshes TTL. Cross-site decision-cache replication is not
required. Reject stale writer epochs during failover.

Redis TTL removes hot entries; PostgreSQL cleanup independently deletes expired
source payloads, jobs and history according to retention. Periodically sweep
stranded indexes and expired negative/error records with bounded scans. Purge
provider-derived copies from local disk snapshots, queues, logs and replicas
when rights expire. Encryption does not exempt backups from retention policy;
limit backup lifetime and reapply deletion tombstones on restore. See
[privacy and retention](security-observability.md).
