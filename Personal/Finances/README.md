# K-FOSS/CoRE-Business Personal/Finances

This repository is a generic starting point for a self-hosted personal-finance
stack. It is intended to grow around the user's goals—finance management,
budgeting, bill and subscription tracking, investing, and cash-flow
optimization—rather than define a single mandatory application. Firefly III is
the starting point and current reference implementation; additional apps can
be added when they provide a distinct capability.

The chart currently prepares Firefly III only. The companion applications below
are candidates for future additions, not deployed components or commitments.

This prepared chart deploys [Firefly III](https://www.firefly-iii.org/), a
self-hosted personal finance manager, with the
[BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It serves `firefly.mylogin.space` through a Gateway API HTTPRoute and uses the
upstream Firefly III container image at version `6.6.6`. Access is protected by
Authentik forward authentication.

## Candidate companion applications

The intended division of responsibility is to keep one clear source of truth
for transaction records and avoid deploying several overlapping ledgers. A
reasonable starting architecture is Firefly III for detailed transaction
tracking, with at most one specialist application for each unmet goal.

| Goal | Candidate | Why it fits | Current recommendation |
| --- | --- | --- | --- |
| Plan spending with an envelope budget | [Actual Budget](https://actualbudget.org/) ([installation documentation](https://actualbudget.org/docs/install/)) | Local-first envelope budgeting, multi-device sync, imports, API, and optional bank sync through supported providers. | Strongest next candidate if the priority is assigning available cash to categories before spending. Validate Canadian-bank coverage and the handling of bank-sync credentials before enabling it. |
| Track recurring bills and subscriptions | [Wallos](https://github.com/ellite/Wallos) ([API documentation](https://api.wallosapp.com/)) | Focused, self-hostable subscription tracking with recurring-expense and budget views. | Good lightweight companion for renewal dates, cancellation review, and recurring-cost visibility; keep actual transactions in Firefly III. |
| Track investments and portfolio performance | [Ghostfolio](https://ghostfol.io/) ([source and self-hosting documentation](https://github.com/ghostfolio/ghostfolio)) | Open-source wealth management for stocks, ETFs, and crypto, designed for continuous personal use. | Good web-based candidate when portfolio analytics are needed; verify market-data-provider requirements and backups first. |
| Track investments plus longer-term goals locally | [Wealthfolio](https://wealthfolio.app/) ([documentation](https://wealthfolio.app/docs/introduction/)) | Local-first investment tracking with holdings, allocation, income, net worth, budgeting, and retirement/FIRE planning. | Worth comparing with Ghostfolio if privacy and planning matter more than a central always-on web service. |

[Maybe](https://github.com/maybe-finance/maybe) is not recommended for a new
deployment: its upstream repository states that it is no longer actively
maintained. Reconsider only if a maintained fork with a clear upgrade and
security story is selected.

### Suggested evaluation order

1. Keep Firefly III as the transaction ledger and establish import, backup, and
   reconciliation workflows.
2. Add Wallos if recurring bills and subscriptions are the immediate gap.
3. Evaluate Actual Budget if the main gap is forward-looking, envelope-style
   cash allocation. Decide whether it complements Firefly III or becomes the
   budgeting source of truth before importing the same accounts into both.
4. Add either Ghostfolio or Wealthfolio only if investment and retirement
   planning needs exceed Firefly III's scope.

Bank aggregators and investment market-data providers may transmit sensitive
financial information to third parties. Treat credentials, provider terms,
regional coverage, rate limits, exports, and restore procedures as acceptance
criteria for any future component. Do not add a companion application to this
chart until its deployment owner, persistence, access policy, secret handling,
and data ownership are documented.

## Access and identity

The route is protected fail-closed by an Envoy Gateway
[`SecurityPolicy`](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
that forwards requests to the site Authentik outpost Service
`aaa-myloginspace-proxy` in `core-prod`. A Crossplane Terraform `Workspace`
creates the Authentik forward-single proxy provider and application through the
`authentik` ProviderConfig. Authentik owns login and session cookies; the route
is intentionally not exposed through Forecastle because Forecastle is reserved
for public services.

The pattern follows the existing
[Office ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/NextCloud.yaml)
and [Fitness Authentik configuration](https://github.com/K-FOSS/CoRE-Business/blob/main/Personal/Fitness/templates/Authentik.yaml).

Firefly III creates its PostgreSQL role and database through the current
[Backplane `mylogin.space` User resource definition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml),
using the generated connection Secret for `DB_DATABASE`, `DB_USERNAME` and
`DB_PASSWORD`; Backplane
auto-generates the username and matching database name. The chart uses the
[External Secrets Password generator](https://external-secrets.io/latest/api/generator/password/)
and ExternalSecret CRDs to create `firefly-app-key` once with a raw,
32-character `APP_KEY`; the generated value is never stored in this repository,
and the target Secret is retained across chart removal. The cluster must have
the External Secrets generator installed before activation. If an earlier
deployment created the Secret with an incorrectly encoded key, replace that
Secret only after confirming that no encrypted data depends on it. Do not
rotate or delete an established key without planning for existing encrypted
data and sessions to become unusable.
The 10Gi Longhorn upload PVC is retained across chart removal and must be backed
up alongside the PostgreSQL database.

The database host defaults to the local-scoped PostgreSQL endpoint
`psql-local.<cluster>.<datacenter>.<region>.mylogin.space`; the owning
ApplicationSet must inject those site values and the matching PostgreSQL
provider references.

There is currently no active Firefly owner in the
[CoRE-Backplane Apps/Business tree](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Apps/Business),
so this is prepared desired state and will not deploy until an ApplicationSet
explicitly references `Personal/Finances`. Its future owner must inject
`cluster.name`, `datacenter`, `region`, and both Firefly PostgreSQL provider
references, select
the target namespace and renderer, and confirm the `main-gw` /
`https-myloginspace` listener. The generated database role and name are
retained by the Backplane database resources.

The chart includes a per-minute Firefly scheduler CronJob. Its generated name
is capped at Kubernetes' 52-character CronJob limit. Review its inherited
Gateway access policy before activation; the route is labeled public/private.

```sh
helm dependency build Personal/Finances
helm lint Personal/Finances \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set firefly.database.crossplane.crossplaneProvider=psql-home1-yvr \
  --set firefly.database.crossplane.terraformProvider=psql-home1-yvr
helm template core-business-firefly Personal/Finances --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=yvr \
  --set region=yvr \
  --set firefly.database.crossplane.crossplaneProvider=psql-home1-yvr \
  --set firefly.database.crossplane.terraformProvider=psql-home1-yvr \
  >/tmp/core-business-firefly.yaml
```

Review the upstream [Firefly III source repository](https://github.com/firefly-iii/firefly-iii),
[installation documentation](https://docs.firefly-iii.org/references/faq/install/),
[Kubernetes support repository](https://github.com/firefly-iii/kubernetes),
[Authentik proxy-provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/proxy/),
[Envoy Gateway external-authorization documentation](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/),
[Crossplane Terraform provider documentation](https://marketplace.upbound.io/providers/upbound/provider-terraform),
[BJW-S Common](https://bjw-s-labs.github.io/helm-charts/tree/main/charts/library/common),
and [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) documentation.
After activation, verify PostgreSQL connectivity, the `/health` endpoint, login
and transaction creation, scheduler completion, route policy behavior, and
restore of both the database and upload PVC.
