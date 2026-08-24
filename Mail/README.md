# CoRE Mail

CoRE Mail is a site-specific mail transport, filtering and mailbox stack. It
combines Postfix, Dovecot, Rspamd, Maddy, DKIM/DNS resources, platform identity
and secret synchronization. An optional SimpleLogin alias service is present
but disabled by default.

## Deployment status and ownership

[The Mail ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Mail.yaml)
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
  LDAP and database-backed routing/authentication.
- Dovecot provides IMAP/IMAPS, SASL and LMTP services. It authenticates through
  LDAP and proxies/reads mailbox state according to the checked-in storage
  configuration.
- Rspamd provides proxy, normal-worker and controller ports and uses the
  site-local, TLS-enabled Dragonfly endpoint. An ExternalSecret renders its
  password-bearing `redis.conf` from the platform credential without placing
  the password in Git.
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
  [`mylogin.space` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).
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
- The [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
  defines the hub/standby topology and site-local endpoints used by all three
  Mail targets.
  The [Dragonfly ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Dragonfly/CoRE.yaml)
  supplies the corresponding TLS endpoint and platform-managed password. The
  [storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
  supplies the site's underlying storage configuration.
- TLS uses the `myloginspace-default-certificates` Secret by default.
- DKIM private keys are sensitive even when generated by a controller; never
  expose them in rendered output or incident transcripts.
- Mailbox/object/database state is external to several stateless Deployments.
  Document and test restores for each data store before treating pod recreation
  as recovery.

## Safety and current limitations

- The ApplicationSet resolves each target's Kubernetes API URL from its Argo CD
  cluster registration and follows `HEAD`. Confirm all selected targets before
  reconciliation and avoid broad fleet resyncs during mail delivery incidents.
- Public address, PureLB sharing, Cilium egress, DNS and mail identity settings
  remain common chart inputs. Verify that their behavior is correct at every
  site; scaling pods successfully does not establish correct inbound routing,
  outbound identity or mail reputation.
- Some images are mutable or locally maintained, including untagged Rspamd and
  `kristianfoss/postfix:core`. Pin reviewed digests before relying on
  reproducible rollback.
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
- [Dovecot website](https://www.dovecot.org/) and [documentation](https://doc.dovecot.org/latest/)
- [Rspamd website](https://rspamd.com/) and [documentation](https://docs.rspamd.com/)
- [Maddy website and documentation](https://maddy.email/) and [source](https://github.com/foxcpp/maddy)
- [SimpleLogin website](https://simplelogin.io/), [documentation](https://simplelogin.io/docs/) and [server source](https://github.com/simple-login/app)
- [dkim-manager source and chart documentation](https://github.com/hsn723/dkim-manager)
- [Cilium egress gateway documentation](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)
- [ExternalDNS documentation](https://kubernetes-sigs.github.io/external-dns/)
- [External Secrets documentation](https://external-secrets.io/)
- [BJW-S common library documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
