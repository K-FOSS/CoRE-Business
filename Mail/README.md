# CoRE Mail

CoRE Mail is a site-specific mail transport, filtering and mailbox stack. It
combines Postfix, Dovecot, Rspamd, Maddy, DKIM/DNS resources, platform identity
and secret synchronization. An optional SimpleLogin alias service is present
but disabled by default.

## Deployment status and ownership

[The Mail ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Mail.yaml)
owns this active production stack. Mail is no longer classified as a legacy
service: a merge generator deploys it through Lovely to three explicitly
approved production clusters and into each target's `core-prod` namespace.

| Argo CD cluster | Site | Role |
| --- | --- | --- |
| `dc1-k3s-node1` | `dc1/yxl` | Credential hub and compatibility deployment retained during the scale-out. |
| `core-dc1-talos-prod` | `dc1/yxl` | Spoke production Talos deployment. |
| `core-home1-talos-prod` | `home1/yvr` | Spoke production Talos deployment. |

The ApplicationSet matches those entries to registered production clusters,
derives the API server, environment, cluster DNS domain, region and datacentre
from cluster metadata, and injects the target-specific LDAP endpoint,
PostgreSQL and Dragonfly hostnames, credential path, and PostgreSQL/S3 provider
names. It follows `HEAD` and preserves resources when a generator entry is
removed, so removing a target does not decommission its mail resources or
external data.

## Components and mail flow

The chart uses the [BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
to generate Deployments, Services, persistence and the optional SimpleLogin
Gateway API route. Mail-specific ConfigMaps remain direct templates because
they contain application configuration consumed by External Secrets template
rendering. External Secrets, CoRE `User`, DKIM, DNS and Cilium resources remain
direct templates because they are application/operator-specific custom APIs.
BJW-S Deployments use release-scoped names and its reserved selector labels;
the stable `dovecot`, `maddy`, `postfix` and `rspamd` Service names remain the
workload-facing endpoints. Spoke credential pulls reconcile in Argo CD sync
wave `-1`, before the workloads that consume those Secrets; legacy Deployments
are pruned only after the replacement resources become healthy.
All Mail Deployments opt into [Stakater Reloader](https://docs.stakater.com/reloader/)
automatic discovery, so changes to referenced ConfigMaps and Secrets trigger
their normal Kubernetes rolling-update strategy.
Workload pods disable automatic service-account token mounts; Mail containers
do not need Kubernetes API credentials.

```text
Internet SMTP :25/:465/:587
  -> Postfix
  -> Rspamd filtering
  -> Dovecot LMTP/mailbox path or optional SimpleLogin handler

Mail client IMAP :143/:993
  -> Dovecot or internal Maddy service
  -> LDAP authentication + platform-managed credentials/storage
```

- Postfix provides SMTP, implicit TLS, submission and an internal authenticated
  SMTP port. Its configuration combines ConfigMaps with ExternalSecrets for
  LDAP and database-backed routing/authentication. Authenticated LDAP users use
  their `mail` attribute as the sender identity when present; users without
  that attribute can send as `<cn>@<email.domain>` (currently
  `<cn>@mail.mylogin.space`). A `postfix-exporter` sidecar exposes Postfix
  queue size and age histograms on an internal metrics Service at port 9154.
  The exporter shares only Postfix's pod-local `public` socket directory; its
  log input is `/dev/null`, so log-derived delivery counters are not collected.
  The `mail.mylogin.space` virtual mailbox domain remains the only mailbox
  domain. The `snd.fyi`, `resolvemy.host` and `writemy.codes` virtual alias
  domains accept only recipients that resolve through LDAP group aliases.
  Postfix follows each group's LDAP `member` DNs, returns the members' primary
  `mail` attributes and delivers those addresses through the existing Dovecot
  LMTP endpoint. The pinned Postfix image applies `CONF_` variables to `main.cf`
  with `postconf -e`; alias domains are comma-separated because its entrypoint
  passes environment-derived settings through `xargs`.
- Dovecot provides IMAP/IMAPS, SASL and LMTP services. It authenticates through
  LDAP and proxies/reads mailbox state according to the checked-in storage
  configuration.
- Rspamd provides proxy, normal-worker and controller ports and uses the
  site-local, TLS-enabled Dragonfly endpoint when Redis support is enabled.
  The container is pinned to the official Rspamd `4.2.3` multi-platform
  manifest digest; review the [Rspamd 4.2.3 release notes](https://github.com/rspamd/rspamd/releases/tag/4.2.3)
  before changing that pin.
  `rspamd.redis.enabled` defaults to `false`; enabling it renders the
  Dragonfly ExternalSecret and Redis mount, and enables Redis-backed Bayes,
  MX-check, URL-reputation and URL-tag features. With the default, those
  Redis-backed features are disabled and the Dragonfly credential is not
  fetched by this chart. Rspamd worker overrides mount under `override.d/`,
  and module settings mount individually under `local.d/`, preserving the
  packaged configuration tree. When Redis is disabled, the Bayes symbols are
  disabled through the statistics group so Rspamd skips the Redis-backed
  classifier.
- Maddy provides an additional internal IMAP service. Its current CoRE `User`
  claim provisions the site-local PostgreSQL role/database and `mail-main` S3
  bucket plus a long-lived MinIO service account; the resulting connection
  Secrets are mounted directly by the Deployment.
- A hub-only `DKIMKey` drives dkim-manager for the `selector1` private key and
  its public DNS record. The generated private-key Secret is pushed to
  `Mail/Clusters/<hubCluster>/DKIM/selector1`; spokes use an `ExternalSecret`
  to recreate `selector1-mail-myloginspace` with the exact key filename used
  by Postfix, Dovecot and Rspamd. The chart-level optional `DNSEndpoint`
  publishes the mail MX records when `dns.automagic.enabled` is true; it is
  currently false.
- `CiliumEgressGatewayPolicy` controls mail egress identity. Changes can affect
  deliverability, SPF alignment and provider reputation.
- SimpleLogin resources include API/mail-handler Deployments, PostgreSQL
  secrets, a PVC, HTTPRoute and service identity, all gated by
  `simplelogin.enabled`; the current value is false.

## Network endpoints

Postfix and Dovecot use PureLB annotations, share the `mail.mylogin.space`
service group and request the checked-in public address. Postfix exposes ports
25, 465, 587 and 10025; Dovecot exposes 143, 993, 12345 and 2525. Rspamd and
Maddy publish internal DNS names.

Treat changes to the public address, service annotations, external DNS, MX,
PTR/rDNS, SPF, DKIM, DMARC, TLS or egress selection as one coordinated mail
delivery change. Validate inbound and outbound traffic before and after sync.

## Identity, secrets and data

- LDAP bind material for Postfix and Dovecot is rendered by External Secrets
  from `mainvault-core`, while their endpoint is the site-local LDAP service.
- CoRE `User` resources create the Postfix, Maddy and optional SimpleLogin
  identities. Maddy uses the current `psql` and `s3` fields from the
  [`mylogin.space` User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
- `credentialsSync.hubCluster` selects the credential hub. Only that cluster
  renders the Postfix, Maddy and optional SimpleLogin `User` claims. It pushes
  their generated PostgreSQL and S3 connection fields through External Secrets
  to `Mail/Clusters/<hubCluster>/...` in the configured
  `ClusterSecretStore`. Every other cluster pulls from that selected hub path
  and recreates the Secret names expected by its local workloads. Cluster
  identity defaults to the `<cluster>-business-mail` release-name convention;
  set `cluster.name` explicitly if the owning ApplicationSet changes it.
- Pushes use `deletionPolicy: None`; spoke targets use `creationPolicy: Orphan`
  and `deletionPolicy: Retain`. Removing the chart therefore does not revoke
  the Vault records or the last spoke copy. Decommissioning requires deliberate
  removal or rotation of both. LDAP bind, Dragonfly and TLS secrets stay in
  their existing platform-owned flows; the generated DKIM private key follows
  this hub/spoke synchronization mechanism.
- The [PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
  defines the hub/standby topology and site-local endpoints used by all three
  Mail targets.
  The [Dragonfly ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Dragonfly/CoRE.yaml)
  supplies the corresponding TLS endpoint and platform-managed password. The
  [storage base ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Base.yaml)
  supplies the site's underlying storage configuration.
- TLS uses the `myloginspace-default-certificates` Secret by default.
- DKIM private keys are sensitive even when generated by a controller; never
  expose them in rendered output or incident transcripts.
- Mailbox/object/database state is external to several stateless Deployments.
  Document and test restores for each data store before treating pod recreation
  as recovery.

## Authentik group aliases

Authentik is the source of truth for public group addresses. Set each group's
multi-valued `mailacceptinggeneralid` attribute to the complete addresses it
owns. The checked-in `AVoIP Admins` configuration declares `voip@snd.fyi`; that
is desired configuration, not a live lookup result. After deployment, confirm
it with the `postmap` command below before treating it as a working alias. A
group may declare several addresses as separate values:

```json
{
  "mailacceptinggeneralid": [
    "voip@snd.fyi",
    "voip@resolvemy.host",
    "voip@writemy.codes"
  ]
}
```

Authentik's [LDAP Provider](https://version-2025-8.goauthentik.io/add-secure-apps/providers/ldap/)
exposes group `member` values as member DNs and group custom attributes as LDAP
attributes.
Postfix searches for an exact address match, follows each `member` DN, and
returns only the member entry's `mail` attribute. It does not synthesize
addresses from CNs or usernames. Multiple group members expand to their
respective primary `@mail.mylogin.space` destinations. The map does not filter
leaf users by `ak-active`; an inactive account that remains a group member and
still has a `mail` attribute can therefore be returned. Remove inactive users
from the Authentik group. A member without `mail` contributes no destination;
unresolvable LDAP member DNs do not produce synthesized addresses and must be
checked in the Outpost and directory logs.

To add another public alias domain, add it to `email.aliasDomains` in
`Mail/values.yaml`, configure its MX records to the mail service, and add
individual addresses to Authentik groups' `mailacceptinggeneralid` lists.
Removing a domain requires removing its value and reviewing DNS and group
attributes in the same change. An address is accepted only when the LDAP group
lookup returns at least one member `mail` value; unknown addresses, empty
groups and members without `mail` do not become catch-all recipients. SMTP
sender authorization is separate: `ldap-auth.cf` maps active user accounts,
and accepting a group alias does not authorize sending as that group.

The previous `ldap-relay.cf` lookup was wired to Postfix `relay_domains`,
which classifies destinations for onward relaying; it did not expand recipients
to member mailboxes. It returned group CNs and could not enforce exact alias
recipient existence. This chart removes that misapplied relay map; alias
expansion uses `ldap.cf`, while `ldap-in.cf` checks primary mailbox addresses
and `ldap-auth.cf` checks authenticated sender identities. These public alias
domains do not belong in `relay_domains`.

### Lookup and delivery checks

Run these inside a Postfix pod after the Secret and chart have reconciled. The
LDAP map output contains recipient addresses, so keep it out of public logs and
tickets:

```sh
postmap -q 'voip@snd.fyi' ldap:/etc/postfix/ldap.cf
postmap -q 'voip@resolvemy.host' ldap:/etc/postfix/ldap.cf
postmap -q 'voip@writemy.codes' ldap:/etc/postfix/ldap.cf
postmap -q 'august@mail.mylogin.space' ldap:/etc/postfix/ldap-in.cf
postconf -h virtual_alias_domains
postconf -h virtual_mailbox_domains
postconf -h virtual_alias_maps
postconf -h virtual_mailbox_maps
postconf -h virtual_transport
postconf -h smtpd_relay_restrictions
postfix check
```

The alias lookup should return the member's primary mail address, while the
mailbox lookup should recognize an active mailbox. Repeat the alias lookup for
the other configured domains and use an unknown local part, unrelated domain,
group without mail-bearing members and inactive member as negative cases. The
SMTP test should reject unknown recipients and preserve
`reject_unauth_destination`; never treat a `postmap` result alone as proof of
end-to-end delivery.

If SMTP returns `554 5.7.1 Relay access denied` for a configured alias, confirm
that its domain is in `email.aliasDomains`, the rendered
`virtual_alias_domains` contains it, and the matching Authentik group address
is visible to the LDAP Outpost. If a group alias lookup is empty, inspect the
exact `mailacceptinggeneralid` value, group membership DNs, member `mail`
attributes and LDAP bind connectivity. Do not add broad recipient permits or
a wildcard alias to work around a missing LDAP result.

Deploy through the owning Mail ApplicationSet and a scoped Argo CD
refresh/sync. Check all three production targets, then validate Postfix
parameters, recipient rejection, Rspamd, SASL and LMTP delivery. Roll back by
reverting the specific Git commit and reconciling the same Mail applications;
the change does not alter mailbox data or DNS resources. Manage public DNS
records separately and remove them only after the domain is no longer accepted.

## Safety and current limitations

- The ApplicationSet resolves each target's Kubernetes API URL from its Argo CD
  cluster registration and follows `HEAD`. Confirm all selected targets before
  reconciliation and avoid broad fleet resyncs during mail delivery incidents.
- Public address, PureLB sharing, Cilium egress, DNS and mail identity settings
  remain common chart inputs. Verify that their behavior is correct at every
  site; scaling pods successfully does not establish correct inbound routing,
  outbound identity or mail reputation.
- Some images remain mutable or locally maintained, including untagged
  Rspamd. Postfix is pinned to the inspected `core` image digest in
  `Mail/templates/common.yaml`.
- Maddy and Dovecot overlap on IMAP responsibilities. Determine the live client
  and storage path before removing either implementation.
- DNS automation and SimpleLogin are disabled, but their manifests remain part
  of the chart's maintenance surface.
- Mail reputation and queued messages can be damaged by repeated retries,
  address changes or incomplete rollback. Inspect queues and controller state
  before restarting transports.

## Validation

```sh
helm dependency build Mail
helm lint Mail \
  --set cluster.name=dc1-k3s-node1
helm template dc1-k3s-node1-business-mail Mail \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  --set cluster.name=dc1-k3s-node1 \
  >/tmp/core-business-mail-hub.yaml
helm template core-dc1-talos-prod-business-mail Mail \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  --set cluster.name=core-dc1-talos-prod \
  >/tmp/core-business-mail-spoke.yaml
git diff --check -- Mail
```

Inspect the render for credentials, public IPs, TLS Secret references, egress
selectors, enabled optional resources and generated DNS/DKIM objects. Validate
the installed CRDs for External Secrets, Cilium, external-dns, dkim-manager and
the CoRE `User` API. The default hub render must contain one `DKIMKey`, four
`PushSecret` resources and two `User` claims; a spoke must contain four
`ExternalSecret` pull resources, no `DKIMKey` and no `User` claims. With
SimpleLogin enabled, the Push/pull and User counts each increase by one. Confirm both renders use
the same `Mail/Clusters/<hubCluster>/...` remote keys, resolve to their own
local Secret names, and contain no Secret data.

The default values represent `dc1-k3s-node1` in `dc1/yxl`; they are not a
representative fleet render. The owning ApplicationSet overrides `clusterDNS`,
`site.ldap`, `site.psql`, `site.dragonfly` and `site.s3` for every target. Keep
those values together when adding a site, render once per target, and keep
Dragonfly logical database `25` reserved for Rspamd at each site.

After reconciliation, verify at each site and then test cross-site behavior:

1. SMTP banner, STARTTLS and certificate chain on ports 25/587.
2. Authenticated submission and IMAP login through a non-privileged test user.
3. Inbound delivery, mailbox visibility and outbound delivery to an external
   provider.
4. SPF, DKIM and DMARC results plus PTR/rDNS and egress-address consistency.
5. Rspamd filtering, Redis connectivity and queue health.
6. Secret-controller, DKIM-controller and DNS-controller conditions.
7. A restore of representative mailbox/object/database state.
8. Site failover and duplicate-delivery behavior, including queue handling and
   preservation of a single consistent public SMTP identity.

## Upstream projects

- [Postfix website](https://www.postfix.org/) and [documentation](https://www.postfix.org/documentation.html)
- [Postfix LDAP table documentation](https://www.postfix.org/ldap_table.5.html) and [LDAP address expansion examples](https://www.postfix.org/LDAP_README.html)
- [Authentik LDAP Provider documentation](https://docs.goauthentik.io/add-secure-apps/providers/ldap/)
- [Postfix Exporter source and options](https://github.com/Hsn723/postfix_exporter)
- [Dovecot website](https://www.dovecot.org/) and [documentation](https://doc.dovecot.org/latest/)
- [Rspamd website](https://rspamd.com/) and [documentation](https://docs.rspamd.com/)
- [Maddy website and documentation](https://maddy.email/) and [source](https://github.com/foxcpp/maddy)
- [SimpleLogin website](https://simplelogin.io/), [documentation](https://simplelogin.io/docs/) and [server source](https://github.com/simple-login/app)
- [dkim-manager source and chart documentation](https://github.com/hsn723/dkim-manager)
- [Cilium egress gateway documentation](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)
- [ExternalDNS documentation](https://kubernetes-sigs.github.io/external-dns/)
- [External Secrets documentation](https://external-secrets.io/)
- [BJW-S common library documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
