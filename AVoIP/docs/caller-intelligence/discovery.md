# Repository discovery and reusable components

Inspected 2026-10-18. This is a source inspection, not a live cluster inventory.
The user's production context reports multiple replicas. Current Backplane
source independently declares three carrier replicas at YVR and YXL; running
replica health, installed modules and failover were not checked in this task.

## Repositories and evidence

| Repository | Inspected revision | Finding |
| --- | --- | --- |
| [CoRE-Business](https://slop.writemy.codes/CoRE/CoRE-Business) | `885b106e1f594df4acb76f0035e44540909fa0fa` | Active implementation under `AVoIP/`; shared checkout also contains unrelated work in progress, excluded from this change |
| [CoRE-Backplane](https://slop.writemy.codes/CoRE/CoRE-Backplane) | `04fdf818501305364cc02f449363cdd984776e1a` | Fresh shallow clone from Forgejo; owns fleet selection, injected values, storage and identity |
| [CoRE-AVoIP](https://slop.writemy.codes/CoRE/CoRE-AVoIP) | `a3a19e30124effc0b38591663e004a2e9baa3d8291f6a3e162cc1ec5b306a38f` | Exists; tree contains only `README.md`, despite its description referring to extraction; no application implementation to reuse |

The active [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
still selects `AVoIP` in CoRE-Business, revision `HEAD`, using
`argocd-lovely-plugin`, with `LOVELY_HELM_MERGE`. Its merge generator combines
site entries and cluster registrations for tenant `core.mylogin.space`,
environment `prod`. Destination is `core-prod`. Listed targets are
`core-dc1-talos-prod` (YXL/DC1), `core-home1-talos-prod` (YVR/Home1) and
`dc1-k3s-node1`; telephony workloads are enabled on the first two. The ApplicationSet
preserves resources on deletion. A missing/changed generator entry is not a
safe cleanup mechanism.

## Actual CoRE-Business paths inspected

| Paths | Evidence and reuse |
| --- | --- |
| `AGENTS.md`, `README.md`, `docs/REPOSITORY.md`, `docs/PHONE-NUMBER-GUARD.md` | Site-specific GitOps, documentation and privacy conventions; hooks stay enabled |
| `AVoIP/README.md`, `AVoIP/TODO.md`, `AVoIP/Chart.yaml`, `AVoIP/values.yaml`, `AVoIP/kustomization.yaml`, `AVoIP/patches/` | Combined Helm/Kustomize rendering unit; BJW-S common 5.0.1, site values and rollout patches |
| `AVoIP/templates/Kamailio/KamailioConfig.yaml`, `_instances.tpl`, `_sip-functions.tpl`, `_sip-private.tpl`, `_sip-outbound.tpl`, `ToposRedis.yaml`, `PrivateCiliumPolicy.yaml` | Generated per-role config, carrier source classification, transactions, dialogs, topology, private routing, existing Redis use and network boundaries |
| `AVoIP/image/kamailio-lf-heartbeat/Containerfile` | Digest-pinned 6.1.4 source/build; explicit compiled modules include `tm`, `ndb_redis`, `topos_redis`, `siptrace`; proposed classification modules are not in this explicit list |
| `AVoIP/templates/FreeSwitch/FreeSwitchDialplanConfig.yaml`, `_inbound-bridge.tpl`, `FreeSwitchSIPConfig.yaml` | Existing IVR and bridges must retain their routing and cancellation behavior |
| `AVoIP/templates/Asterisk/AsteriskConfigTemplate.yaml`, `AsteriskConfigs.yaml`, `AsteriskUser.yaml`, `AsteriskVoicemailSecret.yaml` | Existing application identity, configuration generation, extension/voicemail boundaries |
| `AVoIP/templates/RTPEngine/Valkey.yaml`, `AVoIP/templates/Homer/`, `AVoIP/templates/Authentik/AVoIPGroups.yaml` | Separate media persistence, trace UI/access patterns and AVoIP groups |
| `AVoIP/image/flowroute-sms/go.mod`, `main.go`, `web/`; `AVoIP/templates/SMS/` | Existing Go HTTP/pgx application and Authentik UI patterns; reusable engineering conventions, not a caller-classification API |
| `AVoIP/docs/avoip/architecture.md`, `sip-border.md`, `failure-domains.md`, `topology-hiding.md`, `rtpengine-ha.md` | Existing architecture location and SIP/media failure boundaries |
| `AVoIP/docs/SIP-ROUTING-ARCHITECTURE.md`, `SIP-STATEFUL-HA.md`, `SIP-IDENTITY.md`, `KAMAILIO-VALUES.md`, `INTERNAL-REGISTRAR.md` | Current routing and separately proposed registrar/directory work; do not treat plans as deployed |
| `AVoIP/docs/PHONE-TREE.md`, `VOICEMAIL.md`, `FLOWROUTE-SMS.md`, `HOMER.md`, `NETWORKING.md`, `INTERSITE-VOICE.md`, `SIPCORE-DTMF.md`, `SIPCORE-REMOTE-HANGUP.md` | Regression baselines and existing integrations; unrelated local document changes are not republished |
| `.forgejo/workflows/`, `.githooks/`, `AVoIP/tests/README.md` | Image workflows use path filters; documentation changes do not request image builds |

No Caller Intelligence service, provider ledger, policy schema or API was found
in this rendering unit. The SMS Go module currently uses Go 1.25 and pgx/v5;
that is a precedent, not a prescribed new dependency version.

## Backplane paths inspected

All links below refer to actual paths in the fetched tree:

- [Architecture](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/docs/ARCHITECTURE.md),
  [operations procedure](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/docs/OPERATIONS.md#agent-git-and-argo-cd-procedure),
  [network overview](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Network/README.md)
  and [lab VMs](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Lab/VMs/README.md)
  establish platform boundaries; no VM is needed for this proposed service.
- The [storage base ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Base.yaml)
  targets Longhorn in `longhorn-system` and configures local/peer backups. The
  [PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
  renders `Databases/PSQL` into site `core-prod`, declares YVR as hub with three
  replicas and YXL with one, and injects pooler peer endpoints. This does not
  establish cross-site synchronous consistency for a new application.
- The [Dragonfly ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Dragonfly/CoRE.yaml)
  and [allocation registry](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Storage/Dragonfly/CoRE/README.md)
  define site-local TLS cache services and numeric databases. Existing TOPOS
  allocations 51/52/53 and mail Rspamd allocation 25 are not available for this
  application. Numeric databases are not credential isolation. The registry
  and local values can drift (for example other consumers use 155); re-audit
  all consumers before assigning any apparently unused number.
- The [User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml),
  [Composition](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserComposition.yaml)
  and [User platform guide](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/README.md)
  support Authentik service identity and optional PostgreSQL/S3 provisioning,
  with stable connection secrets. MySQL/MongoDB schema acceptance does not
  imply provisioning. Existing orphan policies require lifecycle review.
- [Lovely plugin configuration](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/ArgoCD/argocd-lovely-plugin.yaml)
  references `lovely-vault-plugin:1.2.5`. Inspect the deployed image/tooling again
  before implementing renderer features; no plugin execution was needed here.
- [Observability overview](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Observability/README.md),
  chart trees `Observability/{Collectors,Metrics,Logs,Traces}` and their fleet
  entries establish proposed telemetry integration points. See
  [observability design](security-observability.md) for exact owner links.

## Preserved call baseline

[Phone tree](../PHONE-TREE.md) currently routes YXL voice over authenticated
inter-site signaling to YVR ingress 7102, and the legacy FaxNumber DIDs to
YVR Asterisk 7101. A field named FaxNumber is not proof of an active fax receiver.
YVR uses a silent digit collector, then allowlisted Asterisk destinations.
Registered contacts, voicemail fallback and its PostgreSQL audio storage are
existing features, independent of the proposed policy engine. SMS is a
separate HTTP/PostgreSQL flow and must not inherit inbound voice rules.

The carrier source IP identifies a carrier SBC. It is useful for ingress
validation and overload control, not caller business identity or location.
No production numbers, secrets, private provider account configuration or
live SIP payloads are recorded in this package.
