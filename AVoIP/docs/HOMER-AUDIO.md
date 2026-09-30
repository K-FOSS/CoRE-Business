# Homer call audio playback

The [Homer 11 project](https://github.com/sipcapture/homer) stores SIP signaling and
RTCP diagnostics. Its [SIPREC receiver](https://github.com/sipcapture/homer/blob/homer11/docs/SIPREC.md)
does not save RTP audio. The AVoIP chart uses [FreeSWITCH `record_session`](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Modules/mod-dptools/6587110/)
to capture answered inbound voice and fax calls as WAV files. A small
[Nginx unprivileged server](https://github.com/nginx/docker-nginx-unprivileged)
in the FreeSWITCH pod serves the recordings at `/recordings/` on the Homer
hostname. The same [Homer HTTPRoute](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
and Authentik Forward Auth policy protect both the UI and the audio.

To play audio inside Homer, open a dashboard, add its **Iframe** panel, and set
the URL to `https://<your-homer-hostname>/recordings/`. The panel lists WAVs by
FreeSWITCH UUID and modification time. Search the call in Homer by SIP Call-ID,
then use its time to find the corresponding WAV. Playback starts when a WAV is
selected. Homer does not automatically attach a file to its call-flow view.

`freeswitch.media.diagnostics.callRecording.enabled` controls both voice/fax
capture and the player route. `homer.recordings.enabled` controls the player
alone. The default recording directory is the retained FreeSWITCH fax spool
PVC, which is `ReadWriteOnce`, `1Gi`, and shared by the FreeSWITCH and Nginx
containers in one pod. The Nginx container removes WAV files older than
`homer.recordings.retentionDays` (2 by default) every six hours; fax TIFFs
are unaffected. This retention is separate from Homer signaling retention.
Watch spool usage while recording is enabled because heavy calling can fill
the PVC before the time limit. Disabling capture stops new WAVs but leaves
existing files until the player next runs its cleanup, or they are removed
under the operator's normal retention procedure.

Audio contains caller content. The player inherits the Homer Authentik
`Home Users` access group; anyone in that group who can use the Homer route
can play retained WAVs. The internal recordings Service has no public load
balancer. The [owning AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
injects cluster values through Lovely and deploys the chart into `core-prod`
for production clusters. The hub and Home1 spoke have FreeSWITCH enabled;
the `dc1-k3s-node1` spoke does not render a player.

To verify, render the chart with the owning ApplicationSet values and confirm
the recordings Service, Nginx container, Homer route rule, and `record_session`
action. After reconciliation, place one answered voice call and one fax test,
then confirm both WAVs appear in the embedded panel and play. Verify an
unauthenticated request to `/recordings/` receives the Authentik challenge.
For rollback, disable `homer.recordings.enabled` to remove playback while
keeping recordings, or disable call recording to stop capture and remove the
route. Neither setting removes the retained fax spool PVC.
