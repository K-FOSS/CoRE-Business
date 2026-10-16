# Asterisk voicemail

The direct FaxNumber call rings the configured Asterisk SIP Core extension for
30 seconds. If the endpoint is busy or does not answer, Asterisk plays its
voicemail greeting and records the message. A caller cancellation does not
start voicemail. While the unavailable greeting is playing, a caller can press
`0` to open the mailbox login, then enter a mailbox number and PIN. A caller
reaching the voice IVR can also dial `*97` to reach that login. The mailbox
owner can dial `*97` from their authenticated SIP Core account to open their
own mailbox. The mailbox menu can change that PIN; Asterisk stores mailbox
credentials in the Asterisk PostgreSQL database. Email delivery is disabled.

The public `*97` route is available only at sites where Asterisk voicemail is
enabled. It uses `VoiceMailMain()` without the option to skip authentication,
so callers must enter both a mailbox number and its PIN. Sites without
voicemail enabled do not accept this IVR destination.

Enable `asterisk.voicemail.enabled` in the site values supplied through the
owning [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The chart accepts the former `freeswitch.voicemail.enabled` setting as a
temporary compatibility alias. New site values should use the Asterisk key.
The feature requires Asterisk SIP Core, a configured `inboundVoiceExtension`,
and a matching CoreVault-backed extension entry. Add a `VoicemailPIN` property
to the `AVoIP/SIPCore/VoiceMail` CoreVault secret's `Pin` property for the
initial PIN. The secret key and property are configurable through
`asterisk.voicemail.pinSecret.remoteKey` and
`asterisk.voicemail.pinSecret.property`. The PIN value is never placed in Helm
values or the repository. The seed process inserts the
initial PIN only for a new mailbox; later changes in the mailbox remain in
PostgreSQL across pod restarts.
The chart does not copy a PIN previously changed in FreeSWITCH's own voicemail
database. Asterisk initializes from the CoreVault PIN; subscribers can then
change it in the Asterisk mailbox menu.

FreeSWITCH continues to receive public carrier calls and bridge the FaxNumber
call to Asterisk. It no longer loads `mod_voicemail`, stores recordings, or
provides the mailbox menu. Asterisk uses `app_voicemail_odbc` to store message
audio as PostgreSQL binary data, and Asterisk Realtime stores mailbox settings
and the changeable PIN in the same database provisioned by its
`User.mylogin.space/v1alpha1` claim. The voicemail schema is created by the
Asterisk PostgreSQL init container. Email addresses and attachments are
disabled.

The chart-local [Asterisk image build](../image/asterisk/Containerfile) keeps
the upstream [andrius/asterisk image](https://hub.docker.com/r/andrius/asterisk)
as its base and adds the `asterisk-odbc` module package, unixODBC, and the
PostgreSQL ODBC driver. It also retains the PostgreSQL, ALSA, English sounds,
music-on-hold, Speex, and SRTP module packages used by the existing image. The
[Forgejo workflow](../../.forgejo/workflows/asterisk.yaml) builds and publishes
only to this repository's Forgejo registry. The chart checks for the ODBC
voicemail module and configured driver at startup and exits with a clear error
if either is missing.

This change does not copy existing FreeSWITCH audio files into PostgreSQL.
The old FreeSWITCH voicemail PVC is retained by its `Prune=false,Delete=false`
policy if it already exists; old messages remain on that volume for manual
export or rollback. New messages go to PostgreSQL. The mailbox PIN seed is
idempotent and will not overwrite a PIN that was changed from the Asterisk
mailbox menu.

## Validation after enabling

Render the complete Lovely application with site-injected values and confirm
that the output contains:

- The Asterisk `User` claim with PostgreSQL enabled.
- The voicemail ExternalSecret referencing the configured CoreVault PIN
  property, without a literal PIN.
- Asterisk ODBC, Realtime, and `app_voicemail_odbc` configuration, with
  credentials generated from the Asterisk connection Secret at runtime.
- The voicemail and voicemail message tables, `*97` mailbox route, and
  unanswered FaxNumber fallback in Asterisk. Where voicemail is enabled, the
  FreeSWITCH IVR accepts `*97` and bridges it to Asterisk's mailbox login; the
  Asterisk `o` extension sends greeting-time `0` to the same login.
- No FreeSWITCH voicemail module, dialplan, or volume mount.

After deployment, verify the `User` and ExternalSecret conditions, ODBC driver
availability, Asterisk module and database startup, and the full call flow:
ringing, no answer, message recording, pressing `0` during the unavailable
greeting to reach mailbox and PIN prompts, inbound IVR `*97`, rejection of a
wrong PIN, PIN change and persistence after restart, caller cancellation
before answer, busy endpoint, and caller hangup during recording. Those
runtime checks have not been performed.

See the [Asterisk voicemail configuration](https://github.com/asterisk/asterisk/blob/20/configs/samples/voicemail.conf.sample),
[Asterisk VoiceMailMain application](https://docs.asterisk.org/Asterisk_20_Documentation/API_Documentation/Dialplan_Applications/VoiceMailMain/),
[Asterisk ODBC voicemail schema](https://github.com/asterisk/asterisk/tree/20/contrib/ast-db-manage/voicemail),
[Asterisk Realtime configuration](https://docs.asterisk.org/Fundamentals/Asterisk-Configuration/Database-Support-Configuration/Realtime-Database-Configuration/),
and [Asterisk ODBC setup](https://docs.asterisk.org/Configuration/Interfaces/Back-end-Database-and-Realtime-Connectivity/ODBC/Configuring-res_odbc/).
