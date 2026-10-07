# LiveKit Server

This page documents the intended rendered configuration. It does not claim
that Argo CD has reconciled the changes or that external WebRTC media has been
verified.

The [official LiveKit Server Helm chart](https://github.com/livekit/livekit-helm/tree/master/livekit-server)
is pinned to chart `1.9.0` from the [official `helm.livekit.io` chart repository](https://helm.livekit.io).
It is enabled for the DC1 hub and Home1 by the active
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
The chart is configured for one
[official `livekit/livekit-server` image](https://hub.docker.com/r/livekit/livekit-server)
replica per enabled site, pinned to multi-platform image digest
`sha256:3602a85840d51981808d0519aefca170a3dbe3dec7bc8c5b87cbd52a503ea89f`, with host networking,
required hostname anti-affinity, `Recreate` deployment strategy, and `2` CPU / `2Gi`
requests (`4` CPU / `4Gi` limits). The separate media LoadBalancer uses the
site's existing public-service allocation mechanism: PureLB `core-public` in
YXL and kube-vip with UPnP forwarding in YVR. It receives its address from the
site pool rather than reusing the AVoIP RTPEngine address. LiveKit uses STUN
external-address discovery; after allocation, verify that its advertised
candidate matches the address and inbound NAT path of this Service.

Configured signaling/WebSocket endpoints are `livekit-yxl.mylogin.space` and
`livekit-yvr.mylogin.space`, HTTPS through the
existing `main-gw` / `https-myloginspace` listener and its configured certificate.
The gateway HTTPRoute carries signaling only. Media uses UDP `7882` (LiveKit UDP
mux) and ICE/TCP fallback `7881` on the separate public LoadBalancer; TCP `7880`
is the in-cluster HTTP/signaling backend. The UDP mux avoids using LiveKit's
default UDP range, and both media ports are distinct from the AVoIP RTP ranges.
The chart uses host networking and required pod anti-affinity so the bound ports
cannot collide with another LiveKit replica on the same node.

Redis is configured to use the site's TLS Dragonfly endpoint on `6379`,
database `155`, allocated
in the [Dragonfly logical database registry](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Storage/Dragonfly/CoRE/README.md).
The password comes from the existing site Vault path
`Storage/DragonFly/CoRE/<region>/<datacenter>/<cluster>/Creds`; it is injected
through `LIVEKIT_REDIS_PASSWORD`. ESO creates an API key and secret, persists
them to `AVoIP/LiveKit/<region>/<datacenter>/<cluster>/Creds`, and syncs the
key file into the workload Secret. The Kustomize patch fixes the upstream
chart's absolute key-file mount/Secret subPath mismatch and injects the Redis
environment variable without rendering its value into a ConfigMap.

RTPEngine, Kamailio, and FreeSWITCH are not reused. RTPEngine handles SIP/SDP
media anchoring and does not implement LiveKit's ICE candidate negotiation,
WebRTC transport, or SFU forwarding. Kamailio handles SIP signaling, not
LiveKit's HTTP/WebSocket signaling protocol. FreeSWITCH is the AVoIP PBX/SIP
media endpoint and is not a LiveKit SFU. Nextcloud Talk's Janus/eturnal backend
is also a separate signaling/media stack. These components and AVoIP routes
remain unchanged; LiveKit has its own service and public media ports.

Required site prerequisites are the ESO/CoreVault ClusterSecretStore, the
site-local authenticated TLS Dragonfly endpoint, a public DNS record for each
signaling hostname, a valid certificate on the existing Gateway listener, and
an available public address in each site's PureLB or kube-vip pool. Firewalls
and NAT must permit inbound UDP `7882` and TCP `7881` to the media Service and
the provider must route those ports to its local host-network endpoint. Clients
need outbound access to STUN for external-address discovery. TURN is disabled;
clients behind restrictive NATs may require an independently operated TURN
service, which is not part of this LiveKit Server-only deployment.

The Helm/Lovely render configures one replica, Service/Route resources, TLS
Redis, credentials by secret reference, and media ports. It does not prove the
site load balancer allocated an address, that STUN advertises that address, or
that UDP/TCP media is reachable externally. After reconciliation, check the
Service address, LiveKit ICE candidate logs, Gateway route/certificate status,
Redis ExternalSecret readiness, and a WebRTC call from outside each site.
LiveKit credentials are retained in Vault if the deployment is removed; rotate
or delete them only as a coordinated API-client lifecycle change.

## Upstream references

- [LiveKit website](https://livekit.io/)
- [Self-hosting documentation](https://docs.livekit.io/transport/self-hosting/)
- [Configuration reference](https://docs.livekit.io/transport/self-hosting/deployment/)
- [Official Helm charts](https://github.com/livekit/livekit-helm/tree/master/livekit-server)
- [LiveKit Server source](https://github.com/livekit/livekit)
