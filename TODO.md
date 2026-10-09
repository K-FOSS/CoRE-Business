# CoRE-Business portfolio implementation backlog

**Baseline: 2026-10-09.** This is the executive backlog, not a list of every
component task. Component trackers own detailed implementation status and
acceptance evidence; root milestone IDs are stable cross-project references.
Nothing here is complete because code renders or an ApplicationSet exists.

## Priority and status key

- **P0:** operational correctness, security, blocking defects and prerequisites.
- **P1:** selected foundational architecture and current delivery priorities.
- **P2:** major capability expansions.
- **P3:** exploratory or long-term initiatives.
- **Status:** Implemented — repository verified; Deployed — evidence verified;
  Reported working; Partial; Planned; Proposed; Research; Blocked; Deferred;
  Retired/Superseded. “Deployment configured” is descriptive evidence, not a
  replacement status or live-health claim.

Detailed AI status is in [AI/TODO.md](AI/TODO.md). AVoIP SIP phases and
acceptance rows remain in [AVoIP/TODO.md](AVoIP/TODO.md), with architecture in
[SIP-STATEFUL-HA.md](AVoIP/docs/SIP-STATEFUL-HA.md). Update those authoritative
ledgers when work begins; do not clone their rows here.

## P0 — Baseline, safety and operational correctness

### CORE-001 — Reconcile portfolio inventory and deployment evidence

- **Status:** Partial
- **Owner:** CoRE-Business with each Backplane ApplicationSet owner
- **Depends on:** Read-only cluster access; current Backplane owner inventory
- **Current state:** Application code and active ApplicationSets are documented,
  but this planning pass did not inspect live application health. Root and
  component READMEs contain some defaults/config claims that may not match
  injected values.
- **Next action:** Build a dated inventory for selected services: owning
  ApplicationSet, target cluster/namespace, Lovely merge values, rendered
  image digests, operator conditions, routes, dependencies, backup and
  user-flow evidence.
- **Acceptance:** Every portfolio status distinguishes repository code,
  deployment configuration, operator observation, operator-reported outcome
  and user-flow acceptance. Contradictions have owners and follow-up IDs.
- **Failure / rollback:** Inventory is read-only; redact private endpoints and
  secrets. If data cannot be verified, retain Partial/Research status and
  publish the evidence gap rather than inferring health.
- **Evidence:** `README.md`, `docs/REPOSITORY.md`, current Business ApplicationSets.
- **Details:** [repository guide](docs/REPOSITORY.md)

### CORE-002 — Reconcile stale AI deployment claims

- **Status:** Partial
- **Priority:** P0
- **Owner:** CoRE-Business/AI and AI ApplicationSet owner
- **Depends on:** CORE-001; effective Lovely render for AI and AINode2
- **Current state:** `AI/README.md` and checked-in `AI/values.yaml` disagree on
  Speaches image tags and CPU/CUDA traffic weights; AINode2 injects LocalAI and
  llama despite local defaults disabling LocalAI.
- **Next action:** Render both current ApplicationSet merge layers and compare
  with live image digests, service endpoints and effective route weights.
- **Acceptance:** The operational README describes verified effective values
  or labels unresolved values clearly; the target clusters and service routes
  are recorded without secret values.
- **Failure / rollback:** Documentation-only correction; retain prior text in
  Git history. Do not adjust operational values as part of this milestone.
- **Evidence:** [AI README](AI/README.md), [AI values](AI/values.yaml),
  [AI owner](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Tools/AI.yaml),
  [AINode2 owner](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/Tools/AINode2.yaml).
- **Details:** [AI phase 0](AI/TODO.md#phase-0--inventory-and-baseline)

### VOICE-000 — Establish voice-AI safety and media baseline

- **Status:** Planned
- **Priority:** P0
- **Owner:** CoRE-Business/AI and AVoIP; Backplane for shared platform evidence
- **Depends on:** CORE-001; existing AVoIP acceptance ledger
- **Current state:** AVoIP tracker records operator-reported long call and
  Home1 G.711 fax milestones. Caller-audio copying and KWS are not implemented.
- **Next action:** Record baseline versions, media path, codecs, RTPEngine
  ownership, call correlation and current privacy/recording behavior. Reconcile
  `internal-websocket` in the fetched AVoIP ApplicationSet against
  `internal-wss` naming in parts of the detailed SIP plan.
- **Acceptance:** Documented caller/recipient audio directions, call-owner
  map, non-blocking and no-persistence requirements, and a reversible lab
  scope; track live call/fax tests in AVoIP's existing table.
- **Failure / rollback:** No runtime change. Stop lab design if the media copy
  cannot be isolated from production forwarding or caller-data policy is
  unresolved.
- **Evidence:** [AVoIP tracker](AVoIP/TODO.md),
  [SIP plan](AVoIP/docs/SIP-STATEFUL-HA.md),
  [AVoIP owner](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).
- **Details:** [AI AVoIP plan](AI/PLAN.md#13-avoip-caller-audio-processing)

### OPS-001 — Define a common service operational baseline

- **Status:** Planned
- **Priority:** P0
- **Owner:** CoRE-Backplane platform operations with application owners
- **Depends on:** Current monitoring/alerting inventory
- **Current state:** Shared monitoring capabilities exist in platform plans;
  app-level SLI, dashboards, alert ownership and restore evidence vary.
- **Next action:** Adopt a short app contract for service owner, metrics/logs,
  traces, dashboards, alerts, runbook, backups and restore test.
- **Acceptance:** AI, AVoIP and one stateful business app demonstrate the
  contract, including a user-flow check and a tested data restore.
- **Failure / rollback:** Do not replace the platform's monitoring stack;
  revise the common contract if it duplicates Backplane collectors.
- **Details:** [portfolio reliability section](PLAN.md#15-security-reliability-ha-and-observability)

## P1 — Selected foundational delivery

### AI-001 — Establish OpenWakeWord inference service

- **Status:** Planned
- **Priority:** P1
- **Owner:** CoRE-Business/AI
- **Depends on:** VOICE-000; authenticated transport contract; CPU capacity;
  model provenance and license review
- **Current state:** No server OpenWakeWord service is present. The user
  reports Hey Jarvis on Home Assistant Voice PE; that is firmware
  `micro_wake_word`, not a server artifact.
- **Next action:** Specify streaming API/auth/session behavior and implement a
  CPU-first service with PCM16 mono 16 kHz, independent session state, model
  discovery, thresholds, cooldowns and metadata-only detection events.
- **Acceptance:** Real approved test audio streams produce versioned,
  timestamped detection events; concurrent streams do not share state; auth,
  malformed frames and saturation are handled; readiness means the model is
  loaded; Prometheus metrics exist; no audio persists by default.
- **Failure / rollback:** Bound queues and drop stale analysis frames; service
  outage never affects phone or HA audio forwarding. Revert route/workload and
  preserve the previous model version.
- **Evidence:** Pending offline and live stream test reports.
- **Details:** [AI phase 1](AI/TODO.md#phase-1--openwakeword-service)

### VOICE-001 — Train and evaluate Hey CoRE for OpenWakeWord

- **Status:** Planned
- **Priority:** P1
- **Owner:** CoRE-Business/AI
- **Depends on:** AI-001 API contract; governed dataset; isolated training
  capacity; immutable artifact storage
- **Current state:** No Hey CoRE trained artifact or dataset is verified.
- **Next action:** Establish speaker-separated positive, hard-negative,
  synthetic, multispeaker and room-noise corpus with telephony augmentation.
- **Acceptance:** Reproducible training output, provenance/license, checksums,
  held-out false accepts/hour, false rejection, latency and CPU/memory report;
  model can be promoted and rolled back independently.
- **Failure / rollback:** Do not promote a model that fails predeclared quality
  gates; retain a prior accepted model and delete test data per retention
  policy.
- **Evidence:** Pending dataset manifest and evaluation report.
- **Details:** [AI phase 3](AI/TODO.md#phase-3--hey-core-openwakeword-training)

### AVOIP-AI-001 — Connect opted-in caller audio to inference

- **Status:** Planned
- **Priority:** P1
- **Owner:** CoRE-Business/AVoIP and AI
- **Depends on:** AI-001; VOICE-000; RTPEngine directional subscription
  proof; PCM adapter; authenticated controller; FreeSWITCH call ownership
- **Current state:** Kamailio uses RTPEngine for standard media relay; no KWS
  fork/adapter or AI-authorized call action is evidenced.
- **Next action:** Prove a lab-only caller-direction stream from one opted-in
  call, then define event correlation and execution API for the owning
  FreeSWITCH worker.
- **Acceptance:** “Hey CoRE” from caller-only PCM generates one valid event;
  an authorized, deduplicated controller action mixes GG to internal 7102;
  normal RTP continues; no raw audio is stored; hangup stops processing; AI
  or controller failure does not terminate or modify the call.
- **Failure / rollback:** Feature disabled by default and per call. On any
  adapter/inference error, stop the fork and preserve existing AVoIP media.
  Roll back only the observer/controller integration; do not redirect RTP.
- **Evidence:** Pending end-to-end call trace and failure injection report.
- **Details:** [AI phase 7](AI/TODO.md#phase-7--avoip-integration),
  [AVoIP acceptance ledger](AVoIP/TODO.md)

### AI-002 — Establish model artifact registry and rollback

- **Status:** Planned
- **Priority:** P1
- **Owner:** CoRE-Business/AI with Backplane S3/Harbor owners
- **Depends on:** AI-001 model metadata; available S3/Harbor artifact contract
- **Current state:** No wake-word model registry/promotion workflow is
  documented as implemented.
- **Next action:** Compare immutable S3 objects plus Git metadata with Harbor
  OCI artifacts and select the least-complex supported option.
- **Acceptance:** Checksummed immutable runtime-specific model versions carry
  license, compatibility, provenance and evaluation metadata; promote and
  restore a prior version from a target site.
- **Failure / rollback:** Invalid checksum or unavailable artifact keeps model
  unready; switch to prior immutable manifest. Avoid creating a database
  unless a real requirement remains unmet.
- **Details:** [AI phase 2](AI/TODO.md#phase-2--model-management)

## P2 — Major capability expansion

### VOICE-002 — Build microWakeWord Hey CoRE device pipeline

- **Status:** Planned
- **Priority:** P2
- **Owner:** CoRE-Business/AI and Home Assistant/ESPHome owners
- **Depends on:** Governed dataset; microWakeWord training; target Voice PE
  firmware and OTA rollback contract
- **Current state:** Existing Hey Jarvis device behavior is user-reported;
  custom microWakeWord artifact is not present.
- **Next action:** Build a reproducible ESPHome/microWakeWord pipeline and
  validate one test Voice PE device without removing existing wake words.
- **Acceptance:** Model manifest and quantized TFLite checksum, firmware
  compatibility, RAM/flash and latency measurements, calibrated sensitivity,
  false-trigger report, previous OTA image and successful rollback.
- **Failure / rollback:** Leave current firmware/model intact until rollback
  is exercised; revert OTA on degraded wake or voice behavior.
- **Details:** [AI phase 4](AI/TODO.md#phase-4--microwakeword-training)

### AI-003 — Establish JupyterHub training workspace foundation

- **Status:** Planned
- **Priority:** P2
- **Owner:** CoRE-Backplane platform and CoRE-Business/AI
- **Depends on:** Authentik OIDC; workspace namespace/quota policy; S3 dataset
  access; GPU inventory; network/secret policy
- **Current state:** JupyterHub is a selected direction, not an owned or
  deployed CoRE-Business service in the baseline inventory.
- **Next action:** Approve shared platform ownership and a CPU-only profile
  before any GPU training profile.
- **Acceptance:** Isolated OIDC user workspace, persistent storage and
  reproducible image; submitted training Job/checkpoint; least-privilege S3
  access; no access to AVoIP admin secrets/sockets; inference reserve remains
  available under load.
- **Failure / rollback:** Quota/priority limits cap training and allow job
  suspension; remove workspace owner without deleting retained user data until
  backup/export policy is followed.
- **Details:** [AI phase 5](AI/TODO.md#phase-5--jupyterhub)

### AVOIP-001 — Close current SIP routing and ownership gates

- **Status:** Partial
- **Priority:** P1
- **Owner:** CoRE-Business/AVoIP
- **Depends on:** Existing AVoIP P0 evidence and target site operator
- **Current state:** [AVoIP/TODO.md](AVoIP/TODO.md) reports a long call and
  Home1 G.711 fax reception, while complete ACK/BYE acceptance, YXL fax,
  active session recovery and site failover remain open. The SIP plan has
  WSS ownership/cutover gates and a current naming discrepancy.
- **Next action:** Continue the existing tracker with live, call-correlated
  acceptance evidence; reconcile `internal-websocket`/`internal-wss` first.
- **Acceptance:** Only the specific tracker phases with SIP/media traces,
  cross-site/failure tests and rollback evidence are marked complete.
- **Failure / rollback:** Follow AVoIP phase-specific migration/rollback; do
  not infer dialog recovery from shared Valkey/TOPOS state.
- **Details:** [AVoIP/TODO.md](AVoIP/TODO.md)

### ID-001 — Define unified user, tenant and device onboarding

- **Status:** Planned
- **Priority:** P2
- **Owner:** Backplane identity team and application owners
- **Depends on:** Current User XRD/Composition behavior, Authentik/LDAP
  contracts and app-specific client inventory
- **Current state:** App-specific OIDC and service claims exist, but one
  universal onboarding flow does not.
- **Next action:** Map lifecycle, entitlements, credential issuance/revocation
  and onboarding for Nextcloud, CardDAV/CalDAV, mail, SIP, Matrix, AI and
  developer workspaces.
- **Acceptance:** New, suspended, renamed and removed identities propagate
  predictably; each client's authentication limits are documented; no
  unsupported universal SSO claim.
- **Failure / rollback:** Preserve recovery/admin access; test revocation and
  credential recovery before moving an existing app login.
- **Details:** [portfolio identity plan](PLAN.md#10-identity-and-onboarding)

### COMM-001 — Prioritize reliability and recovery for current services

- **Status:** Partial
- **Priority:** P1
- **Owner:** Mail, Office, Matrix/Fediverse component owners and Backplane
- **Depends on:** CORE-001 and shared service/backup inventory
- **Current state:** Active application definitions exist; component-specific
  reliability claims require live user-flow and restore evidence.
- **Next action:** Select one current reported issue or recovery gap per active
  stack and attach a bounded acceptance test/runbook before speculative
  additions.
- **Acceptance:** Mail delivery and duplicate-send reports are independently
  diagnosed; Nextcloud collaboration/restore, Matrix federation/key recovery
  and Mastodon federation/media recovery have explicit measured tests.
- **Failure / rollback:** Changes are component-scoped with application data
  backups and service rollback; do not treat IMAP tuning as proof of
  duplicate-send resolution.
- **Details:** [portfolio collaboration plan](PLAN.md#11-office-collaboration-matrix-rtc-and-mail)

## P3 — Long-term and exploratory work

### PLATFORM-001 — Evaluate CoRE Functions and Workflows platform

- **Status:** Proposed
- **Priority:** P3
- **Owner:** CoRE-Backplane platform with CoRE-Business consumers
- **Depends on:** Knative/Temporal operator ownership, auth/network model,
  Forgejo CI and Harbor build/promotion contract
- **Current state:** n8n exists as a current application path; Knative and
  Temporal are selected candidates but not current Business deployments.
- **Next action:** Evaluate one HTTP function and one durable workflow against
  scale-to-zero, authentication, retries, idempotency, metrics, CI and
  rollback requirements.
- **Acceptance:** A documented control-plane/API and security model with a
  pilot that keeps realtime media outside both platforms.
- **Failure / rollback:** Do not migrate all n8n workflows; retain current
  workflow path until parity and data migration are proven.
- **Details:** [portfolio serverless plan](PLAN.md#8-developer-workspaces-and-serverless-functions)

### BIZ-001 — Validate customer services and business case

- **Status:** Research
- **Priority:** P3
- **Owner:** Business/product owner
- **Depends on:** Product boundary, site/commercial-use review, tenant and
  cost attribution model
- **Current state:** Multi-tenant onboarding, billing and related services are
  proposals that need a current product and operating case.
- **Next action:** Validate target users, services, margins, terms, support,
  placement constraints and Stripe/webhook scope before selecting software.
- **Acceptance:** Approved product case and threat/data flow review; payment
  webhooks are idempotent/audited; no payment initiation is delegated to an
  AI agent.
- **Failure / rollback:** Keep finance writes approval-controlled; disable
  webhook consumers and reconcile provider state before retry.
- **Details:** [portfolio business plan](PLAN.md#12-business-applications-and-billing)

### PORT-001 — Triage optional, unowned and legacy applications

- **Status:** Partial
- **Priority:** P3
- **Owner:** CoRE-Business maintainers and Backplane owners
- **Depends on:** CORE-001
- **Current state:** Many directories have no active owner, are opt-in, legacy
  or exploratory. README and `docs/REPOSITORY.md` already identify some.
- **Next action:** For each unowned path decide active maintenance, strategic
  integration, optional exploration or retirement review; preserve data and
  ownership before deletion.
- **Acceptance:** Each retained path has owner, user, deployment status,
  update/backup expectations and a retirement/deletion procedure.
- **Failure / rollback:** Do not remove resources solely because the directory
  lacks an owner; check Backplane Legacy, Argo preserve behavior and external
  data deletion policies.
- **Details:** [portfolio application classifications](PLAN.md#14-supporting-applications)

## Cross-project dependency order

```text
CORE-001 / CORE-002 / VOICE-000
        |
        +--> AI-001 --> AI-002 --> VOICE-001
        |                 |             |
        |                 +--> AI-003   +--> VOICE-002
        |                               |
        +--> AVOIP-AI-001 <-------------+
        |
        +--> AVOIP-001 --> identity/device lifecycle (ID-001)
        |
        +--> OPS-001 --> COMM-001 and platform pilots

PLATFORM-001 and BIZ-001 remain independent research gates;
neither is a prerequisite for voice inference.
```

## Deferred until a concrete owner and acceptance case exists

Multi-region voice AI, broad conversational agents, customer billing/portal,
Eclipse Che/full IDE platform, advanced RTC/SIP federation, Teams Direct
Routing, PeerTube/Lemmy deployment, expanded finance providers and live
payment automation remain P3 research or optional exploration. Compliance- or
carrier-dependent work (STIR/SHAKEN, E911, verified caller identity, PSTN
outbound identity) requires external policy and provider review before an
implementation milestone is approved.
