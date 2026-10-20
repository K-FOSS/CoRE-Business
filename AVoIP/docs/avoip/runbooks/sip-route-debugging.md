# Trace a SIP route to its Kubernetes endpoint

Use this runbook to follow one SIP transaction from the selected Kamailio route
through the chosen local socket to the remote address and Kubernetes pod. The
logs identify the SIP next hop and the resolved wire destination separately:
`next_hop` is the configured `$du`, `destination_ip` and `destination_port` are
the actual send target, and `pod` identifies the Kamailio sender. For a Service
next hop, use EndpointSlices to map the address to a backing pod. For a carrier
or an inter-site peer outside this cluster, the destination address will not
map to a local EndpointSlice.

## Map a Service to endpoint IPs and pods

Run these read-only commands against the cluster handling the call. Set
`SERVICE` to the Kubernetes Service name seen in the `next_hop` field and
`NAMESPACE` to its namespace:

```sh
kubectl -n "$NAMESPACE" get svc "$SERVICE" -o wide
kubectl -n "$NAMESPACE" get endpointslices \
  -l "kubernetes.io/service-name=$SERVICE" \
  -o 'custom-columns=SLICE:.metadata.name,READY:.endpoints[*].conditions.ready,ADDRESSES:.endpoints[*].addresses[*],TARGETS:.endpoints[*].targetRef.name'
kubectl -n "$NAMESPACE" get pods -o wide
```

EndpointSlice `ADDRESSES` and `TARGETS` give the authoritative service-IP to
pod mapping, including readiness. `kubectl get pods -o wide` adds node placement,
readiness and restart counts. Check that the Service selector matches the
target pods when it has no ready endpoints. Do not infer the selected backend
from a Deployment replica count alone.

## Correlate a call

Filter logs using the Call-ID or the repository's sanitized Call-ID hash from
the support trace. Inspect the same transaction on the carrier and internal
Kamailio instances and the FreeSWITCH/Asterisk logs. For a BYE, follow these
events in order:

1. Kamailio dialog decision: the selected route, `$du` next hop and local
   socket.
2. `SIP BYE wire attempt`: sender pod, route URI, next hop, connection, local
   socket and actual destination IP/port.
3. SIP response for that transaction, including its status and direction.
4. `SIP media teardown` and RTPEngine result, which are media cleanup evidence
   and do not prove the remote SIP user agent ended its dialog.
5. The corresponding response or dialog termination at the other SIP endpoint.

An accepted BYE transaction proves that the next SIP hop replied. Confirm the
far endpoint's dialog termination separately; do not treat RTPEngine deletion
or a local `200 OK` as proof that a handset disconnected.

Avoid enabling full message-body or SDP logging to obtain route information.
The structured wire request fields provide route and destination details
without dumping SIP authorization headers or call content.

## Availability checks

For each call-signaling hop, compare desired and ready replicas, PodDisruption
Budget and Service endpoint counts. Check that replicas land on separate nodes
when the site has enough nodes. Treat an endpoint count of one as a single
failure domain even when the Deployment is healthy. Media relay capacity is a
separate availability path: confirm the RTPEngine Service has ready endpoints
and check RTPEngine's own health and call statistics. Multiple Kamailio pods do
not make a single RTPEngine pod highly available.

SIP connection ownership, dialog routing and media state determine whether a
component can safely run multiple replicas. Do not increase replicas by itself
as an incident fix; validate the specific role's shared state, affinity,
readiness and draining behavior first.
