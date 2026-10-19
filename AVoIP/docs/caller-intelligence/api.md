# Internal API and OpenAPI proposal

[OpenAPI 3.1 contract](openapi.yaml), version 0.1.0, is a design artifact with
no deployed URL. It uses [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0)
semantics, closed objects, bounded strings/arrays, typed selectors and explicit
nullable values. No wildcard provider-response blob or arbitrary routing URI
is accepted. JSON bodies are capped at a proposed 16 KiB on evaluation and
64 KiB on management endpoints. Unknown fields and unsupported revisions fail
validation. Deadlines are in the [architecture contract](architecture.md).

## Authentication and authorization

The internal evaluator is a private listener requiring mTLS: validate server
identity and a dedicated SBC client certificate, then map it to allowed site,
tenant and DID inventory. Use short-lived Vault-issued identities through the
platform's certificate machinery. A source CIDR or spoofable HTTP/SIP header
alone is insufficient. If the pinned HTTP module cannot load credentials safely,
a same-pod local proxy may originate mTLS; network policy must prevent direct
unauthenticated service access. Confirm this before implementation.

Management uses an Authentik access token with verified issuer, audience,
signature, expiry and application permission. A BFF may hold it behind a secure
browser session. It is distinct from the SBC service principal. User tokens
cannot call the production evaluator or assert a carrier verification result.
A separate simulation endpoint ignores claimed carrier authority and permits
owned scopes only. The certificate principal and server-owned DID inventory
select tenant/scope; body `scope_hint` cannot elevate access.

## Endpoint behavior

| Method/path | Semantics |
| --- | --- |
| `POST /v1/caller/evaluate` | Bounded local evaluation, authenticated SBC only; 200 includes action and degrade state, no paid synchronous requests |
| `GET /v1/caller/lookup/{number}` | Cached/local authorized view; GET never spends credits. Encode the leading plus; redact URL at proxies/access logs |
| `POST /v1/caller/lookup` | Queue explicitly requested permitted features; 202 with job ID/state, 429 quota/rate denial; polling cached GET reports latest job status |
| `GET /v1/caller/businesses` | Tenant-authorized search with reviewed/candidate status, opaque cursor and limit <=100 |
| `POST /v1/caller/businesses` | Create candidate records; no implicit review, verification or active number association |
| `GET /v1/caller/rules` | Own/delegated scopes only; cannot enumerate other tenants' rules |
| `POST /v1/caller/rules` | Create draft/activate authorized selector/action; returns policy revision and pending sites |
| `PATCH /v1/caller/rules/{id}` | `If-Match` plus idempotency key; revalidate breadth, expiry and ownership |
| `DELETE /v1/caller/rules/{id}` | Tombstone and publish invalidation; 202 with pending/active convergence, rather than claiming immediate site application |
| `GET /v1/caller/history` | Redacted own call evidence, scoped time bounds and cursor; shared-DID history needs explicit access |
| `GET /v1/caller/providers` | Redacted capability/approval/health summary; no private provider configuration or credentials |
| `GET /v1/caller/budget` | UTC period, scoped consumed/reserved/uncertain/remaining, costs and override visibility |
| `POST /v1/caller/simulate` | Additional proposed endpoint: evaluate owned scenarios without SIP effects, enrichment, quota or reporting side effects |
| `POST /v1/caller/reports` | Additional proposed endpoint: bounded pending report, deduplication and review, no immediate global penalty |

Business review/update, association dispute, report withdrawal, policy-assignment
management, audit search, provider administration and manual budget-override
approval are required follow-up API additions. They are explicitly not silently
provided by the base endpoints. Design their contracts before building those
management workflows. Creation endpoints cannot grant reviewer/admin status.
Readiness/metrics and authenticated snapshot-feed endpoints are separate
operational contracts to finalize before deployment.

## Request, consistency and error semantics

Evaluation requires correlation UUID, stable SBC transaction key, authorized
site and DID, initial-inbound kind, bounded selected caller identity and trusted
authentication facts. `transaction_key` is an HMAC over peer/site, Call-ID,
CSeq/method, From tag and top Via branch, with a shared SBC key and consistent
canonicalization. Do not use caller number or Call-ID alone. Tenant scope,
authentication evidence and origin are server-validated against SBC permission.
Reject a key reused with a different request body. A retransmission returns the
original transaction result/correlation, not another enrichment attempt.

Management mutations require `Idempotency-Key`, bound to principal, tenant,
method, path and body digest, retained at least 24 hours. A different body under
the same key returns 409. Rule PATCH/DELETE require opaque version `If-Match`;
412 is stale, 428 missing. List/create/update rule responses expose an opaque `etag` as well as a version;
clients pass that returned validator unchanged in `If-Match`. Activations return a monotonic
policy revision and per-site pending state; the UI polls rule list until active.

Errors have stable code, safe message and correlation ID: 400 malformed input,
401 invalid credentials, 403 unauthorized scope, 404 missing or invisible object
(use indistinguishable object errors), 409 conflict, 422 invalid selector/feature,
429 rate or quota denial, 503 unavailable control plane. Responses may include
bounded `Retry-After` for an actual retryable condition. Provider outage is a
lookup job state, not a request to tear down a call. Unknown/invalid API responses
cause the SBC's normal-routing fallback. Never accept a decision from a SIP
header supplied by an endpoint or carrier.

## Illustrative result

This abbreviated JSON uses a reserved fictitious number. The normative schema
requires the additional freshness/authentication fields in `openapi.yaml`.

```json
{
  "normalized_caller": {"number": "+14165550100", "status": "valid"},
  "identity": {"status": "reviewed", "confidence": 0.8},
  "reputation": {"risk": null, "raw_score": 0, "confidence": 0},
  "matched_rules": [{"symbol": "BUSINESS_BLOCKED", "dimension": "policy"}],
  "decision": {
    "action": "voicemail",
    "explanation": "Reviewed branch matched an active DID preference; no fraud finding."
  },
  "cache_status": "hit",
  "paid_lookup_used": true,
  "enrichment_scheduled": false
}
```

`paid_lookup_used` means paid-derived intelligence contributed, possibly from a
previous cached lookup. It does not mean this evaluation spent money. Record new
provider feature charges in the usage ledger; `enrichment_scheduled` is a separate
best-effort fact. Complete validated synthetic request/response examples are also embedded in
`openapi.yaml`. The full result includes correlation ID, called DID, resolved
scopes, business UUID/evidence, identity confidence, authentication/attestation,
raw and calibrated risk, matched/shadowed rules, enforced/suggested action,
policy/model revisions, decision expiry, freshness and evaluation duration.
All confidence examples are illustrative rather than calibrated production values.
