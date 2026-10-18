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

The NGINX WAV-file location quotes its regex so the `{0,63}` quantifier remains
part of the pattern when NGINX parses the generated configuration. The focused
render check is `AVoIP/tests/sound-library-nginx-render.sh`; run `nginx -t` with
the generated configuration and the deployed image before accepting a rollout.
The editor's exact trailing-slash route aliases the HTML directory and serves
`index.html` from it, avoiding a duplicate `index.html` suffix during NGINX's
index lookup.

The PVC has `Retain` reclaim behavior and Argo CD prune/delete protection. If
the editor or AVoIP release is disabled, the chart removes the workload and its
mounts while retaining the sound files. To verify a rollout, inspect the
release's PVC for `Bound` and `ReadWriteMany`, confirm the audio-library pod is
ready, then record and save a short test prompt and play it from Asterisk or
FreeSWITCH. Do not use a production prompt name for the first save.

The active owner is the [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
which renders this chart through Lovely for the selected production clusters.

## YVR and YXL deployments

YVR/Home1 and YXL/DC1 each run their own audio-library editor and have a
separate site-local PVC. As of 2026-10-17 22:57 UTC, both editor pods were
ready (`1/1`) with zero restarts, and both 5 GiB PVCs were `Bound` with
`ReadWriteMany` access on `avoip-homer-rwx`. The pod readiness probe requests
the trailing-slash editor path, so this confirms the NGINX health check is
passing at both sites.

`IVRGreet.wav` was present in both mounted libraries at that check. The
observed files had different SHA-256 checksums, confirming that the site-local
volumes held different versions then. The YVR and YXL libraries do not
replicate or synchronize files automatically. Upload or replace prompts at
each site separately; when a prompt is intended to be identical, compare its
checksum after uploading it to both libraries. The chart references the
FreeSWITCH greeting by filename and does not package or distribute its audio
bytes.

The YVR `IVRGreet.wav` prompt was subsequently loaded from the sound library
and played successfully through FreeSWITCH. This verifies the YVR FreeSWITCH
mount and playback path. The sound editor and library have also been confirmed
to authenticate through Authentik only. Playback through Asterisk and playback
at YXL have not been verified here.
