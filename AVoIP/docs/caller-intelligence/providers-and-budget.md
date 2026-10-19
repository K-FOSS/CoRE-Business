# Lookup providers, licensing and budget

Research date: 2026-10-18. These are supported **upstream capabilities**, not
implemented CoRE adapters. All paid adapters start disabled. Carrier/line type,
caller name, business identity and spam reputation are distinct capabilities.

## Capability and cost comparison

| Adapter | Confirmed capability and geography | Price planning and enablement |
| --- | --- | --- |
| Local [libphonenumber](https://github.com/google/libphonenumber), [FAQ](https://github.com/google/libphonenumber/blob/master/FAQ.md) | Formatting, possible/valid numbering pattern, region and allocation metadata worldwide; no live ownership/reachability or current carrier verification | No external billable feature request; pinned metadata/license and reviewed Go binding required |
| Reviewed PostgreSQL directory | Tenant-authorized contacts, business UUIDs, aliases, categories and reviewed number associations | No external charge; independently reviewed first-party records, not copied restricted provider content |
| [Twilio Lookup v2](https://www.twilio.com/docs/lookup/v2-api), [Line Type Intelligence](https://www.twilio.com/docs/lookup/v2-api/line-type-intelligence) | Carrier/line type, broad international coverage subject to restrictions; no business classification or general call-spam verdict | Public [pricing](https://www.twilio.com/en-us/lookup/pricing) shows USD 0.008 per feature request; contract, geography and taxes require verification |
| Twilio [Caller Name](https://www.twilio.com/docs/lookup/v2-api/caller-name) | US-number CNAM label/type; not Canadian carrier data, reviewed entity identity or proof of caller origin | Public inbound caller identification price USD 0.01 per request; verify account mapping to Caller Name. US requests may bill even when no name is returned |
| [Sinch Number Lookup v2](https://sinch.com/), [v2 API](https://developers.sinch.com/docs/number-lookup-api-v2/api-reference) | `LineType`, carrier/type; port-corrected US/CA data, original range-holder data elsewhere; coverage restrictions apply | Account quote required; no verified universal per-feature public rate. Do not configure an unknown price as zero |
| [Google Places](https://developers.google.com/maps/documentation/places/web-service/overview), [policies](https://developers.google.com/maps/documentation/places/web-service/policies) | Candidate business search and details/phone fields using an appropriate query; no guaranteed universal reverse-number owner service | Billing-enabled project, correct API and field-mask SKU required; optional later adapter, disabled pending license and cost approval |
| Future reputation providers | No selected feed, coverage, rights or confidence calibration | Future possibility only; new capability/contract/security review and fixtures required |

Twilio identity match compares supplied identity attributes; it is not a reverse
business directory. SMS pumping scores measure a different abuse domain and
must not be relabeled as inbound call spam. Sinch lists SIM Swap beta and VoIP
Detection alpha; these and RND are outside the initial adapter. Neither a VoIP
label nor a bank name means fraud. Prefer local directory, then a fresh licensed
cache; use only one eligible external feature provider by configured priority.
Automatic fallback is another possibly billable operation requiring reservation.

### Canadian restrictions

Twilio documents [CLNPC approval](https://help.twilio.com/articles/360004563433-Twilio-Lookup-API-is-Not-Returning-Carrier-Data-for-Canadian-Phone-Numbers)
for Canadian carrier intelligence, including non-member access and an annual
contract fee directly with CLNPC. Without access, data can be null with error
`60601`. Recheck package-specific restrictions before activation. **Canadian paid carrier
intelligence is disabled until written approval and provider-account enablement
are confirmed.** Twilio US Caller Name is a separate capability and approval.

Sinch documents Canadian coverage, but that does not establish this account's
rights or bypass CLNPC requirements. Obtain written confirmation of its Canadian
access basis, permitted use, approvals and retention before enabling Canadian
carrier features through any adapter. Do not try another provider to evade an
approval error. Local CA/US number-region parsing remains available.

### Places handling

[Places policies](https://developers.google.com/maps/documentation/places/web-service/policies)
restrict prefetching, caching and storage outside permitted exceptions; place IDs
may be retained. Do not apply the generic seven-day business TTL to Places
content. Default to no stored API content; retain permitted place IDs and
minimal non-content request accounting only. Re-fetch permitted display data
through a licensed workflow. A reviewer clicking “verified” does not convert
restricted API content into unrestricted first-party records. Independently
collect/verify organization records with separate provenance. Display required
Google/third-party attribution; when showing a map use the permitted Google Map
presentation. Terms of use/privacy notices must meet applicable requirements.

Fields and [SKU pricing](https://developers.google.com/maps/billing-and-pricing/pricing)
change the charge: search and a follow-up details request may both bill. Do not
assume an old USD 200 credit or free tier makes requests free. For planning only,
a USD 0.05 per-step reserve is an illustrative ceiling, **not a verified SKU
price**; an actual enabled field mask needs a confirmed ceiling before scheduling.
Contract restrictions, including derived-data usage, require review before a
Places result can influence persistent classifications.

## Adapter declaration and normalized result

Every versioned capability manifest must contain:

| Field | Contract |
| --- | --- |
| Provider/API revision, feature IDs and priority | Exact requested features; per-country priority. Never allow provider defaults to add billed features |
| Countries and exclusions | ISO regions plus ambiguous/non-geographic behavior; approval state/evidence/expiry per country and feature |
| Permissions | Twilio Lookup-enabled account/API key with minimum supported access; Sinch project/service-plan and authorized IAM client; Google restricted key/service identity, enabled Places API and billing; no credentials in manifest |
| Price | Currency, per-feature country/SKU tariff, maximum reservable price, effective/review dates and source; unknown price disables feature |
| Data rights | Allowed uses, retention ceiling, cache permission, attribution, deletion and redistribution restrictions; unknown rights disable storage/use pending review |
| Response schema | Strict size/type/version validation and per-feature errors, normalized source IDs and timestamps |
| Runtime | Worker timeout, rate/concurrency limits, circuit breaker, retry policy, priority, dedup key and availability state |
| Failure behavior | Classify unsupported, approval denied, not found, rate limited, provider error and ambiguous completion separately |

Twilio requests `GET /v2/PhoneNumbers/{E164}` with explicit `Fields`;
normalize `phone_number`, `country_code`, `valid`, `line_type_intelligence`
(including type/carrier/error) or `caller_name` (name/type/error). Treat null
with feature errors separately from an authoritative negative.

Sinch v2 uses [POST `/v2/projects/{projectId}/lookups`](https://developers.sinch.com/docs/number-lookup-api-v2/api-reference/number-lookup-v2/numberlookupv2)
with `number` and explicit `features: ['LineType']`; otherwise it defaults to
LineType. Normalize `number`, `countryCode`, `traceId`, `line` carrier/type/
porting/MCC/MNC and feature errors. Prefer [OAuth](https://developers.sinch.com/docs/number-lookup-api-v2/api-reference/authentication)
for production. Do not implement against the separate older API base URL.

Common result: provider/feature/version, canonical number, status, minimal
permitted data, observed/retrieved/expiry timestamps, provenance/license revision,
provider reference and cost status. Timeout starts at 2 s for Twilio/Sinch,
3 s Places. No automatic same-attempt retry after uncertain completion.
Positive/negative cache eligibility and TTL use the stricter of source rights
and [local TTLs](caching.md). Local parsing/direct directory reads have no
external timeout or paid reservation.

## Quota and monetary ceilings

Hard initial cap: **100 billable feature requests across all sites/providers
per UTC calendar month**. Configure provider and feature subcaps whose total
cannot evade the global cap. Example proposed allocation: Twilio 80 (line type
60, US caller name 20), Sinch 20 (LineType 20), Places 0. Disabled features do
not automatically transfer quota. Apply a tenant fairness cap to prevent one
user consuming all 100; global accounting remains the final authority.

Example estimates, excluding tax, FX, subscriptions and CLNPC fees:

| Plan | Billable units | Estimate |
| --- | --- | --- |
| 100 Twilio line-type features | 100 | USD 0.80 |
| 100 Twilio US Caller Name features | 100 | USD 1.00 |
| 50 numbers with both features | 100, even if only 50 HTTP requests | USD 0.90 |
| Example split: 60 line type + 20 caller name + 20 Sinch | 100 | USD 0.68 + 20 times the unverified Sinch rate |

A configurable illustrative USD 5 monthly ceiling provides headroom, but it
is not authorization to enable a provider, raise the 100-unit cap or pay an
annual access fee. Store money in integer micros with an explicit currency.
For multi-currency tariffs require a reviewed conservative FX reserve or separate
currency ceilings; never add unlike currencies. Estimates, reservations,
provider-reported charges and reconciled invoices are separate fields.

### Atomic reservation protocol

PostgreSQL is the global authority. Redis locks reduce work but cannot guarantee
spend bounds after restart or partition. One designated budget writer/worker
region is proposed initially; all paid work stops when it is unreachable.

1. Validate authenticated intent, number/region, tenant eligibility, privacy,
   cache freshness, approvals, exact features, tariff and manual-override scope.
   Rate-limit intents; unknown/malformed/withheld numbers never reserve quota.
2. In one transaction acquire fixed-order row locks for UTC period/global,
   provider, feature, tenant and currency counters. Uniquely insert the job for
   `(provider, feature, entitlement scope, number HMAC, freshness generation)`.
   A concurrent winner is reused. Multi-feature requests reserve every billed
   feature and corresponding money atomically, or reserve none.
3. Require `consumed + reserved + uncertain + requested <= cap` for every counter and monetary
   dimension. Persist feature reservations, price revision and outbox job before
   committing; dispatch only a committed reservation. No automatic overage.
4. Mark dispatch with a durable attempt/fencing token. A single job owner performs
   the request. A lease expiring is not permission for another worker to replay
   a potentially sent request; mark uncertain and reconcile.
5. Successful billed or billable-negative results move reserved to consumed.
   A failed call may still be billed. Release units only when known unbilled
   (for example conclusively not sent); a timeout/crash after possible send
   consumes conservatively or retains an `uncertain` hold against available quota.
   Never free uncertain reservations merely because their lease expired.
6. Reconcile provider usage/invoices later without silently resetting counters.
   Persist discrepancy and adjustment audit. An unexpected invoice overage
   freezes the adapter; provider-side spend caps/alerts are defense in depth.

Period is `[00:00 UTC first day, 00:00 UTC next first day)`. Database time
selects the dispatch period, not caller-supplied time. Reservations crossing
midnight must be revalidated/transferred before dispatch; in-flight work keeps
its original accounting period and records actual provider invoice period too.
Stop dispatch near the boundary if period attribution is uncertain. No quota
carry-over by default. Consumed plus unresolved units survives restart and failover.

An admin override is explicit, time-limited, attributed, scoped by provider/
feature/units/money and approved purpose. It adds an auditable separate allowance;
it never changes the standard cap silently. Read-only budget views expose base
and override separately. Quota exhaustion uses local policies and permitted cache.

Metrics distinguish HTTP requests, billable feature units, consumed, reserved,
uncertain, released, failures and remaining. Failure counters overlap accounting
states; they must not be subtracted from consumed automatically. Remaining is
`max(0, allowance - consumed - reserved - uncertain)` with states mutually
exclusive. [Data model](data-model.md) specifies ledger constraints.
