# AVoIP inbound routing

The deployed [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
assigns two site-local DIDs to neutral routing roles: `dids.asterisk` and
`dids.ivr`. The values come from Vault references supplied by Lovely; do not
put resolved numbers in Git or this page. The current YXL `asterisk` route is
sent to YVR extension `7101` over the existing carrier Kamailio mTLS link.
Both sites' `ivr` route enters a sample menu in local FreeSWITCH.

## Call routing

1. Flowroute sends the call to the site's carrier Kamailio. The carrier
   source CIDR check runs before either DID can be routed.
2. On YXL, a call to `dids.asterisk` matches the exact configured user part.
   Kamailio sends it over the existing TLS/mTLS connection to YVR carrier
   ClusterIP `10.44.7.136:5061`, with destination extension `7101`.
3. YVR carrier Kamailio verifies the YXL client certificate and pod CIDR,
   allows only extension `7101`, and marks the request for the authorized
   cross-site route. YVR FreeSWITCH requires that marker before bridging to
   the authenticated Asterisk gateway. Asterisk rings SIP Core extension
   `7101`.
4. At either site, a call to `dids.ivr` is answered by FreeSWITCH. The sample
IVR plays its configured introduction, accepts one DTMF digit,
and plays one of the configured example prompts before returning to the
menu. `0` plays the goodbye prompt and hangs up; unsupported digits play the
   invalid-entry prompt. FreeSWITCH voice outbound remains rejected.
5. YVR's `dids.asterisk` route uses its local FreeSWITCH-to-Asterisk gateway;
   the Asterisk `from-external` context maps that exact DID to extension `7101`.

The old fax/voice DID distinction is no longer used in the chart routing.
There is no dedicated fax DID route or automatic CNG detection on an inbound
number. The separate fax receive configuration remains available for future
explicit routing, but no DID currently selects it. This change does not remove
the retained fax spool.

The sample IVR settings are under `freeswitch.ivr` in
[values.yaml](../values.yaml). They define the introduction, menu, invalid and
goodbye prompts, DTMF attempts and timeout, and digit/prompt pairs. Upload these
files to each site's existing shared sound library at
`https://<Homer hostname>/audio-library/`: `ivr-menu.wav`, `ivr-choices.wav`,
`ivr-invalid.wav`, `ivr-goodbye.wav`, and `ivr-message-1.wav` through
`ivr-message-3.wav`. `ivr-choices.wav` should announce the choices for digits
1–3 and 0. Files must be mono 8 kHz PCM WAV; see the
[sound library guide](avoip/sound-library.md). The chart references the
site-local library and contains no audio assets. Until these files are uploaded,
FreeSWITCH cannot play the IVR prompts. The chart keeps the menu in the public
context but only matches the explicitly assigned IVR DID; unmatched public
destinations continue to be rejected.

## Trust and operations

The YXL-to-YVR transfer is configured on the carrier Kamailio instance under
`interSite.transfers`. Both peers use their existing Vault-issued client
identities. The receiving Kamailio checks the peer certificate SAN and pod
CIDR, and FreeSWITCH requires the marker from that authenticated route before
bridging extension `7101`. The YXL direct public SIP Service remains disabled.
See the [inter-site voice guide](INTERSITE-VOICE.md) for the trust path,
verification and rollback.

After reconciliation, render both Lovely site value layers and inspect the
resulting DID matches without exposing resolved Secret values. Verify the
YXL transfer resolves to the YVR ClusterIP and extension `7101`, YVR accepts
only that extension from YXL, and the FreeSWITCH IVR contains each configured
prompt. Then place an operator-approved inbound test call to each route and
verify the Asterisk ring and IVR audio/DTMF behavior. A successful render or
pod readiness alone does not prove media playback.

Unmatched destinations are rejected. Public SIP signaling remains on
Kamailio, while FreeSWITCH is not exposed as a carrier-facing SIP endpoint.
See [SIP identity](SIP-IDENTITY.md) for transport and dialog routing details.
