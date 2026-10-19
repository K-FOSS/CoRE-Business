# Engineering comparison and upstream research

Reviewed 2026-10-18 against Kamailio **6.1.4** source README files and 6.1.x
manuals. Website `stable` aliases move; implementation must pin source and
inspect the actual image. Module availability is not proof of configuration.
[Kamailio](https://www.kamailio.org/) remains the signaling boundary.

## SIP tools and reuse

| System | What it supplies | Reuse and limit |
| --- | --- | --- |
| [secfilter 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/secfilter.html), [pinned source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/secfilter/README) | Memory-loaded allow/block checks for IP, UA, domain/user and explicit country input; destination and SQL-injection checks | Useful SIP hygiene. Country input is not automatically the caller number's region. Destination filtering does not imply inbound caller blocking. No business resolver, tenant UI or weighted reputation |
| Historical [userblacklist 5.2](https://www.kamailio.org/docs/modules/5.2.x/modules/userblacklist.html); current [userblocklist 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/userblocklist.html), [pinned source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/userblocklist/README) | User/global prefix lists, allow exceptions, DB loading/reload | 6.1.4 uses `userblocklist` and renamed functions, not `userblacklist`. Defaults target Request-URI destination. Functions accepting an explicit number can be deliberately supplied caller identity, but trust, normalization, scope and precedence must be implemented. Prefer the new policy service as policy authority |
| [pike 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/pike.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/pike/README) | Source-IP request-density detector; script chooses response | Flood control, not telephone spam classification. Aggressively blocking a shared carrier IP can block every caller. Per-process-host state is not a global three-replica counter |
| [ratelimit 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/ratelimit.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/ratelimit/README) | SIP method queues and load/rate algorithms | Overload control; separate from number frequency, reputation or a paid lookup quota. Independent replicas do not create a global budget |
| [htable 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/htable.html) | Shared memory within an instance, expiry and optional DMQ replication | Potential tiny decision cache; DMQ does not provide transactional quota consistency. New module/config work if adopted; avoid replica-local stale enforcement |
| [ndb_redis 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/ndb_redis.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/ndb_redis/README) | Redis commands through hiredis, timeouts and server profiles | Already used for TOPOS and outbound counters. A separate application namespace/DB is required. Caller Intelligence should own cache schemas. Upstream 6.1 docs describe TLS, but the local TOPOS template explicitly uses a TLS proxy for the pinned image: verify build/library behavior rather than copying a TLS example |
| [phonenum 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/phonenum.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/phonenum/README) | libphonenumber parsing, normalization and numbering metadata | Optional early validation. Not reverse owner lookup, port-corrected carrier data or spam scoring. Requires libphonenumber; central Go normalization avoids inconsistent metadata on replicas |
| [http_async_client 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/http_async_client.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/http_async_client/README) | Asynchronous HTTP via libcurl/libevent; resumes an existing `tm` transaction | Preferred future local evaluation bridge. Establish transaction before request, cap timeout below SIP timers, implement error/cancel/resume exactly once. It supplies transport, not policy or provider accounting |
| [stirshaken 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/stirshaken.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/stirshaken/README) | PASSporT/Identity verification and certificate path checks via libstirshaken | Candidate verification input, subject to trust-anchor/certificate governance. Certificate fetch can block; do not put uncached Internet fetches on workers. Library needs `stir_shaken_verify_cert_path`; pin compatible library |
| [secsipid 6.1](https://www.kamailio.org/docs/modules/6.1.x/modules/secsipid.html), [source](https://github.com/kamailio/kamailio/blob/6.1.4/src/modules/secsipid/README) | Alternative STIR/SHAKEN functions via `secsipid_proc` and [secsipidx](https://github.com/asipto/secsipidx) | Evaluate one verifier, not two parallel sources of truth. Requires extra library/packaging, certificate caches and bounded retrieval. Neither verifier makes authenticated calls harmless |

The inspected [custom image build](../../image/kamailio-lf-heartbeat/Containerfile)
explicitly builds signaling, database, Redis, topology, trace and media modules.
It does not list `secfilter`, `userblocklist`, `pike`, `ratelimit`, `htable`,
`phonenum`, `http_async_client`, `stirshaken` or `secsipid`. Carrier roles use
the digest-pinned base image from values; their complete installed module set
has not been inspected. No image or module is changed in this task.

STIR/SHAKEN should use [RFC 8224](https://www.rfc-editor.org/rfc/rfc8224)
and [RFC 8588](https://www.rfc-editor.org/rfc/rfc8588) semantics. Retain verification
status, attestation A/B/C, signer/provenance, time and origin/destination binding.
An attestation letter copied from an untrusted header is not verified evidence.
Missing attestation is common on legitimate paths; valid attestation does not
prove business identity, user consent or benign intent. Legacy identity modules
are not an interchangeable substitute for the current STIR/SHAKEN verifiers.

## Alternatives

[OpenSIPS](https://opensips.org/) [fraud_detection 3.6](https://docs.opensips.org/manual/3-6/modules/fraud_detection/)
tracks calling patterns such as frequency, concurrent calls, duration, total
calls and sequential destinations against profiles/time windows. This helps
identify toll-fraud behavior; it does not resolve the business behind an inbound
number. Introducing another SIP proxy adds routing and dialog failure domains.
Its 3.6 module API/configuration is not loadable into Kamailio. Reuse the ideas
of windows and thresholds in application code rather than add a SIP hop.

[Rspamd](https://rspamd.com/) is an email filtering framework. Its
[actions and scores](https://docs.rspamd.com/configuration/metrics/),
[composites](https://docs.rspamd.com/configuration/composites/) and
[reputation module](https://docs.rspamd.com/modules/reputation/) offer useful
patterns: independent symbols, configurable weights, correlated-evidence caps,
reputation and explainable outcomes. Email task objects, SMTP actions and mail
reputation are not SIP call classification. Reuse the design, not mail symbols,
mail Redis state or email rejection semantics. Pin a release before any actual
code reuse and review its license; this proposal requires no Rspamd dependency.

## Recommendation

Build a standalone Go service for number normalization, tenant policy, reviewed
business associations, licensing-aware adapters, durable quota accounting and
management. Reuse Kamailio's existing ingress validation, transactions,
internal routing and Homer correlation, then add bounded asynchronous local
HTTP evaluation in a later phase. [ADR 001](adr-001-standalone-go-service.md)
records the decision and tradeoffs.
