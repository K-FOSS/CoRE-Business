# Homer call audio playback

The [Homer 11 project](https://sipcapture.github.io/homer/) stores SIP signaling and
RTCP diagnostics in this deployment. It does not store RTP audio. The AVoIP
chart uses [FreeSWITCH `record_session`](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Modules/mod-dptools/6587110/)
to capture answered inbound voice and fax calls as WAV files. A small
[Nginx unprivileged server](https://github.com/nginx/docker-nginx-unprivileged)
in the FreeSWITCH pod serves them at `/recordings/` on the site's Homer
hostname. The [Homer HTTPRoute](../templates/Homer/HomerRoute.yaml) and
Authentik Forward Auth policy protect both the UI and the audio.

To play audio inside Homer, open a dashboard, add its **Iframe** panel, and set
the URL to `https://<site-homer-hostname>/recordings/`. By default the hostname
is `homer.<cluster>.<datacenter>.<region>.resolvemy.host`. The panel lists WAVs
by FreeSWITCH UUID and modification time. Search the SIP call by Call-ID, then
use its time to find the corresponding WAV. Playback starts when a WAV is
selected. Homer does not automatically attach the file to its call-flow view.

The player container, recording Service, and `/recordings/` route render only
when Homer, Kamailio, FreeSWITCH, `homer.recordings.enabled`, and
`freeswitch.media.diagnostics.callRecording.enabled` are all enabled.
`homer.recordings.enabled` can remove playback without stopping FreeSWITCH
capture. The default recording directory is the retained FreeSWITCH fax spool
PVC, which is `ReadWriteOnce`, `1Gi`, and shared by the FreeSWITCH and Nginx
containers in one pod.

While the player container runs, its cleanup loop deletes WAV files older than
`homer.recordings.retentionDays` (2 by default) every six hours; fax TIFFs are
unaffected. This is separate from the 14-day Homer trace retention. Heavy
calling can fill the spool before cleanup. If either recording or playback is
disabled, the player container and its cleanup loop stop; existing WAVs remain
on the retained spool until an operator removes them or playback is restored.

Audio contains caller content. The player inherits the Homer Authentik
`Home Users` access group; anyone in that group who can use the Homer route
can play retained WAVs. The internal recordings Service has no public load
balancer. The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
enables FreeSWITCH on the hub and Home1 spoke. Homer is disabled on
`dc1-k3s-node1`, so that spoke does not render a player.

To verify, render the chart with the owning ApplicationSet values and confirm
the recordings Service, Nginx container, Homer route rule, and `record_session`
action. After reconciliation, place one answered voice call and one fax test,
then confirm both WAVs appear in the embedded panel and play. Verify an
unauthenticated request to `/recordings/` receives the Authentik challenge.
For rollback, disable `homer.recordings.enabled` to remove playback while
keeping capture, or disable `freeswitch.media.diagnostics.callRecording.enabled`
to stop capture and remove the player route. Neither setting deletes the
retained fax spool PVC or its existing WAVs.
