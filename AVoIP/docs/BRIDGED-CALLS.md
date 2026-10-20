# Bridged calls

The optional **Bridged calls** page is served by the existing AVoIP Admin web
application at `/calls`. Authentik's `AVoIP Users` group can reach this page;
the existing `AVoIP Admins` group retains the administration screens and can
inspect all call rows. The page uses the server's authenticated Authentik
identity and never accepts an owner, group, SIP credential, or FreeSWITCH
dialstring from the browser.

## Current implementation

The feature is enabled with `avoipAdmin.bridgedCalls.enabled` and also requires
managed routing and the existing private FreeSWITCH Event Socket integration.
The default is disabled until the site ApplicationSet supplies those values.
The owner is the existing [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml).

Calls are stored in PostgreSQL by the existing Admin schema initializer. Each
row has an application UUID, owner, callback and extension identifiers, caller
ID/provider selection, UTC execution time, display timezone, cancellation
intent, version, preallocated callback/extension UUIDs, and sanitized outcome
fields. Append-only lifecycle events are stored in
`avoip_bridged_call_events`; saved callback destinations are owner-scoped in
`avoip_callback_destinations`.

Administrators can read `/metrics` for status counts and active bridge count;
structured application logs include the application call ID, callback UUID,
provider, and state transitions without logging full callback numbers.

The worker claims due calls with `FOR UPDATE SKIP LOCKED`. A 15-minute lateness
grace marks overdue calls failed as `missed`; it does not place an old call
after an outage. Creation uses an owner/idempotency-key uniqueness constraint.
Origination is deliberately at-least-once across PostgreSQL and FreeSWITCH:
the UUID is allocated before Event Socket origination and an uncertain Event
Socket result is not retried automatically. Cancellation and rescheduling use
row locks and status predicates so a pending row cannot be executed after a
successful race winner.

External callbacks use the catalog's authorized extension/provider/caller-ID
route and the existing FreeSWITCH gateway path. Internal callback destinations
use the existing `sofia/gateway/asterisk/<extension>` route, so FreeSWITCH does
not assume direct registration. The callback is answered, optionally collects
DTMF `1` using FreeSWITCH `play_and_get_digits`, and only then bridges the
authorized extension. `hangup_after_bridge=true` and `bridge_answer_timeout`
ensure that either leg ends the bridge and that extension no-answer/busy paths
do not leave the callback leg hanging. FreeSWITCH's documented
[bridge channel variables](https://developer.signalwire.com/freeswitch/reference/channel-variables/)
and [XML dialplan](https://developer.signalwire.com/freeswitch/dialplan/xml/)
are the source for these controls.

## Configuration

Set the following in the site-owned values layer, after confirming the current
storage and PostgreSQL ApplicationSets: [PostgreSQL](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
and the relevant [storage base](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Base.yaml).

```yaml
avoipAdmin:
  enabled: true
  routing:
    enabled: true
  telephony:
    enabled: true
    freeswitch:
      eventSocketAddress: 'private-freeswitch:8021'
      eventSocketSecret: {name: 'existing-secret', key: 'secret'}
  bridgedCalls:
    enabled: true
    confirmationRequired: true
```

The example secret name is illustrative only and must be replaced by an
existing protected Secret reference; no credential belongs in Git. The chart
validates that bridging cannot be enabled without both managed routing and the
private Event Socket configuration. The internal Event Socket remains bound to
loopback in the FreeSWITCH pod and is reached only through the existing private
management path; it is not exposed through the Gateway.

## Manual acceptance test

Use a test account, an authorized extension/caller ID, and a non-production
callback endpoint unless an operator has explicitly approved a billable call.
Verify the current [SIP routing architecture](SIP-ROUTING-ARCHITECTURE.md) and
the [outbound path](OUTBOUND-PILOT.md) first.

1. Call now: the callback answers and presses `1`; the extension answers and
   both parties have audio.
2. Hang up the callback; confirm the extension leg terminates promptly.
3. Hang up the extension; confirm the callback leg terminates and the carrier
   receives SIP teardown.
4. Let the callback reach voicemail without pressing `1`; confirm the
   extension never rings.
5. Use a busy or unanswered extension; confirm the callback receives the
   configured short outcome and ends.
6. Schedule one call with multiple Admin replicas; confirm one origination and
   one application event history.
7. Race cancellation and restart a worker; confirm no orphaned UUIDs remain.

Automated validation uses a mocked boundary for UUID generation and structured
originate construction plus Go unit tests for extension disablement, timezone
format, idempotency keys, and command safety. It does not place a PSTN call.

## Release gate

The existing SIP hangup-propagation issue is a release-blocking dependency.
The [Flowroute teardown runbook](avoip/runbooks/outbound-flowroute-teardown.md)
contains the demonstrated delayed-BYE failure and the required cross-boundary
verification. A call may not be declared production-ready from the UI state or
from local media stopping alone; a real carrier trace must show the BYE and
`200 OK` through FreeSWITCH, Kamailio, RTPEngine, and the carrier boundary.
