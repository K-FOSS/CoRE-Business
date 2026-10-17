# Outbound Flowroute dialog teardown

The active [AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml)
renders a three-replica carrier Kamailio tier and a separate `internal`
private-SBC. The tiers use site-local TOPOS stores in Dragonfly databases 51
and 52. Reconciliation and shared Dragonfly ownership remain in Backplane;
this chart supplies each tier's routes and Secret references.

## Routing correction

An outbound INVITE crosses both Kamailio tiers. The carrier tier restores its
TOPOS state and forwards a carrier-originated in-dialog request to the
authenticated `carrier` peer on the internal tier. The internal tier then
restores its own TOPOS state and consumes its route set. That tier binds only
`private_tls`; it does not bind the carrier tier's `public_tls` socket. The
private route explicitly selects `private_tls` for this authenticated
carrier-peer dialog after loose routing. An earlier 2026-10-17 BYE trace
restored a UDP Contact and returned `t_relay()=-7` because it forced a TLS
socket to a UDP destination. The route now validates the restored owner IP and
listener port, retains the Request-URI, Route headers and dialog identifiers,
and sets only the destination URI to TLS. It rejects restored targets outside
the owner-IP/Flowroute-TLS-listener contract.

The later 08:43 call still restored
`sip:gw+flowroute@172.20.63.198:5081;transport=udp`, but the current route
selected `sip:172.20.63.198:5081;transport=tls` and logged
`t_relay_result=1`. The internal transaction then timed out without a
FreeSWITCH response. This shows that the UDP Contact remains inconsistent,
but the latest no-response cannot be attributed to a local `-7` transport
mismatch. The missing TCP/TLS receive and Sofia timestamps remain necessary.

The current source selects the non-registering `flowroute-tls` gateway for
all outbound NANP calls, with `register-transport=tls` and the Flowroute
profile's 5081 TLS listener. The existing `flowroute` gateway remains
registered over UDP for Flowroute's SIP-REG inbound route. No outbound
dialplan path selects that UDP registration gateway. Both gateway entries
are generated from the same ExternalSecret template, and the FreeSWITCH
controller already watches that Secret and the Flowroute client certificate
for reloader-triggered pod rollout. This explicit selection corrects the
Contact inconsistency; earlier calls on the same TLS-gateway pattern also
timed out, so it is not considered a proven fix for intermittent delivery.

The first live call after that transport correction reached the FreeSWITCH
owner pod over TLS but failed certificate verification. The owner presented a
certificate for the FreeSWITCH service hostname issued by the site-internal
root, while the internal Kamailio client default trusted only the system CA
bundle. The internal tier now selects an SNI-specific client profile for that
FreeSWITCH hostname, verifies it against the existing site peer CA, and
presents its existing Vault-issued client identity. TLS verification stays on.

The historical incident's `(7/TM)` was the TM response to `t_relay()=-7`.
The later controlled trace showed `get_send_socket2()` reporting `forced
tls:172.20.57.57:5062, to udp:172.20.57.142:5081`, followed by “no
corresponding listening socket.” That confirms the earlier local transport
mismatch. In the 08:43 call, the later route explicitly selected a TLS
destination and queued successfully, yet no FreeSWITCH response appeared.
The two observations identify distinct failure modes; the first does not
explain the second.

TM retransmission matching now runs before BYE teardown effects in both tiers.
A repeated BYE is handled by the transaction cache before quota release or
RTPEngine deletion can run again. The private tier logs TOPOS/loose-route
results, route direction, restored target, selected destination transport,
TLS server name, socket, immediate relay result, and a transaction-failure
marker. When diagnostics are enabled, its `onsend_route` logs the BYE
connection ID, protocol, local tuple and destination as a **send attempt**, not
confirmed delivery. Carrier-side teardown logs RTPEngine deletion and its
result. These route logs do not prove that FreeSWITCH received or parsed the
BYE; operational acceptance still requires boundary capture and a genuine
FreeSWITCH 200 OK reaching Flowroute.

## Local checks

Run from the CoRE-Business repository root:

```sh
AVoIP/tests/outbound-teardown-render.sh
helm lint AVoIP
helm template core-home1-talos-prod AVoIP --namespace core-prod \
  -f AVoIP/tests/fixtures/outbound-teardown.yaml > /tmp/avoip-outbound-teardown.yaml
mkdir -p /tmp/avoip-lovely-check/patches
cp AVoIP/kustomization.yaml /tmp/avoip-lovely-check/kustomization.yaml
cp AVoIP/patches/* /tmp/avoip-lovely-check/patches/
cp /tmp/avoip-outbound-teardown.yaml /tmp/avoip-lovely-check/helm-output.yaml
yq -y -i '.resources = ["helm-output.yaml"]' /tmp/avoip-lovely-check/kustomization.yaml
kustomize build /tmp/avoip-lovely-check > /tmp/avoip-final-render.yaml
test -s /tmp/avoip-final-render.yaml
```

The render test checks both instance configs, independent TOPOS stores, the
private TLS destination, socket and CA profile, the FreeSWITCH Contact parameter,
preserved SIP targets, TM relay diagnostics and retransmission guards. The
Kustomize command validates the local post-Helm
overlay syntax only; deployment output must still be rendered through the
owning Lovely Application with its injected site values and pipeline order.

For the Kamailio 6.1.4 parser, extract each generated `kamailio.cfg` from the
rendered YAML and run it with the pinned runtime image. Set `POD_IP` and
`POD_NAME` to harmless values and use throwaway TLS files. The `ndb_redis`
module may connect during child initialization even in config-check mode, so
provide an isolated temporary Redis-compatible endpoint or report that part
of the parser check as unavailable. Never copy the production Secret value
into shell history or logs. A dummy endpoint validates syntax and module
loading, not the TOPOS schema, Dragonfly ACL, or live topology state.

## Live acceptance

Run one controlled call after the reviewed config has reconciled. The current
Home1 path is Asterisk SIP Core → FreeSWITCH → internal Kamailio → carrier
Kamailio → Flowroute. Use a test destination allowed by the active site policy.
Do not enable raw SIP logging; the new route logs and Homer are sufficient.

```sh
SITE_CONTEXT='<site-kube-context>'
NS='core-prod'
CALL_ID='<Call-ID from Homer>'
CARRIER_APP='core-home1-talos-prod-business-avoip-prod-avoip-kamailio'
INTERNAL_APP='core-home1-talos-prod-business-avoip-prod-avoip-kamailio-internal'
FS_INSTANCE='core-home1-talos-prod-business-avoip-prod'

kubectl --context "$SITE_CONTEXT" -n "$NS" logs -l "app=$CARRIER_APP" \
  -c kamailio --prefix --since=10m | rg -F "$CALL_ID"
kubectl --context "$SITE_CONTEXT" -n "$NS" logs -l "app=$INTERNAL_APP" \
  -c kamailio-internal --prefix --since=10m | rg -F "$CALL_ID"
kubectl --context "$SITE_CONTEXT" -n "$NS" logs \
  -l "app.kubernetes.io/instance=$FS_INSTANCE,app.kubernetes.io/controller=freeswitch" \
  -c freeswitch --prefix --since=10m | rg -F "$CALL_ID"

POD='<one-internal-kamailio-pod>'
kubectl --context "$SITE_CONTEXT" -n "$NS" exec "$POD" -c kamailio-internal -- \
  kamcmd -s unix:/tmp/kamailio_ctl core.tcp_info
kubectl --context "$SITE_CONTEXT" -n "$NS" exec "$POD" -c kamailio-internal -- \
  kamcmd -s unix:/tmp/kamailio_ctl dlg.dlg_list "$CALL_ID" '2j898vF7vcDFa'

RTP_POD='<rtpengine-pod>'
kubectl --context "$SITE_CONTEXT" -n "$NS" exec "$RTP_POD" -c rtpengine -- \
  rtpengine-ctl list sessions
```

`core.tcp_info` shows current TCP/TLS connections. `dlg.dlg_list` is available
on instances loading the dialog module; it is local process state, not a
cluster-wide dialog registry. Check TOPOS restoration from the structured
`private-topos-restore` log and the site Dragonfly's DB 51/52 health without
printing its credential or dumping unrelated keys. In Homer, search the exact
Call-ID and inspect the SIP ladder plus the Kamailio route events.

Confirm all of the following in the same Call-ID trace:

1. **Flowroute-originated BYE:** carrier replica receives it; internal tier
   logs `topos_result=route-restored`, a successful loose route, selects
   `private_tls` and a `;transport=tls` destination to the restored owner pod,
   and FreeSWITCH receives that same BYE. FreeSWITCH returns a
   genuine `200 OK`, which traverses both Kamailio tiers to Flowroute.
2. **FreeSWITCH-originated BYE:** initiate hangup locally. Flowroute receives
   the BYE and returns 200; its route set and TLS transport remain intact.
3. **Cross-replica:** use separate established calls whose INVITE, 2xx ACK and
   Flowroute BYE are observed on different carrier replicas. Each remote BYE
   must restore through shared TOPOS state and reach the original FreeSWITCH
   pod Contact.
4. **Immediate retransmission:** retransmit the same BYE (same branch/CSeq).
   TM returns the cached final response; only one `rtpengine_delete=requested`
   event and one FreeSWITCH dialog teardown occur.
5. **Cleanup timer race:** after a carrier BYE succeeds, wait beyond the
   configured local cleanup interval. No second local BYE or Flowroute 481
   appears.
6. **Session refresh:** keep a separate call up across the existing 90-second
   WebRTC refresh. UPDATE and its 200 OK continue through the same dialog
   route.
7. **Media and CDR:** after either BYE direction, `rtpengine-ctl list sessions`
   no longer shows the call's session; an unrelated test call remains. The
   FreeSWITCH CDR records `NORMAL_CLEARING`/remote clearing, and Homer shows
   one completed teardown.

Reject the run if internal logs contain `t_relay_result=-7`, if a synthetic
response is returned without FreeSWITCH receiving BYE, if a duplicate BYE or
carrier 481 follows, or if the CDR/media state does not match the SIP ladder.
Save the Call-ID, UTC time range, pod names and sanitized log excerpts with the
change record. Do not include SIP credentials, full SDP, or Secret values.

## Rollback

Revert the reviewed routing/logging change in Git and reconcile only the
owning AVoIP ApplicationSet and its affected child Application. Existing
dialogs keep their established routes; verify rollback behavior with a fresh
call. Do not directly patch the live Deployment or broaden its peer policy.
