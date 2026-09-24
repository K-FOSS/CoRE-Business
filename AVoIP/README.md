# AVoIP

This chart is the desired state for the legacy AVoIP stack in `core-prod`. It
contains optional Asterisk and FreeSWITCH workloads plus an optional Jitsi Meet
dependency. Speech recognition and synthesis are provided by the existing
[CoRE AI stack](https://github.com/K-FOSS/CoRE-Business/tree/main/AI), not by
workloads duplicated in this chart. It does not currently expose a public HTTP
route from this chart.

## Deployment ownership

The owner is the [legacy AVoIP ApplicationSet in CoRE-Backplane](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml).
Its current desired state uses a merged generator for three production
clusters: `core-dc1-talos-prod`, `core-home1-talos-prod`, and
`dc1-k3s-node1`. It deploys the `AVoIP` path from the
[CoRE-Business source repository](https://slop.writemy.codes/CoRE/CoRE-Business), targets
`core-prod`, and renders through the
[Argo CD Lovely plugin](https://github.com/crumbhole/argocd-lovely-plugin).

The [owning ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
uses `targetRevision: HEAD`, enables `CreateNamespace=true` and
`ServerSideApply=true`, and injects the following Helm merge values:

- `env`, `datacenter`, `region`, and `cluster` identity/type/domain metadata.
- `asterisk.enabled`, `freeswitch.enabled`, and FreeSWITCH public exposure per
  cluster.
- `hub` metadata for spoke clusters.
- `gateway.name`, `gateway.namespace`, and `gateway.sectionName`.
- `jitsi.domain` and `jitsi.tls.secretName`.

The current component matrix is:

| Cluster | Role | Asterisk | FreeSWITCH |
| --- | --- | --- | --- |
| `core-dc1-talos-prod` | Hub | Enabled | Enabled |
| `core-home1-talos-prod` | Spoke | Disabled | Disabled |
| `dc1-k3s-node1` | Spoke | Disabled | Disabled |

The chart’s top-level `values.yaml` contains the same single-cluster defaults
for standalone rendering, with both telephony components disabled. The
current [owning ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml)
overrides those flags only for the hub. Lovely-injected values take precedence
for each selected cluster. The live `dc1-k3s` controller is stale: it still
has the older single-cluster ApplicationSet and the application was last
observed at revision `f043ea6e783e1655db2a1456ad2a2c5b575479cf`, with Argo
reporting `Synced` and `Healthy` on 2026-06-11. Its old speech resources remain
pending the newer ApplicationSet/chart reconciliation.

The deployed FreeSWITCH image is built by the site-local
[Core-Docker Forgejo project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker)
from its [FreeSWITCH image definition](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker/src/branch/main/Images/FreeSwitch)
and consumed from the Forgejo container registry. The chart pins an immutable
Forgejo build tag rather than the moving Docker Hub `latest` image.

The mirrored `gateway` and `jitsi` values document the current merge contract.
The existing SIP routes still use their dedicated SIP Gateway sections, and
the chart’s Jitsi dependency still receives its detailed settings under
`jitsi-meet`; neither path should be assumed to consume the generic merge
metadata until its templates are changed.

## Chart state

The complete current DID flow, SIP messaging path, registration behavior, and
operational caveats are documented in [docs/PHONE-TREE.md](docs/PHONE-TREE.md).
Inbound external SIP is restricted by the Flowroute signaling CIDRs configured
under `freeswitch.flowroute.signalingCIDRs`; the public DID route does not
accept arbitrary Internet SIP sources.

The Asterisk and FreeSWITCH Deployments and Services are rendered through the
pinned [BJW-S common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
`5.0.1`, following the workload pattern used by the repository's AI stack.
The chart keeps the existing AVoIP resource names and selectors so the
migration does not create a second telephony stack. ConfigMaps, External
Secrets, SSO `User` claims, Cilium egress policy, and Gateway API routes remain
local templates because they are application-specific or operator-specific
resources not provided by the common chart.

Both voice controllers use surge-first `RollingUpdate` settings with one extra
pod allowed and zero unavailable replicas. Asterisk uses its local CLI uptime
check for startup, readiness, and liveness; FreeSWITCH uses a non-network
process/configuration check because its event socket is not enabled. Each
controller must pass startup and readiness before the old replica is removed.

The chart defaults are intentionally mostly inactive:

| Component | Chart behavior | User/API resources |
| --- | --- | --- |
| Speech recognition/synthesis | External dependency | Use Wyoming from the AI stack as the protocol adapter: TTS is backed by GPUStack and STT by Speaches. |
| Asterisk | Disabled | When enabled, creates a rootless UID/GID 1000 workload with a service identity and ConfigMap-backed SIP configuration. Its generated User credentials are mounted only at runtime and used to authenticate the Asterisk peer to FreeSWITCH. Unused Asterisk LDAP/PostgreSQL realtime, phone provisioning, audio hardware, music-on-hold, CDR/CEL, and IAX2 modules are disabled; LDAP remains a FreeSWITCH internal-peer concern. |
| FreeSWITCH | Disabled | When enabled, creates internal SIP services and External Secret-backed configuration. The configured DID currently receives fax with SpanDSP/T.38 into an ephemeral TIFF spool. Public RTP uses a PureLB LoadBalancer with the requested `freeswitch.publicExposure.address`; public SIP/TCP/UDP remains disabled unless `freeswitch.publicExposure.sip.enabled` is explicitly enabled, while the TLS route remains available. |
| Jitsi Meet | Disabled | Pinned dependency `jitsi-meet` `1.2.2`; no Jitsi resources render by default. |

The Asterisk and FreeSWITCH `User` claims use the current supported claim
shape: `spec.name`, `spec.groups`, `spec.serviceAccount`, and
`spec.writeConnectionSecretToRef`. The explicit `serviceAccount: true` records
the intended service identity, although the current SSO Composition still
hardcodes service-account creation. The current
[User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
also exposes `psql`, `s3`, `mysql`, `mongodb`, `email`, `username`, and
`AVoIP` fields. The current
[User Composition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserComposition.yaml)
does not consume `AVoIP`, `mysql`, or `mongodb`; this chart does not set those
fields.

When both voice services are enabled, FreeSWITCH authenticates the internal
Asterisk peer against the LDAP-backed directory using the username/password
from Asterisk's generated User connection Secret. The Asterisk container
creates its local PJSIP auth object at startup from mounted Secret files; the
credentials are not present in the chart ConfigMap or Helm values. FreeSWITCH
keeps Flowroute inbound traffic on its separate source-ACL-protected external
profile, so carrier ingress does not bypass application authentication. See
[PHONE-TREE.md](docs/PHONE-TREE.md) for the call paths and verification checks.

## Live `dc1-k3s` snapshot

The following is a non-secret inventory captured from the live cluster. Secret
objects, secret data, environment values sourced from Secrets, and generated
credentials are deliberately excluded.

The active Argo application is
`dc1-k3s-node1-business-avoip` in `argocd`, targeting `core-prod`. Its complete
resource inventory is only:

- Deployment `dc1-k3s-node1-business-avoip-avoip-vosk`, `0` replicas,
  image `alphacep/kaldi-en:latest`, container HTTP port `2700`.
- Service `dc1-k3s-node1-business-avoip-avoip-vosk`, ClusterIP, TCP and UDP
  port `5060`, both targeting the container ports named `tcp-sip` and
  `udp-sip`.
- Deployment `dc1-k3s-node1-business-avoip-avoip-mycroft-mimic`, `0` replicas,
  image `smartgic/ovos-tts-server-bark:alpha`, container HTTP port `9666`, and
  an `emptyDir` mounted at `/home/mimic3/.local`.
- Service `dc1-k3s-node1-business-avoip-avoip-mycroft-mimic`, ClusterIP port
  `80` targeting the `http` port.

No Asterisk, FreeSWITCH, Jitsi, `User`, HTTPRoute, TCPRoute, UDPRoute, or
TLSRoute resource is currently part of this Argo application. The live speech
resources are scaled to zero, matching the chart’s replica settings.

These speech resources are legacy remnants. The chart no longer renders them;
the next Argo reconciliation will prune them. Until that reconciliation, they
remain visible in the live snapshot above and must not be treated as supported
speech backends.

## Speech architecture and TODOs

The replacement speech path is the deployed AI stack:

- The [AI ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/AI.yaml)
  renders the shared AI services, including Wyoming, GPUStack, and Speaches.
- Wyoming is the protocol adapter on TCP `10300`. Its TTS OpenAI-compatible
  endpoint is GPUStack at `https://gpustack.mylogin.space/v1`, using
  `CoRE-AI-TTS`.
- Wyoming’s STT OpenAI-compatible endpoint is
  `https://stt.int.mylogin.space/v1`, backed by Speaches with
  `Systran/faster-whisper-small`. Speaches has CPU and CUDA backends in the AI
  chart; AVoIP must not create another Vosk or TTS deployment.
- The [AI chart documentation](https://github.com/K-FOSS/CoRE-Business/blob/main/AI/README.md)
  describes the current GPUStack, Speaches, Gateway, and Wyoming deployment.

Remaining integration work is to connect the minimal FreeSWITCH DID service to
the existing Wyoming endpoint (or an OpenAI-compatible speech bridge) if voice
TTS/STT is needed. This chart does not currently ship an IVR or speech bridge;
its old Vosk and Mycroft resources have been removed.

## Documented chart/live differences

These differences are intentional or unresolved and should be reviewed before
activating a component:

1. The legacy live Vosk Service exposes TCP/UDP SIP port `5060` and targets port
   names that do not exist on the Vosk Deployment. The Deployment exposes only
   HTTP port `2700`. Because replicas are zero and Vosk is being retired, no
   repair is planned; the Service will be pruned on reconciliation.
2. The legacy live Vosk image is the mutable `alphacep/kaldi-en:latest` tag;
   it is being retired rather than pinned or reactivated.
3. The legacy live OVOS TTS Deployment has `imagePullPolicy: Always`; it is
   also being retired rather than reconciled back into this chart.
4. The live application is rendered from an older revision of the [legacy ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Legacy/AVoIP.yaml), while the current desired ApplicationSet is multi-cluster and injects Helm values. Compare the rendered Lovely output after every chart change; standalone `helm template` is only a partial check for this deployment.

## Validation and activation notes

Run `helm dependency build .` to resolve the pinned local dependency, then run
`helm lint .`. For representative standalone checks, render once with the
`dc1-k3s-node1` defaults and once with the injected `cluster`, `hub`,
`gateway`, and `jitsi` values. Before activating Jitsi, render through the
same Lovely pipeline used by the owning ApplicationSet.

Before enabling Asterisk or FreeSWITCH, inspect the chart’s External Secret
references and the cluster’s SecretStore configuration. Asterisk's static
PJSIP configuration is a ConfigMap; only its generated `User` connection
Secret contains runtime credentials. Do not put credentials or generated
Secret data in this repository. Verify the resulting `User`, its `XUser`, the
claim connection Secret key names, and downstream provider conditions. The
current SSO platform documentation is the authoritative guide
for this workflow: [User platform APIs](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/README.md).

Principal upstream projects:

- [Asterisk](https://www.asterisk.org/) and its
  [documentation](https://docs.asterisk.org/)
- The deployed Asterisk image is the pinned `core-docker/asterisk:20` package
  from the site-local [Core-Docker project](https://forge.core-dc1-talos-prod.dc1.yxl.writemy.codes/CoRE/Core-Docker),
  built from the upstream [andrius/asterisk image source](https://github.com/andrius/asterisk).
  The digest is maintained in `values.yaml`; backups are maintained at
  [GitHub](https://github.com/K-FOSS/Core-Docker) and
  [slop.writemy.codes](https://slop.writemy.codes/CoRE/Core-Docker).
- [FreeSWITCH](https://signalwire.com/freeswitch) and its
  [source repository](https://github.com/signalwire/freeswitch)
- [Wyoming OpenAI adapter](https://github.com/roryeckel/wyoming_openai)
- [GPUStack website](https://gpustack.ai/) and
  [documentation](https://docs.gpustack.ai/)
- [Speaches website and documentation](https://speaches.ai/) and
  [source repository](https://github.com/speaches-ai/speaches)
- [Jitsi Meet](https://jitsi.org/) and the
  [Jitsi Helm chart](https://github.com/jitsi-contrib/jitsi-helm)
