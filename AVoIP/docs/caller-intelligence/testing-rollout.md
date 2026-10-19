# Testing, implementation roadmap and rollout

Status: proposed acceptance plan, not a report of executed subsystem tests.
This documentation task validates documentation/contract consistency only.
No SIP test calls, paid requests, migrations, live route changes or deployments
are needed or authorized here. Existing unrelated worktree changes are preserved.

## Staged roadmap and exit gates

| Phase | Engineering work | Exit evidence |
| --- | --- | --- |
| 1 — Documentation and architecture | Repository discovery, research, ADR, API/data/cache contracts, costing, test design | This package reviewed; unresolved runtime/provider assumptions tracked; no claim of deployed subsystem |
| 2 — Local caller protection | Go service skeleton, PostgreSQL identity/policy migrations, scoped API, immutable site snapshots, Dragonfly allocation/cache, exact blocking/country resolution, Authentik authorization | Mock/local integration tests prove scope/expiry/invalidation/failure behavior; separate private UI login and SBC mTLS; no SIP enforcement yet |
| 3 — Lookup providers | Twilio/Sinch adapters, explicit features and contracts, Canadian gates, license-aware TTLs, durable budget and dedup | 100-feature cap holds under concurrency/crash/partition; no credentials/forbidden content; fixtures default, paid smoke test only when explicitly approved |
| 4 — Business intelligence | Reviewed businesses/branches, aliases/categories, independent records versus provider candidates, review/dispute and directory adapters | Uncertain matches cannot hard-block; branch/entity and reassignment tests; Places remains disabled until rights/attribution/cost approved |
| 5 — Reputation engine | Weighted symbols, evidence caps/decay, reports, unique-call windows, simulation and explanations | Reproducible scores with config revisions, report-poisoning and false-positive correction tests; thresholds reviewed/calibrated, no automatic production scores |
| 6 — Kamailio integration | Carrier-image module verification, async local HTTP, transaction/cancel/correlation handling, observe-only then controlled enforcement | Three-replica SIP tests and current IVR/fax/voicemail/registration/teardown/media regressions pass; one-DID canary and rollback evidence |
| 7 — Multi-site reliability | Site-local caches/snapshots, policy feed, failure fencing, quota authority failover, performance validation | YVR/YXL partition/rejoin and freshness gates pass; no remote per-call dependency, no double spend or claim of active-dialog migration |

Mock multi-site failure behavior is tested before phase 6; phase 7 proves it
under the selected deployed topology. A phase number is not permission to enable
paid traffic or hard enforcement before its own prerequisite gates are complete.

## Required fixtures and harnesses

Use deterministic local fixtures for Twilio v2 per-feature success/null/error,
Canadian `60601`, US CNAM billable-negative, Sinch v2 nested feature errors,
rate limits, timeouts, late responses and malformed/oversized JSON. Mock provider
servers record invocation count and requested features; no real credentials or
public API fallback in tests. Simulate billing independently from HTTP status.
Use a controlled clock for UTC month boundaries, expiry/decay and delayed invoices.

SIP harness uses an isolated Kamailio 6.1.4 image with the selected module build,
three replicas, fake carrier and internal B2BUA/registered endpoints, synthetic
reserved test numbers, local Redis/Dragonfly and PostgreSQL fixtures. Replay
synthetic SIP scenarios, not production captures containing private numbers.
Use [SIPp](https://sipp.sourceforge.net/) and its
[documentation](https://sipp.readthedocs.io/) if selected; pin it during
implementation. No test reaches PSTN or a real paid provider by default.

Test service code, schema upgrade, authorization, real PostgreSQL transaction
semantics and selected Redis/Dragonfly commands; mocks alone cannot prove atomic
budget reservations, RLS, lease fencing or crash recovery. Keep provider workers
without Internet egress in default CI. A separately opt-in paid smoke test needs
explicit approval, reserved units, approved countries and known upper cost.

## Acceptance matrix

| Scenario | Expected behavior and evidence |
| --- | --- |
| Known allowed number/contact | Exact allow wins appropriate tier, normal routing, confidence/authentication remain visible; no mandatory enrichment |
| Explicitly blocked number | Fresh active rule gives configured action, reason/scope/revision; no provider call; retransmissions share result |
| Unknown number | Local unknown label, configured non-destructive default, optional bounded dedup intent; unknown is not automatically fraud |
| Spoofed caller ID | Unverified/invalid binding remains visible, trusted contact/business association does not prove call origin; no spoofed emergency bypass |
| Withheld or malformed | Separate bounded state, no normalization crash or paid lookup, explicit missing-ID policy |
| Canadian +1 versus US +1 | Full metadata resolves synthetic CA/US numbers, blocks only selected region; other NANPA/toll-free/ambiguous cases remain distinct; no Canadian paid request without approval |
| Business with several reviewed numbers | Only active reviewed associations match selected UUID/branch/tree; evidence and confidence returned; new candidate number not silently blocked |
| Uncertain/disputed business | Candidate annotation only; no inherited hard business block; provider CNAM/display name cannot verify entity |
| Country exception and global precedence | Authorized exact allow overrides delegable country restriction; mandatory platform rule still wins; other tenant/DID unaffected |
| Prefix/range/category breadth | Boundary and length checks, admin broad approval, impact preview; malformed/wildcard/overbroad input rejected |
| Cache hit and miss | Hit costs zero new units; miss returns local decision within target and coalesces work; negative and error caches distinct |
| Simultaneous INVITEs across replicas | Same transaction stable outcome/correlation; one downstream admission under proved affinity/owner mechanism; one provider job per feature/freshness, no overspend |
| Paid API timeout/ambiguous crash | Call continues; uncertain billing remains reserved/consumed conservatively; no lease-expiry duplicate dispatch |
| Multiple billed features | Each requested feature reserves units and money, all-or-none before dispatch; HTTP count differs from feature count |
| Monthly quota exhausted | 100 consumed/reserved/uncertain blocks new spend; cached/local policies work; no automatic fallback-provider overage |
| Concurrent quota boundary | At 99 units, many workers can reserve at most one unit globally; multi-feature request cannot partly overspend; include both sites |
| UTC rollover and override | New period chosen at dispatch, old uncertainty preserved; override bounded/audited; invoice reconciliation cannot reset base cap |
| Redis unavailable/failover | In-process policy still evaluates; durable dedup prevents paid duplicates; no use of TOPOS DB or broad flush |
| PostgreSQL unavailable | Local snapshot works within age/expiry, writes/reservations fail closed; bounded spool reports loss/lag; no per-call writer wait |
| Evaluator unavailable/invalid response | <=75 ms proposed bounded wait, normal existing route, degraded metric; no arbitrary URI/action accepted |
| Carrier retransmission | INVITE repeats return consistent transaction handling, no duplicate evaluation side effects, downstream call or external lookup |
| In-dialog requests | ACK/BYE/CANCEL/UPDATE/re-INVITE/INFO/PRACK never initiate full evaluation; suspended request can be canceled once without late reroute |
| Existing IVR/extensions | Silent collector, authorized digit destinations, parallel contact ringing/first-answer cancellation and no-contact fallback unchanged |
| Existing fax/voicemail paths | Actual fax test preserves supported RTP/T.38 behavior; no audio challenge on fax role; legacy FaxNumber-to-7101 unchanged; mailbox greeting/PIN/recording and teardown work |
| Existing WebSocket/registration/media | REGISTER/auth and WSS ownership unaffected, DTMF/trickle handlers intact, bidirectional RTP and clean BYE/200/ACK through current helpers |
| YVR/YXL failure and rejoin | Each site admits calls from local snapshots/cache, no remote writer/cache wait; paid work halts without fenced ledger authority; revision/expiry catches up before enforcement |
| False-positive correction | Exact allow/dispute/tombstone invalidates online sites <=2 s target, stale decisions unusable; pending partitioned sites visible, no false immediate-convergence claim |
| Tenant isolation/ownership reassignment | Cross-tenant IDs/cursors/evidence denied; old extension owner loses current grants/history access per policy; certificate cannot claim another site/DID |
| Provider rights expiry/deletion | Forbidden content absent from DB/cache/logs/disk, hard expiry and backup restore tombstones hold; Places content not durably copied |
| Observability and load | Bounded labels/redaction, no raw numbers/credentials/DTMF, latency targets at declared load; log/trace outages cannot stop calls |

## Proposed rollout order

1. Approve contracts and unknowns, then provision only a private local-policy
   service and management path with paid adapters/enforcement disabled.
2. Validate identity, RLS, snapshots, cache, policy revision acknowledgements,
   emergency guard, expiry and failure fallback in a non-production harness.
3. Add adapters with mock traffic and a disabled paid worker. Enable a real
   feature only after rights/pricing/approval and atomic-accounting acceptance.
4. Add business/reputation capabilities in simulation; review false positives,
   categories and trust requirements. Do not use an arbitrary fixed observation
   duration as proof of accuracy; collect representative cases and agreed metrics.
5. Introduce one controlled DID's asynchronous observe-only carrier integration.
   Confirm all three replicas, no duplicate forwarding, Homer correlation,
   cancellation and current user-facing workflows. If runtime inspection is
   needed at YVR use the documented `logged-user` context.
6. Enable low-risk explicit exact-number enforcement on that DID, with a tested
   bypass and administrator recovery route; expand only after controlled inbound
   allow/block/voicemail/fax tests and correction latency pass. Keep score-based,
   category and challenge actions disabled until separately accepted.
7. Expand by DID/site/action with staged review. Exercise WAN/cache/writer failures,
   budget fencing and rejoin before claiming multi-site protection is reliable.

Future deployment tasks use narrow commits, exact outgoing diff review, the
owning Argo layers and downstream verification. `Synced` or ready pods alone
are not acceptance. A controlled real call in a later authorized test window
should be correlated directly in available logs/Homer; no request for users to
collect private logs.

## Rollback and stop conditions

Keep independent switches for evaluation bypass, observe-only, each enforcement
action and paid dispatch. On false-positive spike, latency/timeout regression,
duplicate SIP forwarding, unexpected cost or loss of policy consistency, disable
the affected action/DID or bypass the classifier, pause workers if accounting is
uncertain, and return to the pre-existing route. Maintain active dialogs and
media; do not roll telephony pods or delete state merely to disable protection.

Restore a previous compatible service/policy revision through normal Git/Argo
workflow. A policy rollback is a **new** revision with invalidation/acknowledgements,
not reuse of an old revision number. Retain usage/uncertain reservations and
reconciled history; rollback cannot refund or replay a potentially billed call.
Do not reverse schema by dropping tables. Separate destructive retirement from
routing rollback and inspect platform claim/provider orphan policies, PVCs,
finalizers and backups. Verify calls, fax, IVR, voicemail, registration, DTMF,
RTP and teardown after rollback, including the cross-site path.

## Next implementation task dependencies

Before phase 2 starts, choose supported Go/pgx/normalization libraries and metadata
pins, finalize tenant/DID/extension/contact ownership and Authentik claims, review
PostgreSQL identity/grants/writer routing, reserve a Dragonfly DB through Backplane,
select signed snapshot transport/storage, define service roles/mTLS and private
Gateway access, and agree retention plus outage limits. Implement missing review/
audit/assignment/override API contracts before their UI journeys.

Before phase 3, obtain contracted feature tariffs and failed-request billing,
Canadian access evidence, provider credentials by Vault reference, permitted
retention/attribution/residency, explicit currency ceilings and a dispatcher
fencing/reconciliation design. Before phase 6, prove carrier image modules,
transaction affinity, timeout/cancel behavior, exact route insertion point and
safe action targets using the complete Lovely render. These are open engineering
tasks, not features delivered by this documentation change.

## Documentation validation performed for this delivery

- Parsed and structurally validated the OpenAPI 3.1 contract using
  `openapi-spec-validator` 0.7.2 in an isolated temporary environment.
- Validated the complete synthetic evaluation request/response examples against
  their schemas and confirmed an arbitrary routing-URI field is rejected.
- Resolved all internal OpenAPI references, checked unique operation IDs and
  checked local Markdown link targets in the package and four updated indexes.
- Reviewed documentation-only changed paths, source/proposal distinctions,
  provider gates, reserved fictional examples and scoped whitespace/phone guards.
- Inspected the four existing Forgejo image workflow path filters: these document
  paths do not request those builds. No Helm/Lovely rendering or telephony runtime
  test is evidence for this delivery because no deployed inputs were changed.

These checks establish documentation/contract consistency, not implemented API,
provider access, classifier accuracy, latency, concurrency safety or live health.
