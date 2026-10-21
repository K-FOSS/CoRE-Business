# Admin-managed IVR

The IVR is being moved from a site-wide static extension list to an
AVoIP Admin-managed definition. Admin now stores IVRs in the versioned
`/api/sip` catalog, provides an authenticated shared-audio-library WAV picker,
and validates digit destinations against the existing SIP/provider catalog.
The current deployment has renamed the legacy FreeSWITCH contexts to `ivr`,
`ivr-entry`, and `ivr-targets`; those contexts remain the only active call
execution path. Saving a managed definition does not yet change live call
routing.

## Target model

An IVR definition belongs to a configured DID and site, using the same
provider, caller-ID, tenant, and limit-profile authorization already applied
to DID routing. Each definition contains:

- a greeting selected by stable media-library asset ID;
- a timeout and invalid-input policy;
- ordered digit routes with a structured destination kind: extension, SIP
  endpoint, DID, relayed DID, voicemail, announcement, or hangup;
- destination identifiers validated against the authoritative extension and
  provider catalogs;
- optional prompt and announcement assets from the shared AVoIP audio library.

The API must accept asset IDs and destination identifiers, never FreeSWITCH
XML, channel variables, SIP expressions, or dialstrings. Authorization is
rechecked when a call enters the IVR.

## Runtime boundary

The IVR controller should run as a dedicated FreeSWITCH instance and service,
separate from the routing FreeSWITCH deployment. AVoIP Admin will publish a
validated, versioned IVR snapshot to that instance. The routing stack only
hands an authorized call to the IVR service and does not render arbitrary
Admin data into its own dialplan.

The dedicated instance will follow [FreeSWITCH XML dialplan and mod_xml_curl
documentation](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Modules/mod_xml_curl/)
and use the existing shared [AVoIP audio library](avoip/sound-library.md). It
will:

1. answer the authorized IVR leg;
2. resolve the greeting and announcement asset through the internal audio
   library service;
3. collect DTMF using the configured timeout and retry policy;
4. request a destination action from the validated snapshot;
5. bridge only through the existing authenticated Asterisk/Kamailio/carrier
   routes; and
6. terminate both legs promptly when the caller, destination, or application
   cancels the call.

Snapshot publication must be atomic and versioned. A failed or unavailable
snapshot must fail closed rather than falling back to caller-provided routing
data. Existing DID/provider authorization remains the single outbound
authorization system.

## Migration sequence

1. **Implemented:** Add persisted IVR definitions and digit-route records to
   the Admin catalog, including optimistic versioning and the existing
   catalog-save audit event.
2. **Implemented:** Add the Admin UI and authenticated media-index proxy for
   shared-library selection and structured destination validation.
3. **Remaining:** Add a private snapshot endpoint and dedicated FreeSWITCH deployment with
   authenticated access and a readiness check for the active snapshot.
4. **Remaining:** Route one configured DID through the dedicated instance in a fixture and
   mocked telephony tests.
5. **Remaining:** Migrate existing static IVR entries, verify DTMF and hangup propagation,
   then remove the compatibility definition from the routing dialplan.

Until this migration completes, the static `freeswitch.ivr` values remain the
authoritative fallback and must continue to be reviewed with the normal chart
render and inter-site routing tests.
