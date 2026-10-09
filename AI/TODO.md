# CoRE AI engineering backlog

**Baseline: 2026-10-09.** This is the AI implementation tracker. The
[AI platform plan](PLAN.md) describes architecture and acceptance contracts;
the [root portfolio backlog](../TODO.md) carries only cross-project milestones.
Do not close any phase based only on Helm rendering, pod readiness or an
ApplicationSet reference. Attach sanitized tests, effective configuration,
operator conditions and user-flow evidence to each completed milestone.

Priority: **P0** operational/security prerequisite; **P1** selected foundation;
**P2** major expansion; **P3** exploratory. Status uses the categories defined
in the [portfolio plan](../PLAN.md#2-current-core-business-capabilities-and-evidence).
At baseline, phases 0–8 are not complete. Existing AI applications are
**Implemented — repository verified** and their ApplicationSets are
**deployment configured**; live health is not established in this tracker.

## Phase 0 — Inventory and baseline

**Phase state:** Partial. **Priority:** P0. **Owner:** CoRE-Business/AI with
Backplane AI, S3, GPU and observability owners.

**Dependencies:** Read-only access to current ApplicationSet inputs, rendered
values and live resource metadata. **Exit evidence:** dated inventory per
selected target cluster; do not print secret values.

- [ ] **AI-000.1 — Resolve AI ApplicationSet scope and effective values.**
  Record AI and AINode2 selectors, target clusters/namespaces, Lovely merge
  layers, renderer order, enabled services, image digests, worker/GPU placement,
  Gateway host/path/weights and secrets by reference only.
  - **Acceptance:** representative full Lovely render reviewed beside
    sanitized live Deployment/StatefulSet/Service/Route/Workspace/User
    metadata; discrepancies listed.
  - **Failure behavior:** missing values or cluster evidence remain unknown;
    do not substitute chart defaults as production truth.
  - **Rollback:** read-only inventory; no runtime rollback required.
- [ ] **AI-000.2 — Reconcile AI README and values discrepancies.** Verify
  Speaches image tags and 1/99 default weights versus README's 0.8.3/equal
  split; verify Wyoming `latest`, LocalAI/llama enablement and other mutable
  tags against effective values. Update operational docs only after evidence.
  - **Acceptance:** each claim links to source/config or dated operational
    evidence and labels unresolved values.
  - **Failure behavior:** leave conservative unresolved wording; never change
    live values as a documentation fix.
  - **Rollback:** revert documentation commit.
- [ ] **AI-000.3 — Inventory models, runtimes and licenses.** Capture GPUStack,
  llama.cpp, LocalAI, Speaches/faster-whisper, Wyoming bridge, OpenWebUI, MCP,
  Paperclip, TTS, model IDs/versions, licenses, source, supported task, device,
  cache and consumer.
  - **Acceptance:** model/runtime matrix includes image/artifact digest,
    license conditions and deployment owner; no token or private model data.
  - **Failure behavior:** mark unknown model provenance/license and do not
    promote it for a new consumer.
  - **Rollback:** inventory only.
- [ ] **AI-000.4 — Inventory security, storage and observability.** Verify
  Authentik groups/redirects, User claims and Composition behavior, Gateway
  auth/exposure, Cilium policies, External Secrets refs, Postgres/Dragonfly/S3
  use, PVC/backup semantics, metrics/logs/traces and alert ownership.
  - **Acceptance:** per-service data-flow and failure-boundary record; no
    secrets, generated keys or raw audio in evidence.
  - **Failure behavior:** unknown permissions/data deletion are explicit
    blockers for dependent work.
  - **Rollback:** read-only inventory.
- [ ] **AI-000.5 — Establish inference and speech baselines.** Run known test
  prompts/audio through supported model endpoints; record p50/p95 latency,
  throughput/concurrency, CPU/GPU/memory, cold load, quality and errors.
  - **Acceptance:** repeatable sanitized input set, test command/version and
    dated results per selected workload/cluster.
  - **Failure behavior:** unavailable endpoint or model is recorded as failure,
    not inferred from pod readiness.
  - **Rollback:** test only; do not change production model selection.

**Dependencies for next phase:** AI-000.1/000.4, target CPU capacity, protocol
and auth design, agreed raw-audio non-retention and model license review.

## Phase 1 — OpenWakeWord service

**Milestone:** [AI-001](../TODO.md#ai-001--establish-openwakeword-inference-service).
**Phase state:** Planned. **Priority:** P1. **Owner:** CoRE-Business/AI.

- [ ] **AI-001.1 — Define streaming API and identity contract.** Specify
  authenticated WebSocket setup, service identity, client token lifecycle,
  PCM16 mono 16 kHz chunk framing, timestamps/sequence, session close/reset,
  model discovery/version selection, thresholds, cooldown and bounded size.
  - **Depends on:** AI-000.4.
  - **Acceptance:** versioned API schema covers normal, malformed, stale,
    unauthorized and overloaded sessions; audio data and logs have explicit
    non-retention defaults.
  - **Failure:** reject unauthorized or invalid streams; never allow unbounded
    buffers or anonymous public audio ingress.
  - **Rollback:** no service deployed until contract review; API versions are
    additive and clients can pin prior version.
- [ ] **AI-001.2 — Implement CPU-first OpenWakeWord runtime and container.**
  Pin runtime/model dependencies, non-root image, resource limits, health and
  readiness that verifies a model is loaded; isolate session state per stream.
  - **Depends on:** AI-001.1; AI-002 metadata format or temporary reviewed
    development artifact.
  - **Acceptance:** real audio test vectors produce expected positive and
    negative outputs; concurrency and memory tests show no cross-session
    leakage; image digest is recorded.
  - **Failure:** model load failure prevents readiness; process crash closes
    sessions and does not affect HA/AVoIP RTP.
  - **Rollback:** restore previous digest/model; disable route and keep any
    existing Wyoming/Home Assistant paths unchanged.
- [ ] **AI-001.3 — Add event lifecycle, thresholds and deduplication.** Emit
  versioned events with model/version, event ID, session, timestamp, score,
  threshold, cooldown and optional caller-provided correlation ID. Do not add
  caller name, transcript or raw audio by default.
  - **Depends on:** AI-001.1 and runtime.
  - **Acceptance:** one event per accepted phrase/cooldown, explicit session
    reset, expired/replayed event detection and no cross-stream event bleed.
  - **Failure:** invalid event is dropped and counted without escalating to
    an action.
  - **Rollback:** disable event consumer; retain model API for diagnostic use.
- [ ] **AI-001.4 — Add test suite and streaming performance gates.** Test
  chunk framing, resampling responsibility, jitter/drop, reconnect, auth expiry,
  multiple concurrent sessions, malformed inputs, resource exhaustion and
  known positive/hard-negative samples.
  - **Acceptance:** defined false accept/reject, time-to-detect, dropped frame,
    p95 latency, CPU and memory thresholds pass on the target CPU profile.
  - **Failure:** fail closed for model/action output; do not degrade voice
    forwarding. Revert to prior artifact or keep endpoint unpublished.
- [ ] **AI-001.5 — Expose metrics and integrate privately.** Export active
  streams, frame loss, queue depth, model errors/load, detections by model,
  latency, CPU/memory and auth failures; use bounded labels. Add private route
  or service, NetworkPolicy and platform dashboards/alerts after ownership
  review.
  - **Depends on:** AI-000.4; Backplane Gateway/Cilium contracts.
  - **Acceptance:** dashboards and alert tests work without audio/transcript
  labels; route is authenticated/private; service is tested through intended
  consumer path.
  - **Failure:** missing metrics/health prevents production promotion.
  - **Rollback:** remove private route and restore previous service config;
    do not remove model artifacts needed for rollback.
- [ ] **AI-001.6 — Validate horizontal scale and session routing.** Load-test
  independent sessions across replicas, sticky routing or explicit session
  ownership, draining and reconnect behavior.
  - **Acceptance:** no lost or duplicated detections during the defined
  reconnect window; saturation is bounded; scale-up/down does not silently
  redirect audio to an incompatible model.
  - **Failure:** shed new sessions before unbounded latency; existing voice
  call remains unaffected.
  - **Rollback:** pin a tested replica count and disable autoscaling until
  session behavior is understood.

**Exit evidence:** authenticated real PCM test, quality/performance report,
metrics, no audio persistence verification, and failure test proving consumer
path remains independent. A render alone does not complete this phase.

## Phase 2 — Model management

**Milestone:** [AI-002](../TODO.md#ai-002--establish-model-artifact-registry-and-rollback).
**Phase state:** Planned. **Priority:** P1. **Owner:** AI with Backplane S3/Harbor.

- [ ] **AI-002.1 — Select S3/Git or Harbor artifact model.** Compare immutable
  S3 objects plus Git manifests against Harbor OCI artifacts for access control,
  checksum/signature, CI, retention, replication and restore. Do not add a
  registry DB unless requirements justify it.
  - **Depends on:** Backplane S3 and Harbor owner review; AI-000.4.
  - **Acceptance:** ADR names owner, path/namespace, lifecycle, auth, site
  placement, backup and rollback, with threat/data-flow review.
  - **Failure:** if neither path meets provenance/security, keep models in
  controlled build artifact storage and block promotion.
  - **Rollback:** selection only; no live workload change.
- [ ] **AI-002.2 — Define immutable manifest and metadata schema.** Include
  content checksum, artifact/runtime/version/format, license, source, training
  code/data references, hardware compatibility, evaluation, creator and
  promotion state.
  - **Acceptance:** schema validates OpenWakeWord ONNX and microWakeWord TFLite
  artifacts separately; metadata contains no restricted audio or secrets.
  - **Failure:** reject incomplete or conflicting metadata before upload.
  - **Rollback:** schema versions remain readable; old manifests are immutable.
- [ ] **AI-002.3 — Implement promotion, rollback and restore.** CI uploads
  content-addressed artifacts, verifies checksum and provenance, promotes by
  reference, and restores an earlier version from each intended site.
  - **Acceptance:** corrupted artifact is rejected; promotion is auditable;
  rollback completes within a measured bound and prior runtime loads it.
  - **Failure:** block promotion; keep current known-good model and cache.
  - **Rollback:** point deployment metadata to prior artifact; never overwrite.
- [ ] **AI-002.4 — Add license and artifact revocation workflow.** Track
  redistribution and dataset/model license; document removal from caches and
  restore copies when license or provenance changes.
  - **Acceptance:** owner can identify consumers and revoke future pulls while
  retaining required audit metadata.
  - **Failure:** suspect artifact is quarantined; no silent fallback to an
  unreviewed model.

## Phase 3 — Hey CoRE OpenWakeWord training

**Milestone:** [VOICE-001](../TODO.md#voice-001--train-and-evaluate-hey-core-for-openwakeword).
**Phase state:** Planned. **Priority:** P1. **Owner:** AI/model steward.

- [ ] **VOICE-001.1 — Approve corpus governance and license plan.** Define
  consent, licensing, provenance, speaker/source metadata, access/retention,
  deletion, de-identification and S3 isolation before collecting audio.
  - **Depends on:** privacy/security review and artifact plan.
  - **Acceptance:** approved data card, access policy and removal process;
  no private conversation/audio is copied to Git.
  - **Failure:** no data collection or model promotion until resolved.
  - **Rollback:** revoke dataset access and apply deletion/retention process.
- [ ] **VOICE-001.2 — Build balanced positive and negative data.** Include
  positive multispeaker examples, synthetic speech with licensing record, hard
  negatives, room noise/reverb/mic variation and telephony-band/codec/noise
  augmentation.
  - **Acceptance:** source and augmentation manifest; speaker/session-disjoint
  train/validation/held-out partitions; reproducible data hashes.
  - **Failure:** contaminated/leaked partitions invalidate evaluation and
  block training promotion.
  - **Rollback:** exclude/rebuild affected split; never overwrite published
  corpus version.
- [ ] **VOICE-001.3 — Pin and reproduce OpenWakeWord training/export.** Record
  framework/dependency versions, config, seeds, training command/hardware and
  output format.
  - **Depends on:** data gate and training capacity.
  - **Acceptance:** independent rerun produces expected artifact/checksum or
  documented reproducibility tolerance.
  - **Failure:** do not publish; retain logs without audio/secrets and repair
  pipeline.
  - **Rollback:** continue using prior selected model or no custom model.
- [ ] **VOICE-001.4 — Evaluate and promote Hey CoRE.** Measure false accepts
  per hour, false rejection, time-to-detect, model size, CPU/memory and group
  conditions on held-out speech/telephony samples; compare to predeclared gates.
  - **Acceptance:** signed/attested manifest, license, checksums and report;
  staged promotion with rollback reference.
  - **Failure:** model remains candidate; retrain or revise phrase/dataset.
  - **Rollback:** restore previously accepted model and invalidate candidate.

**Exit evidence:** actual runtime-compatible artifact and reproducible report.
“Hey CoRE” remains an untrained proposal until this gate passes.

## Phase 4 — microWakeWord training

**Milestone:** [VOICE-002](../TODO.md#voice-002--build-microwakeword-hey-core-device-pipeline).
**Phase state:** Planned. **Priority:** P2. **Owner:** AI with HA/ESPHome.

- [ ] **VOICE-002.1 — Validate microWakeWord dataset and training path.** Reuse
  approved source material only where license, sample rate and augmentation
  fit the embedded runtime; track embedded-specific training configuration.
  - **Acceptance:** reproducible training record, held-out speakers and
  device-oriented quality report.
  - **Failure:** do not infer equivalence from OpenWakeWord quality; keep
  existing embedded models.
  - **Rollback:** no device update.
- [ ] **VOICE-002.2 — Export quantized TFLite and ESPHome model manifest.**
  Validate target firmware format, checksums and runtime compatibility using
  pinned microWakeWord/ESPHome toolchain.
  - **Acceptance:** firmware build resolves artifact reproducibly and reports
  expected model version.
  - **Failure:** reject incompatible/oversized export.
  - **Rollback:** previous model and firmware manifest remain selectable.
- [ ] **VOICE-002.3 — Benchmark Voice PE memory, latency and sensitivity.**
  Test actual device flash/RAM, wake latency, threshold/sensitivity calibration,
  false accepts/rejects, “Stop” behavior and normal voice pipeline responsiveness.
  - **Acceptance:** test report across expected room/noise conditions and
  preserved current Hey Jarvis/Okay Nabu/Hey Mycroft/Stop behavior.
  - **Failure:** no OTA promotion if response is slow, noisy or degraded.
  - **Rollback:** execute tested OTA restore to prior firmware/model.

## Phase 5 — JupyterHub

**Milestone:** [AI-003](../TODO.md#ai-003--establish-jupyterhub-training-workspace-foundation).
**Phase state:** Planned. **Priority:** P2. **Owner:** Backplane platform for
shared operators; AI for workspace images and jobs.

- [ ] **AI-003.1 — Approve workspace ownership and threat model.** Compare
  notebook needs with full IDE needs; define namespace, group/tenant mapping,
  quotas, network, ingress, secret, image, storage and audit contracts.
  - **Acceptance:** named platform owner, Authentik app/group, least-privilege
  service identity, Cilium/network and data-retention review.
  - **Failure:** block deployment if isolation or user offboarding is unclear.
  - **Rollback:** keep existing developer tools; no data is migrated.
- [ ] **AI-003.2 — Implement Authentik OIDC and KubeSpawner profiles.** Start
  with CPU-only profile; add persistent per-user storage, idle culling,
  resource quotas and versioned base images.
  - **Acceptance:** authorized user can create/stop workspace; another user
  cannot read its storage; suspended identity loses access and admin recovery
  works.
  - **Failure:** failed auth/quota checks deny workspace creation.
  - **Rollback:** stop new spawns, preserve/export user storage, restore prior
  chart/image.
- [ ] **AI-003.3 — Add isolated GPU profile and training Jobs.** Apply lower
  priority than real-time inference; mount only scoped S3 data; store
  checkpoints and logs without production service credentials.
  - **Acceptance:** repeatable job, checkpoint/restart, quota/preemption and
  inference reserve test pass; no AVoIP secret or RTPEngine socket is mounted
  or reachable.
  - **Failure:** suspend training on inference saturation or node/GPU loss;
  resume from checkpoint only.
  - **Rollback:** disable GPU profile; retain approved checkpoints under data
  policy.
- [ ] **AI-003.4 — Connect CI evaluation and artifact promotion.** Run tests
  from Forgejo CI or approved Job, publish report, and require human/model
  steward promotion.
  - **Acceptance:** untrusted pull request cannot publish production models;
  protected branch and provenance are enforced.
  - **Failure:** failed test or provenance blocks promotion.
  - **Rollback:** use previous immutable artifact, not a notebook output.

## Phase 6 — Home Assistant integration

**Phase state:** Planned. **Priority:** P2. **Owner:** AI and Home Assistant.

- [ ] **AI-006.1 — Inventory existing Hey Jarvis behavior and device artifact.**
  Record Voice PE firmware/ESPHome versions, microWakeWord model selection,
  thresholds, Home Assistant pipeline and rollback image. Avoid storing
  credentials or private device details.
  - **Depends on:** AI-000 inventory and user/device verification.
  - **Acceptance:** baseline test produces wake and STT/TTS outcomes with
  versioned device configuration.
  - **Failure:** preserve device behavior; mark any unverifiable details.
  - **Rollback:** no config change.
- [ ] **AI-006.2 — Decide optional Wyoming/server wake integration.** Verify
  current Wyoming protocol capabilities and Home Assistant support; compare
  server stream with embedded trigger, network/privacy tradeoffs and failure
  behavior.
  - **Acceptance:** an architecture decision explicitly preserves embedded
  mode as fallback or explains an approved change; only supported APIs selected.
  - **Failure:** retain embedded KWS if server path is unavailable.
  - **Rollback:** disable integration endpoint/HA selection; restore device's
  previous pipeline.
- [ ] **AI-006.3 — Distribute Hey CoRE to a test device.** Package approved
  microWakeWord artifact via reproducible ESPHome manifest and one-device OTA
  pilot after VOICE-002 passes.
  - **Acceptance:** checksum/firmware recorded; target device detects within
  quality gates, existing controls work and OTA rollback is executed.
  - **Failure:** restore previous firmware immediately on degraded behavior.
  - **Rollback:** tested OTA to prior image; preserve device accessibility.

## Phase 7 — AVoIP integration

**Milestone:** [AVOIP-AI-001](../TODO.md#avoip-ai-001--connect-opted-in-caller-audio-to-inference).
**Phase state:** Planned. **Priority:** P1 after prerequisites. **Owner:**
CoRE-Business/AVoIP and AI; Backplane for media/network policy.

- [ ] **AVOIP-AI-001.1 — Prove RTPEngine directional media subscription.**
  Confirm deployed RTPEngine version, control protocol access, media selection
  by Call-ID/tags, sink reachability, RTP/session setup, codec behavior and
  teardown. Verify copy-only subscription leaves original caller/recipient
  streams unchanged.
  - **Depends on:** VOICE-000; read-only inventory of site RTPEngine owner;
  isolated internal lab call.
  - **Acceptance:** packet/Call-ID-correlated traces show caller-only stream at
  sink, no injected packets, stable two-way call quality and no cross-call
  leakage; failure to connect subscriber does not disrupt RTP.
  - **Failure:** stop test and do not expose a production media fork; use
  Asterisk ARI external media only if a separately reviewed path is more
  suitable.
  - **Rollback:** unsubscribe/stop adapter and confirm baseline RTP resumes;
  no media policy is broadened.
- [ ] **AVOIP-AI-001.2 — Specify and implement PCM adapter.** Define codecs,
  packet timing, jitter buffer, G.711 decode, resampling to PCM16 mono 16 kHz,
  channel direction, timestamps, loss/late-frame handling, auth, NetworkPolicy,
  resource bounds and metrics.
  - **Depends on:** successful AVOIP-AI-001.1.
  - **Acceptance:** deterministic capture-free tests validate sample rate,
  amplitude, endian, timing, caller direction and bounded behavior under loss.
  - **Failure:** adapter drops analysis frames on overload; never queues
  indefinitely or sends control back to RTPEngine based on model output.
  - **Rollback:** disable subscriber and remove adapter endpoint/policy.
- [ ] **AVOIP-AI-001.3 — Define dialog correlation and authorized controller.**
  Map SIP Call-ID/tags, RTPEngine selected instance, FreeSWITCH UUID/channel
  owner, call opt-in and expiry. Authenticate event source, deduplicate action
  IDs, audit metadata, check live call ownership and allow only approved
  FreeSWITCH operation.
  - **Depends on:** existing AVoIP SIP identity/owner model and AI-001 event
  contract.
  - **Acceptance:** forged, replayed, expired, wrong-direction and post-hangup
  events are rejected; valid event reaches only the owning channel once.
  - **Failure:** fail closed for action, fail open for normal call/media; no
  arbitrary extension or dial string from model output.
  - **Rollback:** controller denies all actions while observer may be tested;
  stop subscription and revoke service identity.
- [ ] **AVOIP-AI-001.4 — Execute controlled extension 7102 GG lab action.**
  With a specifically opted-in internal/lab call, recognize Hey CoRE from
  inbound caller audio and request FreeSWITCH to mix the “GG” test sound toward
  internal extension `7102` on the owning channel.
  - **Depends on:** AI-001, VOICE-001, AVOIP-AI-001.1–.3, explicit lab
  extension/media route and authorization.
  - **Acceptance:** one detection -> one action; called participant receives
  GG; caller/recipient RTP stays healthy; action target and direction are
  proven; detection after hangup is rejected; no recording exists; service
  outage leaves call connected.
  - **Failure:** no audio side-effect if authorization, owner mapping or call
  state is unknown; apply call-specific cooldown and event expiry.
  - **Rollback:** disable opt-in and action policy, unsubscribe media,
  restore previous FreeSWITCH dialplan/config and verify ordinary calls.
- [ ] **AVOIP-AI-001.5 — Validate load, security and failure behavior.** Test
  multiple opted-in/non-opted-in calls, duplicate subscriptions, site/network
  loss, RTPEngine owner loss, CPU saturation, KWS outage, controller outage,
  FreeSWITCH channel migration/hangup and logging/redaction.
  - **Acceptance:** no media regression, no cross-call processing, bounded
  CPU/packet overhead, no retained caller audio, complete audit of decisions
  and no action without explicit authorization.
  - **Failure:** feature auto-disables at configured safety threshold; ordinary
  telephony remains available.
  - **Rollback:** site-local feature flag off and subscriptions drained; retain
  no raw audio or stale action queue.

**Exit evidence:** end-to-end call trace, test recordings only if separately
authorized and retained under explicit policy (default is none), metrics,
failure injection and an operator rollback exercise. The AVoIP phase remains
open until those results are recorded in [AVoIP/TODO.md](../AVoIP/TODO.md).

## Phase 8 — Broader AI platform

**Phase state:** Proposed/Research. **Priority:** P2–P3. **Owner:** AI plus
each consuming application and Backplane platform owner.

- [ ] **AI-008.1 — Benchmark inference routing and serving candidates.** Compare
  current GPUStack/llama.cpp/LocalAI/Speaches with vLLM/SGLang only against
  measured workload needs; evaluate quantization, cold-start, concurrency,
  quotas, caching, model discovery, site routing and resource fairness.
  - **Depends on:** AI-000 baselines, GPU inventory and target API contract.
  - **Acceptance:** repeatable report using latency, throughput, memory,
  compatibility, hardware utilization and operating effort; select a minimal
  runtime set with migration/rollback plan.
  - **Failure:** keep current runtime and document gap; do not deploy a
  framework just for feature parity.
  - **Rollback:** return router to previous endpoint/model; keep old runtime
  until consumers pass.
- [ ] **AI-008.2 — Evaluate Knative function and Temporal workflow pilots.**
  Use one authenticated API function and one retryable background workflow;
  compare with current n8n and ensure shared operators/identity exist.
  - **Depends on:** Backplane owner/readiness, Forgejo CI, Harbor build and
  shared auth/network/observability contracts.
  - **Acceptance:** function auth/scale-to-zero and workflow idempotency,
  retries, timers, approval, logs/traces and rollback tested; RTP excluded.
  - **Failure:** do not migrate existing workflows; retain n8n path.
  - **Rollback:** stop new task starts; drain/version workflow safely; restore
  prior integration.
- [ ] **AI-008.3 — Evaluate agent tool execution and audits.** Review
  OpenWebUI, Paperclip and MCP coverage before adding orchestration. Implement
  actor-scoped tool registry, secret isolation, confirmation, audit and
  prompt-injection/data-exfiltration evaluation.
  - **Acceptance:** adversarial tests prove tenant/tool isolation, high-impact
  approval, revocation and no action from untrusted retrieved instructions.
  - **Failure:** tools default to read-only/disabled; no production credential
  in model context.
  - **Rollback:** revoke tool grants and disable execution while preserving
  user-facing inference.
- [ ] **AI-008.4 — Evaluate RAG and knowledge ingestion.** Compare approved
  Markdown/Obsidian/Git, Nextcloud and other sources; define provenance,
  permissions, deletion sync, embeddings, hybrid retrieval and reranking.
  - **Acceptance:** per-user/tenant access tests, citation provenance,
  deletion and prompt-injection checks pass before indexing production docs.
  - **Failure:** source denied or stale permissions stop retrieval; no
  cross-tenant fallback.
  - **Rollback:** remove index/embeddings and source credentials according to
  retention policy; preserve source of truth.
- [ ] **AI-008.5 — Evaluate multi-site placement and capacity controls.**
  Define data locality, remote fallback rules, per-site cache, queue, priority,
  cold start and inference SLO; coordinate with Backplane ClusterMesh/network
  owners.
  - **Acceptance:** site/link loss, cache miss and GPU saturation tests produce
  documented behavior; no claim of shared state or active-active model cache.
  - **Failure:** refuse remote inference when data policy, identity or latency
  requirement is unmet.
  - **Rollback:** pin consumers to their last known local endpoint.

## Phase closeout and status rules

For each phase, link the full rendered configuration when relevant, but also
include operator conditions, actual API/audio result, relevant latency/quality
numbers, auth/authorization tests, failure behavior and rollback evidence.
Remove personal identifiers and do not attach raw caller audio. Update the
root `TODO.md` summary and this tracker in the same documentation change when
a milestone changes status. Keep the AVoIP SIP phase rows authoritative for
its media, registration, WSS, routing and recovery status.
