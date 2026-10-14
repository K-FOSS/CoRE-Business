# FreeSWITCH voicemail

The AVoIP chart has an opt-in voicemail mailbox for the configured direct
Asterisk SIP Core extension. The route keeps FreeSWITCH as the public call
entry point, bridges the call to Asterisk, and runs the mailbox if the bridge
ends without the caller hanging up. The mailbox owner can dial `*97` from the
configured SIP Core extension and enter the mailbox PIN. In the mailbox menu,
press `5` for configuration and `6` to change the PIN. FreeSWITCH stores the
changed PIN in its voicemail database in PostgreSQL; this overrides the
initial directory PIN from CoreVault. Email notifications are off.

The feature is disabled by default. Enable `freeswitch.voicemail.enabled` in
the site values supplied through the owning
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
It requires Asterisk SIP Core, a configured `inboundVoiceExtension`, and a
matching CoreVault-backed extension entry. Add a `VoicemailPIN` property to
that extension's existing CoreVault secret for the initial PIN. Use a PIN of
4–12 digits. The chart fetches that property through an ExternalSecret; the
PIN itself must never be put in Helm values or the repository.
`freeswitch.voicemail.pinProperty` can select a different property name if
needed. Until the property exists, the ExternalSecret will not produce the
Secret needed by FreeSWITCH. After the subscriber changes the PIN from the
mailbox menu, the PostgreSQL value takes precedence, so changing the CoreVault
property alone will not reset it.

FreeSWITCH's built-in voicemail preference table stores the changed PIN in
its `password` field. Limit PostgreSQL access to the FreeSWITCH service
identity and trusted database operators. The profile rejects empty-PIN
authentication.

FreeSWITCH stores voicemail message metadata in the PostgreSQL database
provided by its `User.mylogin.space/v1alpha1` claim, using the deployed
`mod_pgsql` database interface. The voicemail audio and greetings are stored
on a retained `ReadWriteMany` PVC. Its storage class defaults to
`freeswitch.fax.persistence.haStorageClass` (`avoip-homer-rwx` in the current
chart defaults); `freeswitch.voicemail.storageClass` can override it. This
lets both active FreeSWITCH replicas access mailbox audio. The default claim
size is `1Gi`.

This interim filesystem arrangement is the live mailbox store. It does not
write voicemail audio directly to S3. The separate S3-compatible
`mod_http_cache` feature can GET and PUT objects, but `mod_voicemail` does not
use it as its mailbox filesystem automatically. See the [FreeSWITCH voicemail
module](https://developer.signalwire.com/freeswitch/applications/voicemail/),
[FreeSWITCH PostgreSQL support](https://developer.signalwire.com/freeswitch/configuration/core-settings/),
and [`mod_http_cache`](https://developer.signalwire.com/freeswitch/reference/vanilla-config-map/).

## Validation after enabling

Render the complete Lovely application with the site's injected values and
confirm that the output contains:

- The FreeSWITCH `User` claim with PostgreSQL enabled.
- The voicemail ExternalSecret referencing the extension's configured
  `VoicemailPIN` property, without a literal PIN.
- A retained `ReadWriteMany` voicemail PVC using the existing site storage
  class, mounted at the configured voicemail path in each FreeSWITCH replica.
- `mod_pgsql` and `mod_voicemail` loads, a PostgreSQL voicemail DSN, a mailbox
  directory entry, and the `*97` dialplan route.
- `db-password-override` enabled and empty-PIN authentication disabled.
- An Asterisk route that sends `*97` to FreeSWITCH only from the mailbox
  owner's authenticated SIP Core context.

After deployment, verify the ExternalSecret and `User` claim conditions, PVC
mounts on both replicas, FreeSWITCH module/database startup, and the complete
call flow: a 30-second unanswered call, the keypad PIN mailbox check, message
recording, retrieval, and caller cancellation before answer. Those runtime
checks have not been performed by this repository change.
