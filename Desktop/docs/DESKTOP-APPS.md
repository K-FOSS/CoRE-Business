# Browser desktop application catalog

CoRE Desktop can host Linux GUI applications packaged on the
[LinuxServer Selkies base](https://github.com/linuxserver/docker-baseimage-selkies),
or a custom image built from that base. Prefer a maintained upstream image,
pin it to a reviewed immutable version or digest, and test its persistence,
GPU and browser-input behavior before enabling it here.

## Good candidates

| Area | Application/image | GPU | Notes |
| --- | --- | --- | --- |
| CAD | [FreeCAD](https://docs.linuxserver.io/images/docker-freecad/) (`lscr.io/linuxserver/freecad`) | Recommended | Natural companion to OrcaSlicer; persist `/config` and mount project storage separately if needed. |
| Vector graphics | [Inkscape](https://docs.linuxserver.io/images/docker-inkscape/) (`lscr.io/linuxserver/inkscape`) | Optional | Useful for SVG, laser and CNC preparation. |
| Video | [Kdenlive](https://docs.linuxserver.io/images/docker-kdenlive/) (`lscr.io/linuxserver/kdenlive`) | Recommended | Needs generous shared memory, storage and tested GPU encode/decode. |
| Video | [Shotcut](https://docs.linuxserver.io/images/docker-shotcut/) (`lscr.io/linuxserver/shotcut`) | Recommended | Lighter alternative to Kdenlive. |
| Audio | [Audacity](https://docs.linuxserver.io/images/docker-audacity/) (`lscr.io/linuxserver/audacity`) | Optional | Browser microphone/audio forwarding must be tested end to end. |
| Office | [LibreOffice](https://docs.linuxserver.io/images/docker-libreoffice/) (`lscr.io/linuxserver/libreoffice`) | Optional | Mount only intended document storage; do not expose broad shared filesystems. |
| Browser | [Firefox](https://docs.linuxserver.io/images/docker-firefox/) (`lscr.io/linuxserver/firefox`) | Optional | Useful for isolated browsing or launching an approved SaaS application. |
| Files | [Double Commander](https://docs.linuxserver.io/images/docker-doublecommander/) (`lscr.io/linuxserver/doublecommander`) | No | Explicitly scope every data mount. |
| Disk inspection | [QDirStat](https://docs.linuxserver.io/images/docker-qdirstat/) (`lscr.io/linuxserver/qdirstat`) | No | Data mounts should normally be read-only. |
| E-books | [Calibre](https://docs.linuxserver.io/images/docker-calibre/) (`lscr.io/linuxserver/calibre`) | No | Requires durable library and configuration storage. |
| Database administration | [MySQL Workbench](https://docs.linuxserver.io/images/docker-mysql-workbench/) (`lscr.io/linuxserver/mysql-workbench`) | Optional | Restrict network reachability and database credentials. |
| General workstation | [Webtop](https://docs.linuxserver.io/images/docker-webtop/) (`lscr.io/linuxserver/webtop`) | Optional | Flexible but grants a much broader interactive environment and needs tighter authorization. |
| Gaming | [Steam](https://docs.linuxserver.io/images/docker-steam/) (`lscr.io/linuxserver/steam`) | Required | Browser-accessible Steam client with audio and gamepad forwarding; requires an x86-64 node, durable game storage and an unconfined seccomp profile for game sandboxing. |

LinuxServer GUI images currently expose proxied HTTP on `3000`, HTTPS on
`3001`, store the user's home/configuration under `/config`, and recommend a
memory-backed `/dev/shm`. External HTTPS is required for modern browser media
features. Use `PIXELFLUX_WAYLAND=true` and explicit render-device settings
when GPU acceleration has been validated on the selected nodes.

GPU selection is per desktop. NVIDIA workloads can set `runtimeClassName` and
an NVIDIA node selector. Intel workloads request and limit
`gpu.intel.com/i915: '1'` through the
[Intel GPU device plugin](https://intel.github.io/intel-device-plugins-for-kubernetes/cmd/gpu_plugin/)
and set `DRINODE` plus `DRI_NODE` to `/dev/dri/renderD128`. The device-plugin
request is what schedules the pod onto a node advertising an Intel GPU and
injects the allocated device; do not combine it with the NVIDIA runtime class.

## Steam

[Steam](https://store.steampowered.com/) is deployed from LinuxServer's
[browser-accessible Steam image](https://docs.linuxserver.io/images/docker-steam/).
The image is x86-64 only and remains under active development. Its complete
home directory and installed game library live under `/config`; the default
Steam PVC is therefore 250 GiB. Browser play depends on Selkies audio and
gamepad forwarding. Separate NVIDIA and Intel instances use their respective
GPUs for display and encoding.
The stream is fixed at 120 FPS with H.264 streaming mode enabled and the
paint-over quality pass disabled for motion-heavy content. Steam and each game
must also be configured for a 120 Hz refresh rate, VSync and frame cap as
appropriate; those application settings persist under `/config`.

The NVIDIA instance replaces `/config/.config/labwc/autostart` with a
chart-managed, read-only file that launches `/usr/bin/wrapped-steam
-bigpicture`. It restricts `SELKIES_ENCODER` to the single `x264enc` choice,
which removes the encoder selector, and its H.264 streaming-mode setting uses
Selkies' `true|locked` syntax to keep streaming mode enabled and prevent
changing that boolean in the web UI. The Intel instance retains the image's
normal Steam startup and unlocked encoder and H.264 settings.

The Intel instance uses a dedicated 300 GiB `desktop-rwx` PVC with
`ReadWriteMany` access. Longhorn exposes this generic
[RWX volume](https://longhorn.io/docs/1.12.0/nodes-and-volumes/volumes/rwx-volumes/)
through an NFSv4 share-manager pod. The NVIDIA instance retains its 250 GiB RWO
PVC. RWX permits the Intel volume to be mounted from multiple nodes but does
not make it safe to run multiple Steam writers against the same `/config`; the
controller continues to use a single replica with a `Recreate` strategy.

Steam requests one `nvidia.com/gpu`, uses the `nvidia` RuntimeClass and is
restricted to CUDA 13-capable nodes. It also has a blanket `operator: Exists`
toleration. That toleration accepts every current and future node taint, but it
does not override the architecture, CUDA label or GPU resource requirements.
LinuxServer's Steam image requires proprietary NVIDIA driver 580 or newer,
`nvidia-drm.modeset=1`, `nvidia_drm.fbdev=1` and an initialized DRM device for
Wayland. Confirm those host prerequisites and that the allocated render node is
`/dev/dri/renderD128` before considering the stream healthy.

Steam requires `seccompProfile.type: Unconfined` so Bubblewrap can create the
namespaces used by games. This weakens syscall isolation for only the Steam
container; do not copy the exception to other desktops. The chart does not use
the optional unconfined AppArmor setting. Verify the cluster's admission policy
permits this exception before reconciliation, and test each game's licensing,
anti-cheat and Proton compatibility separately.

## Fusion

[Autodesk Fusion](https://www.autodesk.com/products/fusion-360/overview) has no
supported Linux installation. The preferred integration is a hardened Firefox
desktop launched at `https://fusion.online.autodesk.com`; Autodesk limits the
online application to eligible commercial, startup, TokenFlex, collection and
education entitlements. It is not available with personal-use or trial
licenses. See Autodesk's [browser-access guidance](https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Is-there-a-way-to-access-Fusion-360-via-browser.html)
and [system requirements](https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/System-requirements-for-Autodesk-Fusion-360.html).

If the entitlement does not include browser access, use a separately managed
Windows 11 VM with GPU passthrough and an authenticated low-latency remote
desktop gateway. A Windows VM is outside this Linux container chart's current
deployment model. Wine/Proton images are unsupported experiments and may
break whenever Autodesk updates Fusion, authentication or its embedded
browser.

## Admission checklist

Before adding an entry to `desktops`:

1. Confirm the license permits server-hosted and concurrent remote use.
2. Verify the image source, immutable version, architecture and update notes.
3. Identify `/config`, project-data and removable-device mounts separately.
4. Choose CPU-only or GPU placement and establish resource requests/limits.
5. Add a unique `*.mylogin.space` hostname and exact Authentik redirect URI.
6. Test OIDC denial, WebSocket streaming, file transfer and clipboard policy.
7. Test persistence and rollback without deleting user data.
8. Document any network destinations, credentials, USB access or elevated
   container permissions. Avoid `privileged` and unconfined seccomp unless a
   reviewed exception explicitly requires them.
