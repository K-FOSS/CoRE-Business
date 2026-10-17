# Carrier outbound calling

The desired YVR configuration allows Asterisk SIP Core account `7101` to
place standard NANP calls through the existing carrier Kamailio and Flowroute
connection. The caller ID is sourced from the existing
`carrierOutbound.calls.callerId` value. YXL keeps PSTN call
origination disabled. This route has not yet been reconciled or verified with
a live carrier call.
The [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
configures this policy and the Vault-backed mTLS identities.

## Signaling path

The enabled SIP Core account dials a `+1` E.164 number in Asterisk.
Asterisk sends the call to FreeSWITCH over their existing private TLS peer.
FreeSWITCH bridges through the explicit non-registering `flowroute-tls`
gateway; the separate registered `flowroute` gateway remains UDP for the
Flowroute SIP-REG inbound route. The outbound gateway uses TLS through the
existing internal Kamailio private listener and the carrier Kamailio SIPS
Gateway path. The internal Kamailio validates the FreeSWITCH peer, caller
identity, and destination; carrier Kamailio applies its quota checks and
Flowroute Tech Prefix, then uses the existing carrier-owned RTPEngine path.
Flowroute lists [G.711 and G.729 as supported voice codecs](https://flowroute.com/voice/).
For this bridge, the Flowroute-specific FreeSWITCH `absolute_codec_string`
policy offers PCMU and PCMA by default; PCMA can be omitted while PCMU stays
required. It is set in the per-leg bridge dial string so the variable applies
to the carrier B-leg. The observed runtime showed the earlier A-leg assignment
executing while the carrier SDP still omitted G.711. See the FreeSWITCH
[channel-variable rules](https://developer.signalwire.com/freeswitch/reference/channel-variables/)
and [bridge dial-string syntax](https://developer.signalwire.com/freeswitch/dialplan/dptools/).
FreeSWITCH
keeps the existing Asterisk/WebRTC codec negotiation on its separate A-leg
and must transcode between those legs when their negotiated codecs differ.
Recent YVR logs showed Flowroute rejecting the previous offer, which contained
RTP payload types 107, 101, and 13 but no G.711 payloads, with SIP 488.
Carrier-to-FreeSWITCH traffic continues to use its existing private Service
listener. The public site TLSRoute, global SIP identity, public ACME certificate and its Secret path do
not change; there is no additional TLSRoute, SNI hostname, or Service. The
shared SIPS listener is owned by Backplane's [Ingress ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Network/Ingress.yaml).

The existing public SIPS listener uses an optional client-certificate TLS
profile for its site SNI. The public ACME certificate and its Secret path stay
unchanged. The Certificate already contains that public site name; no extra
SAN is requested.
The private Kamailio trusts the carrier server certificate and presents its
separate Vault client certificate. The carrier trusts the internal Kamailio
client issuer. The chart's network policies restrict the private Kamailio's
5061 egress to the existing Gateway. Carrier ingress is limited to that
Gateway and the existing FreeSWITCH path; the internal request carries
PROXY v2 and is authenticated by its TLS certificate and source range.

Only standard NANP destinations are routed. `+1900` and `+1` 976 service
numbers are rejected. The internal policy first authenticates account `7101`,
then both Kamailio hops set the carrier-facing From and P-Asserted-Identity
from `carrierOutbound.calls.callerId`. The carrier Kamailio prepends the Flowroute
registration username and `*` to the called E.164 user part as Flowroute's
IP-auth Tech Prefix. Flowroute accepts the optional leading `+` in the E.164
user part. That username is read from the existing Vault reference
into a separate username-only Secret and injected only into the carrier
Kamailio pod; it is never rendered into a ConfigMap or logged. See Flowroute's
[IP-based authentication format](https://support.bcmone.com/flowroute-support/docs/set-up-ip-based-authentication-for-outbound-calls).
The existing FreeSWITCH SIP registration remains enabled; adding the prefix
does not change the authentication method. Flowroute IP authentication
requires a static public egress IP and account-side allowlisting. Registration
alone does not grant PSTN access. Carrier-wide Dragonfly quota allows one call per minute
and one concurrent call, with a 600-second maximum lifetime.

The available compact YVR wire-SDP log shows payload numbers from the `m=`
line but omits `a=rtpmap` attributes. The meaning of payload 107 is therefore
not established from the current capture; do not label it Opus based on its
number. The source now logs the full SDP body at Kamailio's final network-send
boundary when the opt-in `kamailio.sipLogging.diagnostics.sdp` switch is on.
That is after carrier RTPEngine rewriting and includes the complete codec
mapping. Keep SIP-message and core debug tracing disabled outside controlled
diagnostics. The scoped codec offer is not validated until the final Flowroute
INVITE shows `PCMU/8000` on payload 0 and compatible `telephone-event/8000`
negotiation on payload 101. An authorized test call must also answer with
two-way audio.

## Configuration and rollout

The owning [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
supplies site-specific peer service names, pod ranges, controller labels,
identity Secret references, and the existing `core-tls-vault` issuer. The
carrier's `peer` values identify the internal Kamailio client. The internal
instance's `peer` values identify the carrier service and its Vault-issued
identity. Both site role entries remain present because
`kamailio.instances[]` is a replace-only list.

Before rollout, verify both Vault certificates and mounted CA bundles, the
carrier's existing SIPS listener, scoped Cilium and Kubernetes network policy,
and the mTLS OPTIONS response. Then verify the caller and destination rejection
cases and quotas. A real carrier call is billable; no automated check places a
public call.

### Post-deployment diagnostics

Use the local Event Socket with its injected Secret value; do not put the
password in shell history or print it. This checks the loaded profiles without
starting a call:

```sh
FREESWITCH_POD="$(kubectl -n core-prod get pods -o name | sed -n '/avoip-freeswitch/p' | head -n 1 | cut -d/ -f2)"
kubectl -n core-prod exec "$FREESWITCH_POD" -c freeswitch -- sh -c \
  'exec fs_cli -H 127.0.0.1 -P 8021 -p "$PASSWORD" -x "$1"' sh 'sofia status'
```

For a controlled carrier test, set `sipLogging.diagnostics.sdp: true` on the
existing YVR `carrier` item in `kamailio.instances[]` in the owning
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml).
That list is replace-only, so preserve its other instance entries. Reconcile
the change through the normal GitOps workflow, read the final post-RTPEngine SDP
and final response from the carrier Kamailio pods, then turn the diagnostic off
again. This output includes RTP addresses and codec mappings; keep it access
restricted.

```sh
for pod in $(kubectl -n core-prod get pods -o name | sed -n '/avoip-kamailio/p'); do
  kubectl -n core-prod logs "$pod" -c kamailio --since=15m \
    | rg 'SIP wire SDP|SIP outbound response'
done
```

Correlate by `linkedid` and the explicit `X-Core-*` IDs in new source logs.
Each SIP B2BUA can create a new Call-ID, so matching browser, Asterisk,
FreeSWITCH, and carrier legs by Call-ID alone is incorrect. Existing YVR logs
do not establish that browser-facing 486 responses and carrier-facing 488
responses belong to the same calls.

YXL keeps its direct public SIP Service disabled. Do not enable a direct
Service to use this Gateway path. It does not add a public LoadBalancer or
carrier ACL entry.

Rollback is to set `carrierOutbound.enabled: false` on the two Kamailio role
entries and reconcile the reviewed ApplicationSet. That removes the private
peer route and associated mTLS policy while preserving the public SIP route,
public certificate, Flowroute trunk, and existing FreeSWITCH connection.
Existing quota keys expire by the configured maximum duration; do not flush
the shared Dragonfly database.
