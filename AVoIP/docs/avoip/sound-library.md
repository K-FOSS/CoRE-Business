# Shared AVoIP sound library

The chart provisions one retained `ReadWriteMany` PVC named
`<release>-audio-library` from the existing `avoip-homer-rwx` StorageClass.
The class is the AVoIP chart's existing Longhorn class, configured with two
replicas. The separate PVC keeps prompt files out of Homer's database and call
recordings. Longhorn RWX uses a cluster-local share manager, so each active
cluster has its own library; files do not replicate between DC1/YXL and
Home1/YVR. See [Longhorn RWX volumes](https://longhorn.io/docs/1.9.1/volumes-and-nodes/volumes/rwx-volumes/).

When Asterisk and FreeSWITCH are enabled, both mount the PVC read-only and the
audio library web service mounts it read-write. Asterisk reads prompts as
`Playback(avoip-shared/<name>)` (without the `.wav` suffix); FreeSWITCH reads
`playback /usr/share/freeswitch/sounds/avoip-shared/<name>.wav`. Files must use a mono, 8 kHz,
16-bit PCM WAV format. The browser editor uses the [Web Audio API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API)
to record microphone audio, import WAV, preview it, trim a selection, and save
normalized WAV to the shared volume. It is intended for short IVR prompts
rather than multitrack editing.

Open `https://<Homer hostname>/audio-library/`. The route reuses Homer's
Authentik Forward Auth provider and `Home Users` access group. The browser asks
for microphone access when recording; microphone capture requires a
[secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)
and user permission. The
[NGINX unprivileged image](https://github.com/nginx/docker-nginx-unprivileged)
serves the editor and uses its built-in [WebDAV PUT support](https://nginx.org/en/docs/http/ngx_http_dav_module.html)
to write WAV files. Access is limited by the route's fail-closed Envoy
SecurityPolicy and a Cilium ingress policy allowing only the Envoy Gateway
data-plane pods.

The name field accepts 1–64 ASCII letters, digits, hyphens, and underscores.
Saving an existing name asks before replacing it; changing a saved name affects
playback for both PBX services. Coordinate edits with other operators because
the last completed save wins. The route's group authorization permits members
to upload and replace prompts; do not store private recordings or credentials
in this library.

The PVC has `Retain` reclaim behavior and Argo CD prune/delete protection. If
the editor or AVoIP release is disabled, the chart removes the workload and its
mounts while retaining the sound files. To verify a rollout, inspect the
release's PVC for `Bound` and `ReadWriteMany`, confirm the audio-library pod is
ready, then record and save a short test prompt and play it from Asterisk or
FreeSWITCH. Do not use a production prompt name for the first save.

The active owner is the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
which renders this chart through Lovely for the selected production clusters.
