# CoRE Caller Intelligence & Call Protection

Status: **proposed architecture; documentation only**. Research date: 2026-10-18.
Nothing in this package enables a service, changes a schema, changes SIP routing,
or authorizes paid provider traffic. CoRE Caller Intelligence is the proposed
standalone Go application extending the existing CoRE-AVoIP platform.

It classifies initial inbound PSTN calls using local policies, reviewed business
records, contacts, independently tracked identity confidence and reputation,
and optional asynchronous enrichment. Kamailio remains the signaling and
routing enforcement boundary. Paid external lookups never gate establishment.
Existing registrations, extension routing, SMS, IVR, voicemail, fax, dialog
teardown and media ownership remain the acceptance baseline.

## Design package

| Document | Contents |
| --- | --- |
| [Discovery](discovery.md) | Actual repositories, inspected paths, revisions, reuse and evidence limits |
| [Technical research](research.md) | Kamailio modules, OpenSIPS, Rspamd and compatibility |
| [Architecture](architecture.md) | Components, call path, latency and failure contracts |
| [Providers and budget](providers-and-budget.md) | Capabilities, licensing gates, prices, reservations and accounting |
| [Policy and reputation](policy-engine.md) | Number/business/category policies, precedence, weighted rules and explanations |
| [PostgreSQL proposal](data-model.md) | Entities, proposed migration sequence, constraints, indexes and retention |
| [Cache specification](caching.md) | TTLs, invalidation, single-flight and site resilience |
| [API design](api.md) and [OpenAPI proposal](openapi.yaml) | Typed contract, authentication, examples and extension backlog |
| [Kamailio integration](kamailio-integration.md) | Three-replica transaction handling, trust and routing outcomes |
| [Management design](management.md) | Authentik, authorization, screen layouts and journeys |
| [Deployment design](deployment.md) | Proposed Kubernetes resources, platform identity and multi-site operation |
| [Security and observability](security-observability.md) | Privacy, retention, audit, metrics, traces and abuse prevention |
| [Testing and rollout](testing-rollout.md) | Fixture matrix, phase gates, implementation backlog and rollback |
| [ADR 001](adr-001-standalone-go-service.md) | Why a Go service with Kamailio rather than adapting Rspamd or adding OpenSIPS |

## Delivery boundary and decisions

Documentation lives beside [existing AVoIP architecture](../avoip/architecture.md).
The separately discovered [CoRE-AVoIP repository](https://slop.writemy.codes/CoRE/CoRE-AVoIP)
contains only a README at the inspected revision. No repository migration is
part of this design. Names of proposed resources and APIs are proposals, not
claims about deployed services. There is no new deployment directory yet.

Initial operating target: **100 billable feature requests per UTC calendar month
across all providers and sites**, with independently enforced monetary ceilings,
no automatic overage, and paid providers initially disabled. Local computation
and cache hits consume no paid allowance. Provider capability, permission,
price and retention approval are required per feature before enabling it.

Implementation proceeds through local protection, licensed provider adapters,
reviewed business intelligence, reputation, observe-only SIP integration,
controlled enforcement and multi-site reliability. [Phase gates](testing-rollout.md)
include user-facing regressions and a route-level bypass rollback. Upstream
capabilities already exist; the Caller Intelligence application does not.

## Open decisions requiring evidence

- Confirm current running carrier image modules and transport permissions;
  repository desired state is not a runtime module inventory.
- Select a Go libphonenumber implementation and pinned metadata release;
  Google's reference library does not supply an official Go binding.
- Confirm tenant/DID/extension ownership data and contact-directory source.
  Existing SMS number grants are not call-policy authorization.
- Obtain Canadian carrier-data permission, contracted provider prices,
  failed-request billing rules, retention/resale terms and data residency review.
- Prove platform PostgreSQL read/write behavior and site isolation before choosing
  snapshot transport; configured pooler peers are not proof of application HA.
- Approve retention, stale-policy limits, emergency callback handling, business
  review roles and calibrated score thresholds before enforcement.
- Allocate a new Dragonfly database in the platform registry during implementation;
  no database number is allocated by this document.
