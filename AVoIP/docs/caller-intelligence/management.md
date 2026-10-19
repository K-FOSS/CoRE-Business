# Authentik and Call Protection management design

Status: proposal, no UI or Authentik resource implemented. Use
[Authentik](https://goauthentik.io/) with its
[OAuth2/OIDC provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/).
Existing [AVoIP group declarations](../../templates/Authentik/AVoIPGroups.yaml)
and [SMS inbox patterns](../FLOWROUTE-SMS.md) are references, not automatic grants
for call protection. Existing `AVoIP Admins` is application access, not Authentik
superuser status. Avoid broadening its existing mail/SMS attributes accidentally.

The proposed Call Protection UI must follow the shared
[2019–2022 Material Design 2 specification](../UI-DESIGN.md), including existing
SMS typography, surfaces, controls and responsive behavior.

## Identity and access

Propose an Authentik confidential OIDC application with authorization-code flow
and PKCE, exact redirect allowlist and server-side BFF sessions. Validate issuer,
audience, signature, nonce, state and expiry; secure HttpOnly SameSite cookies,
CSRF protection, session rotation and logout. Browser does not receive provider
secrets or service client certificates. Server-side authorization applies to every
request, including history, lookup, simulation and exports. Private Authentik-only
routes have no Forecastle annotations and no `wan-mode: 'public'` DNS selection.
The final hostname, Gateway attachment and client ID are implementation inputs.

| Role | Proposed permissions |
| --- | --- |
| User | Own assigned direct DIDs/extensions and reports/history, create/expire own rules, simulate owned scope; manual paid lookup only with delegated entitlement |
| Tenant administrator | Tenant defaults, DID ownership/delegation, reviewed directory and disputes; tenant usage and authorized audit; cannot grant platform scope |
| Directory reviewer | Review sourced business/branch/number/category evidence within assigned tenant; no budget/provider privilege unless separately granted |
| Platform administrator | Global mandatory rules, tenant publication, provider enablement, quota overrides and emergency guard configuration with audit |
| SBC principal | Evaluate only approved ingress/site/DIDs, no management writes or user history enumeration |
| Worker principal | Read eligible jobs, reserve/settle feature usage and write permitted evidence; cannot alter user policy or global permission |

Map roles from explicitly reviewed claims/groups plus server-owned assignments;
never from an arbitrary email suffix, mutable username or user-supplied tenant ID.
Number/extension reassignment revokes the prior owner's policy-management grant
and retains historical visibility only under an explicit retention/access rule.
A user cannot request another tenant's business evidence or infer its blocked
numbers through search/error behavior. Cross-tenant global directory publication
is separately reviewed and excludes private contacts.

## Proposed layouts

```text
Call Protection                      [Tenant] [Owned DID / Extension] [Policy status]
Overview | Number search | Businesses | Policies | History | Usage | Audit

Overview
  [Protection mode: Observe / Enforce] [Policy revision] [Site convergence]
  [Cache availability] [Provider availability] [Monthly remaining /100]
  Recent calls: time | redacted caller | identity confidence | suggested / actual action
  Explanation drawer: winning policy, shadowed rules, attestation, source freshness

Number search
  [Number + input region] [Search local/cache]
  Identity: candidate/reviewed, number association, auth limitations, provenance
  [Allow] [Block] [Temporary rule] [Report] [Request paid lookup]
  Paid preview: feature/provider/country, permission, units, maximum cost, remaining

Policies
  [Scope] [Exact / Prefix / Range / Country / Business / Category / Missing identity]
  Selector | action | start / expiry | reason | priority | active revision
  [Draft] -> [Simulate] -> [Impact preview] -> [Activate] -> [Pending site acknowledgements]

Businesses
  Entity / branch tree | aliases | reviewed numbers | independent categories
  Candidate evidence separately from first-party verified records
  [Review association] [Dispute] [Block branch] [Block reviewed entity tree]

Usage / Administration
  Base allowance | explicit overrides | consumed | reserved | uncertain | remaining
  Estimated costs / currency | reconciled invoice costs | provider health and approval
  No credentials displayed; configuration shows references and redacted capability only
```

Small screens use one scope selector, stacked call cards and a single explanation
drawer. Keep provenance/status text explicit; color alone cannot communicate risk
or verification. Users see actual active-site state, not a false “enabled” banner
when publication is still pending. Raw caller numbers/history need authorized
reveal, and temporary rules always show exact expiry/timezone.

## Journeys and acceptance

1. **Block an unwanted number**: open own call -> inspect identity/attestation
   separately -> create exact-number temporary/permanent draft -> simulate against
   recent authorized calls -> see conflicts/breadth -> activate -> wait for site
   convergence. Undo deletes the rule and invalidates decisions; it never hangs
   up an existing call.
2. **Allow an exception to a country rule**: select direct DID and CA/US region
   policy -> add exact allow -> preview precedence. Explain any mandatory global
   block that still wins. For a shared IVR, show that recipient policies cannot
   apply until the recipient is selected and the local gate exists.
3. **Block a business**: search reviewed business UUID -> inspect branch tree,
   associated numbers, confidence and evidence -> choose branch or reviewed entity
   tree -> simulate -> activate. Candidate identity is presented for review and
   cannot silently block all associated numbers. Financial category is not fraud.
4. **Paid manual lookup**: local search first -> choose explicit feature -> show
   country approval/retention, unit and maximum cost -> submit if entitled -> show
   job status and accounting. Quota exhaustion keeps local search usable; a user
   cannot bypass it with a new idempotency key. Ambiguous provider completion
   appears as uncertain, not as free retry.
5. **Correct a false positive**: inspect winning/shadowed evidence -> dispute
   association/report or create an authorized exact exception -> invalidate relevant
   revision/cache -> show site acknowledgements. Preserve correction audit and
   do not let a stale provider refresh undo reviewed corrections.
6. **Administrator review**: evaluate proposed broad prefixes/categories, global
   restrictions and provider settings; simulation uses authorized minimized
   history only. Show estimated match count, affected DIDs, inaccessible/unknown
   coverage and active-call exclusions. Budget overrides require explicit units,
   money, expiry, purpose and audit; no automatic overage button.

[API design](api.md) lists base and additional contracts. Business review/updates,
policy assignment, audit queries and override approval need dedicated endpoint
specification before these complete journeys can be implemented. History exports
are off by default and require a separate privacy review. No provider response
content is copied into durable records through a generic “save business” action.
