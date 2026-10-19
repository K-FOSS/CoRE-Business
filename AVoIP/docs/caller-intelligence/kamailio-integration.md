# Future Kamailio integration plan

Status: **design only; no routing or image changes in this task**.
[Existing generated routes](../../templates/Kamailio/_sip-functions.tpl) and
[named instances](../../templates/Kamailio/_instances.tpl) are the starting point.
The [owning AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
declares three `carrier` replicas at both sites. Private SBC and WebSocket
instances have different roles and must not automatically inherit evaluation.
No replacement of Kamailio, FreeSWITCH, Asterisk or RTPEngine is proposed.

## Trust and asserted identities

1. Preserve carrier CIDR/source validation on the existing ingress. Where Envoy
   supplies PROXYv2, accept it only from the authorized gateway path and retain
   original source facts. Validate tenant-owned DID and ingress role before
   scheduling evaluation or enrichment. A carrier source is not a caller identity.
2. Define a per-carrier trust profile for P-Asserted-Identity using
   [RFC 3325](https://www.rfc-editor.org/rfc/rfc3325). Only select PAI when the
   transport/source profile explicitly authorizes that assertion. Handle multiple
   or conflicting asserted identities as ambiguous, not by choosing whichever
   permits the call. Bound parsing and URI length; strip untrusted route-control
   and classifier headers. No display name is an identity authority.
3. Preserve original From for signaling semantics; choose a canonical evaluation
   identity from trusted assertion or, if absent, a clearly marked unverified
   From. Validate SIP/tel URI grammar, percent encoding, `user=phone`, international
   prefix handling and authorized default region. Do not turn extension IDs into
   public numbers. A From number can be spoofed even from a trusted carrier SBC.
4. Apply presentation/privacy restrictions. Withheld remains withheld for user
   displays and paid lookups; avoid sending private asserted data externally by
   default even if the carrier supplies an internal number. Missing or malformed
   identity produces its explicit policy state, not a crash or guessed country.
5. Accept STIR/SHAKEN evidence only from a trusted verifier with origin/destination/
   time/certificate binding. Store unavailable separately from invalid. A raw
   Identity header or carrier `verstat` is not automatically locally verified.
   Verification module and certificate-fetch constraints are in [research](research.md).

## Transaction placement and three-replica deduplication

The current carrier route already treats `has_totag()`, ACK and dialog routing
specially. Its source/authorization/transaction helpers and inter-site transfers
must be reviewed as a complete generated unit before editing. This is ordering
pseudocode, deliberately **not runnable Kamailio configuration**:

```text
existing syntax, transport/source and destination authorization
existing CANCEL / ACK / in-dialog / keepalive / registration handling
existing transaction retransmission check
if initial INVITE from validated carrier to an owned external DID:
    establish/check tm transaction once; send normal bounded provisional response
    preserve original DID and tenant through any inter-site handoff
    derive stable transaction key + correlation ID
    async authenticated site-local evaluate, overall wait <= proposed 75 ms
    callback: verify transaction still pending, not canceled/finalized
    validate response revision, transaction, DID/scope, expiry and action enum
    resume exactly once into approved local action mapping or normal fallback
existing topology, Record-Route, media, inter-site and backend routing
```

An existing `tm` transaction must be present before `http_async_query()` for
suspend/resume behavior. Check its return values and timeout callback in the
pinned module. Do not assume it creates a safe transaction automatically.
Choose one resume owner; a timeout/cancel/final-response race must not emit two
final responses or leak a suspended transaction. CANCEL must remain prompt
while the HTTP request is pending. No synchronous retry on the call path.

Retransmits matched on the same replica reuse `tm` state. If ingress can deliver
copies to different replicas, the service returns the same transaction result
from shared dedup, but that alone does **not** prevent two SIP proxies forwarding
the call. Existing ingress/transaction affinity must be proved or an explicit
cross-replica admission owner/lease protocol designed before enforcement. A
classification cache is not replicated SIP transaction state. Test simultaneous
copies, no duplicate downstream INVITEs, and cancellation routing. If this gate
fails, keep observe-only/bypass rather than claim distributed SIP safety.

Enrichment single-flight is a separate provider/feature/number freshness key
across all replicas/sites, with the durable ledger as authority. In-dialog
re-INVITE, UPDATE, INFO/DTMF, PRACK, ACK, BYE, CANCEL, REGISTER, OPTIONS and SMS
must neither initiate evaluation nor paid lookups. Transfer-generated initial
INVITEs from authenticated internal peers carry only server-validated correlation;
they must not masquerade as a new external call.

## Redis and internal HTTP

Prefer service-owned Redis access initially. Kamailio's existing `ndb_redis`
profiles support topology state and outbound accounting; do not add classifier
payloads to those keys or reuse their timeout settings. A future direct cache
fast path is optional and requires its own profile, allocated database, schema,
short timeouts, authentication-state/DID/policy-aware keys and reliable revision
invalidation. It must not bypass tenant policy or consult a remote-site Redis.
A stale/failed direct cache should fall through to local evaluation or normal
routing within the same deadline, not exhaust the SIP worker.

Add `http_async_client` only after confirming the carrier image has the module,
libcurl/libevent, mTLS support and bounded JSON parsing. Any required image build
is a separately tested, pinned change. Network policy allows only evaluator
access, not public provider APIs from the SBC. Validate the response content type,
body size, correlation, allowed action, owned scope, expiry and revision. Never
use provider text or a returned URI as `$du`/Request-URI routing input.

## Action mapping and response codes

| Decision | Planned signaling behavior |
| --- | --- |
| `normal` | Continue original DID/IVR/extension route and all existing topology/media helpers |
| `warn` | Normal route plus an authenticated callee UI indication where supported; no public spoofable SIP display-name rewrite; normal fallback otherwise |
| `challenge` | Only a configured voice DID challenge on FreeSWITCH/Asterisk, with a bounded single attempt, timeout and destination allowlist; success resumes original policy-approved route, never arbitrary DTMF dialing |
| `voicemail` | Only an explicitly provisioned Asterisk mailbox/context for the destination, preserving privacy, greeting, PIN access and normal teardown; no arbitrary extension from API |
| `reject` | Proposed default 603 Decline for explicit user call refusal; 607 Unwanted only after carrier interoperability/semantics review. Existing transport/security failures retain their established 403 behavior |

[603 semantics](https://www.rfc-editor.org/rfc/rfc3261#section-21.6.2) can affect
forks/retries; test actual carrier behavior before choosing codes.
[607](https://www.rfc-editor.org/rfc/rfc8197) is an optional caller-unwanted signal,
not a generic provider failure. Do not use SIP 401/407 as an IVR challenge: those
are authentication challenges. A classifier timeout does not return SIP 503;
it continues the pre-existing route. Apply a code only on the original pending
INVITE and permit normal transaction ACK/cancel handling. Avoid response details
that disclose private block reasons to the caller.

## Existing application paths

- **IVR**: evaluate before the carrier route's YXL-to-YVR transfer as well as the
  local YVR path, preserving original DID/scope. Do not evaluate again at 7102.
  Existing silent digit collection is not the proposed anti-spam challenge.
  New challenge audio, retries, failover and mailbox mappings require a future
  explicit dialplan design and regression tests.
- **Registered extensions**: allowed calls retain contact lookup, parallel ringing,
  first-answer cancellation and no-contact behavior. Do not query private
  recipient policy before a shared IVR has selected that recipient. Unknown
  recipient uses the DID policy; unsupported user policy is shown as inactive.
- **Voicemail**: existing greeting, busy/no-answer handling, PostgreSQL storage,
  mailbox PIN navigation and transfer behavior are preserved. A policy voicemail
  action is available only if mailbox provisioning and the route are validated.
  Missing mapping falls back to normal with a configuration alert.
- **Fax**: classify by reviewed DID service role, not a historical value name or
  carrier line-type label. Preserve current legacy FaxNumber-to-7101 behavior.
  Actual fax DIDs must bypass audio warnings/challenges and retain fax negotiation,
  RTP/T.38 behavior where configured; default observe-only until a controlled fax
  test proves compatibility. Unsupported actions fall back to normal.
- **Emergency/infrastructure/internal**: bypass as defined in [policy precedence](policy-engine.md).
  Do not grant exemptions based on spoofable From/PAI text. Outbound emergency
  dialing and existing service extensions are outside this inbound classifier.
- **Media/dialogs**: no change to Record-Route, TOPOS tokens, aliases, SIP Core
  WebSocket ownership, RTPEngine selection/restoration, SDP or BYE/ACK routing.
  Existing active calls never acquire a new classifier dependency.

Correlate evaluation UUID, protected original SIP Call-ID/transaction HMAC and
site/role/policy revision with existing [Homer traces](../HOMER.md). Carry the
association across the approved inter-site path using authenticated metadata,
not user-provided headers. Keep raw numbers out of low-access logs; Homer retains
its existing restricted SIP payload access. See [observability](security-observability.md).
