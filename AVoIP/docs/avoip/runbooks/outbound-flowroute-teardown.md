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
carrier-peer dialog after loose routing. A live BYE on 2026-10-17 exposed the
remaining fault: the restored Contact pointed to the FreeSWITCH owner at
`172.20.57.142:5081` with UDP transport. TM logged a forced TLS socket versus
UDP destination mismatch and returned `-7`. The private tier now selects a
TLS destination URI using the restored owner IP and port, while leaving the
Request-URI, Route headers and dialog identifiers intact. It rejects a
restored target that is not an owner IP on the Flowroute profile's TLS port.
The Flowroute FreeSWITCH bridge also advertises `transport=tls` in its Contact
for new calls. Its separate Flowroute registration remains on UDP.

The incident's `(7/TM)` is the TM response to `t_relay()=-7`. The original
trace did not include its internal TM debug line. The later controlled call
did: `get_send_socket2()` reported `forced tls:172.20.57.57:5062, to
udp:172.20.57.142:5081`, followed by “no corresponding listening socket.”
This confirms the transport mismatch. A send socket selection alone cannot
change the destination transport inferred from the Contact URI.

TM retransmission matching now runs before BYE teardown effects in both tiers.
A repeated BYE is handled by the transaction cache before quota release or
RTPEngine deletion can run again. The private tier logs TOPOS/loose-route
results, route direction, destination, socket and relay return value. The
carrier tier logs the RTPEngine deletion request. These are route/render
findings; a live carrier-originated BYE and returned 200 OK are still required
for operational acceptance.

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
private TLS destination and socket, the FreeSWITCH Contact parameter,
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
FS_DEPLOY='core-home1-talos-prod-business-avoip-prod-avoip-freeswitch'

kubectl --context "$SITE_CONTEXT" -n "$NS" logs -l "app=$CARRIER_APP" \
  -c kamailio --prefix --since=10m | rg -F "$CALL_ID"
kubectl --context "$SITE_CONTEXT" -n "$NS" logs -l "app=$INTERNAL_APP" \
  -c kamailio --prefix --since=10m | rg -F "$CALL_ID"
kubectl --context "$SITE_CONTEXT" -n "$NS" logs "deploy/$FS_DEPLOY" \
  -c freeswitch --since=10m | rg -F "$CALL_ID"

POD='<one-internal-kamailio-pod>'
kubectl --context "$SITE_CONTEXT" -n "$NS" exec "$POD" -c kamailio -- \
  kamcmd -s unix:/tmp/kamailio_ctl core.tcp_info
kubectl --context "$SITE_CONTEXT" -n "$NS" exec "$POD" -c kamailio -- \
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
