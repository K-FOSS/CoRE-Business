# ADR 001: Standalone Go Caller Intelligence service

Date: 2026-10-18. Status: proposed for subsequent implementation.

## Context

CoRE-Business already owns the [AVoIP rendering unit](../../README.md).
Kamailio, FreeSWITCH, Asterisk, RTPEngine, PostgreSQL, Dragonfly and Homer have
existing responsibilities and operational constraints. Three carrier Kamailio
replicas need consistent inbound policy without synchronous paid dependencies.
The application needs tenant/DID/user policy, reviewed businesses, explainable
classification, provider licenses and a hard global lookup budget.

## Decision

Keep Kamailio as SIP trust and enforcement boundary. Build CoRE Caller
Intelligence as a standalone Go application with evaluator, management and
asynchronous worker roles. Keep documentation in this repository while it owns
the deployed stack. Revisit extraction only through a separate repository and
Backplane ownership migration. Expose an authenticated, versioned internal
contract and private Authentik management UI; begin observe-only.

## Alternatives and consequences

| Option | Benefit | Cost and disposition |
| --- | --- | --- |
| Standalone Go application | Explicit API, bounded contexts, tenant model, licensing and quota transactions; follows existing Go/pgx precedent | New application, snapshots, adapters and lifecycle to maintain; selected |
| Embed all logic in Kamailio | Fast native routing, fewer processes | Business review, OIDC UI, licensing and multi-feature accounting would be routing-script application logic; module/image coupling increases regression risk |
| Adapt Rspamd | Mature weighted rules, composites and reputation patterns | Email task model/actions are inappropriate for SIP and require a translation application anyway; borrow concepts only |
| Add OpenSIPS fraud_detection | Existing behavior and toll-fraud windows | New SIP hop, transaction/dialog operational risk, no business identity resolver; unnecessary for the stated objective |
| Call a paid provider directly from Kamailio | Small prototype | Couples call setup to billing/network delays, weak multi-replica accounting, no reviewed identity/policy workflow; rejected |

Tradeoff: fail-open optional classification preserves admission during service
failure and can admit unwanted calls. Paid scheduling fails closed on quota or
accounting uncertainty. Site snapshots add a bounded stale-policy window.
Business/attestation confidence and spam risk remain independent so a legitimate
financial organization is not labeled fraudulent merely for its category.

## Evidence and review gates

[Research](research.md) identifies reusable upstream features and build limits.
[Testing and rollout](testing-rollout.md) supplies acceptance gates. Before
implementation approve privacy/retention, ownership mappings, monetary ceilings,
module availability and multi-site snapshot transport. Before enforcement prove
transaction cancellation, false-positive correction, fax/voicemail preservation,
site partition behavior and bypass rollback. No deployment accompanies this ADR.
