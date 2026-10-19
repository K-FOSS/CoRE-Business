# Policy, classification and reputation specification

Status: proposal. Call actions are `normal`, `warn`, `challenge`, `voicemail`
and `reject`. `warn` means a controlled callee UI indication while retaining
normal routing; if no supported endpoint exists it falls back to `normal`.
An audio warning or challenge requires a separately approved B2BUA route.
Never rewrite caller identity or inject an arbitrary redirect as a warning.

## Independent evaluation properties

| Property | Meaning |
| --- | --- |
| Spam risk | Calibrated 0–100 risk plus raw weighted score, model revision and uncertainty; unknown is not zero-risk evidence |
| Identity confidence | 0–1 confidence and status `unknown`, `candidate`, `reviewed`, `verified`, `disputed`; verification method and expiry required |
| Business categories | Versioned configurable many-to-many labels, each with source, reviewer, confidence and validity |
| Authentication | STIR/SHAKEN status `valid`, `invalid`, `unavailable`, `not_present`, attestation A/B/C or null, trust source and binding checks |
| Explicit policy | Winning allow/block rule, enforcement tier, scope, exceptions, validity and revision, independent of numeric score |

A reviewed business-to-number association does not prove that today's call
originated from that business. Track number association confidence separately
from call-origin authentication; show both. A valid attestation is confidence
in an asserted number under the verifier's semantics, not proof of harmlessness.
VoIP carrier type, SIP display name and a CNAM label never establish a business.
Debt collection and financial services are legitimate categories; blocking
preferences must not mark every member as fraudulent. `known_scam_operations`
requires reviewed, attributable evidence and a correction path.

## Number and country selectors

Normalize valid public numbers to E.164 with a pinned metadata revision. Keep
national input plus an authorized default region only at input boundaries;
never guess a region from caller-controlled headers. Separate `withheld`,
`malformed`, `unknown`, `non_geographic`, and internal-extension identifiers.
E.164 syntax validity does not establish assignment, reachability or ownership.

- **Exact**: normalized number, per-user/extension/DID/tenant/global scope,
  reason, actor, start, optional end; permanent rules have null expiry.
- **Prefix**: canonical E.164 digit prefix, including calling-code boundary;
  no arbitrary regex. Simulation shows cardinality estimate and examples with
  redaction. Proposed ordinary-user minimum is country code plus three national
  digits; broader prefixes require admin review, explicit broad-match approval
  and an impact cap. A whole-country restriction uses the country selector.
- **Range**: inclusive start/end, same calling code and national length,
  start <= end; compare canonical digits/length, not arbitrary lexical text.
  Show computed range size. Proposed >1,000 numbers requires admin approval.
  UI/API reject reversed, cross-plan, empty and overly broad selections.
- **Country**: ISO 3166-1 alpha-2 using numbering-plan region metadata, not
  source IP. Resolve Canada and US within shared +1 using full metadata;
  other NANPA regions are distinct. +1 alone cannot implement CA/US policy.
  Shared/non-geographic/toll-free or ambiguous regions stay unresolved unless
  reliably assigned. Never infer real caller location from number-assigned region.
- **Missing identity**: explicit withheld/unknown/malformed rules with their own
  behavior; do not silently match them against a blocked country or paid lookup.

An exact allow exception can override a country restriction within a delegable
policy tier. An attested number may still be spoofed through a compromised
origin; a contact allow is a user preference, not an authentication bypass.

## Business and category selectors

Business UUIDs are stable and tenant-owned (or explicitly administrator-published
shared directory entries). A branch has a UUID and optional reviewed parent.
Aliases support search only. A business block matches only active **reviewed**
number associations with sufficient configured association confidence and an
appropriate call-origin trust requirement for high-impact actions. Candidate,
expired or disputed matches may annotate/warn but cannot inherit a hard business
block automatically. A disputed candidate must not claim a verified business.

A rule explicitly chooses `branch_only` or `reviewed_entity_tree`; parent-to-child
membership and each number association are reviewed and versioned. A new number
or branch is not swept into an old block until approved. Reassignment closes
old association validity, invalidates caches and prompts review of number rules.

Categories start with debt collection, telemarketing, financial services,
political solicitation, surveys and known scam operations. Taxonomy is configurable,
independently assigned and can contain several labels per entity. Category
blocking is a preference with an explanation and exceptions, not a fraud finding.
Automatically suggested categories require review before broad enforcement.

## Deterministic precedence

Evaluate applicable rules against one immutable revision. The tiers below are
ordered; stop action selection at the first tier with an actionable match, but
retain lower matches as shadowed explanation evidence.

1. **Protected infrastructure/path guard**: outbound emergency-service dialing,
   registrations, internal extensions, active dialogs and authenticated health/
   infrastructure calls bypass this inbound subsystem. Known emergency callbacks
   need a reviewed callback route/identity policy; a caller claiming an emergency
   name or number never obtains this guard. Ordinary carrier calls are not trusted
   infrastructure merely because the carrier source is trusted.
2. **Mandatory global restrictions**: only administrators can designate a global
   rule non-delegable. Scope must include the affected tenant/DID and protected
   path exclusions; no user allow overrides it. Deletion requires admin audit.
3. **Delegated scope overrides**: DID > selected extension/user > tenant > global
   default. Broad restrictions from a higher tier can declare themselves mandatory
   only through tier 2; ordinary global defaults allow explicit user exceptions.
   DID owners must explicitly delegate user overrides if overriding that DID's
   mandatory local preference is desired. A user cannot override another owner.
4. **Within a scope**: exact number > reviewed branch/entity > range/prefix
   (smallest range/longest prefix) > country > category > contact-derived default.
   An exact allow beats a category/country block at the same scope. Equal
   specificity uses explicit priority, then block over allow, then stable UUID;
   publishing conflicting equal-priority rules shows a validation warning.
5. **Risk thresholds**: applied only when no explicit policy decides. A risk-based
   action cannot override an explicit allow; authentication failures remain
   visible in the result. Independent SIP transport/security rejection remains
   outside the classifier and cannot be bypassed by any caller allow rule.

Global scope is platform-admin-only. Tenant admins may manage tenant defaults;
users may manage assigned DIDs/extensions. A shared DID uses its own policy at
initial ingress, never the union of every eventual recipient's private blocks.
Before an IVR selects an extension, that user scope is unknown. A future local
post-selection check can enforce user policy without a second lookup; until
implemented, the UI marks those policies inactive on shared-IVR ingress.

Example: an exact user allow defeats a delegable tenant country block only on
that user's authorized direct DID. It cannot defeat a mandatory global block
or affect another subscriber. A DID override wins over a user preference unless
its owner has explicitly delegated that decision.

## Modular rule contract

Each rule declares symbol/version, input dependencies, applicability, missing-data
behavior, score dimension, weight, group cap, evidence validator, confidence
function, expiry and optional suggested action. Rules are bounded deterministic
Go functions over a prepared context; no rule performs network I/O. A versioned
configuration supplies weights and thresholds. No production scores are selected
by this proposal.

| Symbol | Evidence and proposed effect |
| --- | --- |
| `CONTACT_TRUSTED` | Authorized contact match; lower risk by configurable amount; annotate identity source, do not assert authentication |
| `NUMBER_EXPLICITLY_BLOCKED` | Active winning block policy; action override, not a large artificial score |
| `NUMBER_EXPLICITLY_ALLOWED` | Active allow; normal routing override, other evidence still returned |
| `BUSINESS_VERIFIED` | Reviewed association and independent verification method; identity confidence, optional capped risk reduction |
| `BUSINESS_BLOCKED` | Reviewed UUID/branch match and trust requirement; explicit policy |
| `BUSINESS_CATEGORY_BLOCKED` | Reviewed category matching policy; explicit preference with category/evidence |
| `COUNTRY_RESTRICTED` | Confident number-region match and scoped policy; explicit policy |
| `CALLER_ID_UNVERIFIED` | Missing/unavailable authentication; confidence reduction, risk weight can be zero |
| `CALLER_ID_MALFORMED` | Invalid bounded identity; explicit missing-ID behavior or configurable risk |
| `NUMBER_PREVIOUSLY_REPORTED` | Deduplicated reviewed reports with decay; capped reputation signal |
| `REPEATED_SHORT_CALLS` | Distinct completed call outcomes in a configured window; exclude failed infrastructure calls and retransmits |
| `HIGH_CALL_FREQUENCY` | Unique admitted call attempts per number and tenant/DID window, not carrier packet count; cap influence because spoofing can poison it |
| `SUSPECTED_DEBT_COLLECTOR` | Candidate category with provenance; label only by default, no fraud assertion or automatic block |
| `CARRIER_LOOKUP_UNAVAILABLE` | Provider unavailable/forbidden/quota-limited; operational uncertainty, default zero spam contribution |
| `UNKNOWN_CALLER` | No usable identity/directory evidence; default zero or a separately calibrated small score, never an automatic reject |

Compute raw score as sum of weighted confidence-adjusted matches after correlated
group caps. Convert to calibrated risk using a versioned documented mapping;
missing evidence is not negative evidence. Proposed threshold configuration is
`T_warn < T_challenge < T_voicemail < T_reject`, all deployment-configurable;
actions can be disabled per DID (especially fax). Observe-only records the
suggested action while returning enforced `normal`. No automatic weight learning
or threshold changes from unreviewed reports.

## Reputation lifecycle and explanation

Count unique calls, not SIP messages, and deduplicate reports by actor/call/category.
Track attempts separately from completed calls and duration. Exclude challenge/
voicemail durations from ordinary short-call heuristics; avoid a feedback loop
where classifier-induced hangups raise future risk. Tenant-private reports do
not become global reputation without review. Bound rate effects, decay signals,
retain source timestamps and support disputed/withdrawn reports. The caller
number alone is not a trustworthy actor identity.

Return matched symbols, evidence references with redacted summaries, raw
contribution, confidence dimension, shadowed status, winning policy, policy/model
revisions, data freshness and an explanation such as “Voicemail by DID rule;
reviewed branch association; no assertion that the call is fraudulent.” Evidence
must be inspectable by an authorized reviewer; private contacts/reports remain
redacted from other scopes. [API](api.md) defines the response shape.
