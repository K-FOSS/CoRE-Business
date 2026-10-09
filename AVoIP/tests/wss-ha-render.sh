#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
pilot="$(mktemp)"
cutover="$(mktemp)"
invalid="$(mktemp)"
asterisk_file="$(mktemp)"
trap 'rm -f "$rendered" "$pilot" "$cutover" "$invalid" "$asterisk_file"' EXIT

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" > "$rendered"

assert_yq() {
  local query="$1"
  local description="$2"
  local input="${3:-$rendered}"
  if ! yq -e "$query" "$input" >/dev/null; then
    printf 'FAIL: %s\n' "$description" >&2
    exit 1
  fi
}

assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-wss") | .spec.replicas == 3 and .spec.serviceName == "core-home1-talos-prod-avoip-kamailio-internal-wss-owner" and .spec.template.spec.securityContext.fsGroup == 1000' 'three stable WSS StatefulSet replicas use their own headless owner service and writable non-root drain volume'
assert_yq 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal") | .spec.replicas == 1' 'the existing private-sbc remains a separate single-replica Deployment'
assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-wss") | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .lifecycle.preStop.exec.command[-1] | test("touch /tmp/kamailio-draining;.*ws.disable.*sleep 130")' 'preStop marks the owner draining, disables new websocket handshakes and waits through the configured grace interval'
assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-wss") | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .readinessProbe.exec.command[-1] | contains("kamailio-draining")' 'readiness removes draining owners from new Envoy selection'
assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-wss") | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .livenessProbe.exec.command[-1] | (contains("kamailio-draining") | not)' 'liveness continues to treat a healthy draining process as alive'
assert_yq 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss") | .spec.selector["avoip.mylogin.space/kamailio-instance"] == "internal-wss" and (.spec.ports[] | select(.port == 8088 and .appProtocol == "kubernetes.io/ws"))' 'the Envoy backend Service selects only the dedicated WSS instance on port 8088'
assert_yq 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-owner") | .spec.clusterIP == "None" and .spec.publishNotReadyAddresses == true and .spec.ports[].port == 5063' 'owner routing uses the WSS headless TLS service and keeps draining pod DNS addressable'
assert_yq 'select(.kind == "PodDisruptionBudget" and .metadata.name == "core-kamailio-internal-wss") | .spec.minAvailable == 2' 'two WSS replicas remain available during voluntary disruption'
assert_yq 'select(.kind == "HTTPRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-wss") | .spec.hostnames == ["sipcore.mylogin.space"] and .spec.rules[0].matches[0].path.value == "/ws" and .spec.rules[0].backendRefs[0].name == "core-home1-talos-prod-avoip-kamailio-internal-wss" and .spec.rules[0].timeouts.request == "0s" and .spec.rules[0].timeouts.backendRequest == "0s"' 'the existing route selects the separate WSS instance with unchanged host/path and unbounded request duration'
assert_yq 'select(.kind == "BackendTrafficPolicy" and (.metadata.name | test("kamailio-internal-wss-sipcore-wss-timeouts$"))) | .spec.timeout.http.streamIdleTimeout == "1h"' 'HTTP stream idle timeout remains bounded at one hour'
assert_yq 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-sip-policy") | .spec.ingress[0].fromEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"] == "kube-system" and .spec.ingress[0].fromEndpoints[0].matchLabels["app.kubernetes.io/name"] == "envoy" and .spec.ingress[0].toPorts[0].ports[0].port == "8088"' 'WSS Cilium authorization remains restricted to the observed Envoy identity on 8088'
assert_yq 'select(.kind == "Certificate" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-sip-tls") | .spec.dnsNames[] | select(. == "*.core-home1-talos-prod-avoip-kamailio-internal-wss-owner.core-prod.svc.cluster.local")' 'TLS SAN covers stable per-pod WSS owner DNS names'

config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-config") | .data["kamailio.cfg"]' "$rendered")"
tls_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-config") | .data["tls.cfg"]' "$rendered")"
private_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$rendered")"
! grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' <<<"$private_config"
! grep -Fq 'loadmodule "websocket.so"' <<<"$private_config"
grep -Fq '#!substdef "/SIPCORE_OWNER_POD/$env(POD_NAME)/"' <<<"$config"
grep -Fq 'loadmodule "path.so"' <<<"$config"
grep -Fq 'modparam("path", "use_received", 0)' <<<"$config"
grep -Fq 'loadmodule "outbound.so"' <<<"$config"
grep -Fq 'if (!add_path_received())' <<<"$config"
grep -Fq 'SIPCORE_OWNER_POD.core-home1-talos-prod-avoip-kamailio-internal-wss-owner.core-prod.svc.cluster.local' <<<"$config"
grep -Fq 'sipcore.mylogin.space' <<<"$config"
grep -Fq 'https://home.mylogin.space' <<<"$config"
grep -Fq 'Host Not Allowed' <<<"$config"
grep -Fq 'Origin Not Allowed' <<<"$config"
grep -Fq 'record_route_preset("SIPCORE_OWNER_POD.' <<<"$config"
grep -Fq 'listen=tls:0.0.0.0:5062' <<<"$config"
! grep -Eq 'listen=(udp|tcp|tls):[^[:space:]]+:5061' <<<"$config"
grep -Fq 'server_name = core-home1-talos-prod-avoip-kamailio-internal-wss-owner.core-prod.svc.cluster.local' <<<"$tls_config"
grep -Fq 'verify_certificate = yes' <<<"$tls_config"
grep -Fq 'require_certificate = yes' <<<"$tls_config"

grep -Fq 'support_path=yes' "$rendered"
grep -Fq 'max_contacts=2' "$rendered"
grep -Fq 'auth_type=userpass' "$rendered"
grep -Fq 'username=7101' "$rendered"
grep -Fq 'outbound_proxy=sip:127.0.0.1:1' "$rendered"
! grep -Fq 'outbound_proxy=sip:core-home1-talos-prod-avoip-kamailio-internal-wss-sipcore-return' "$rendered"
grep -Fq 'type=auth' "$rendered"
grep -Fq 'context=from-sipcore-7101' "$rendered"
grep -Fq 'exten => 9090,1,Answer()' "$rendered"
grep -Fq 'exten => 66,1,Dial(PJSIP/gg-audio@freeswitch,30,g)' "$rendered"
grep -Fq 'exten => 1234,1,Answer()' "$rendered"

asterisk_init="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("asterisk"))) | .spec.template.spec.containers[] | select(.name == "asterisk") | .args[0]' "$rendered")"
printf '%s\n' "$asterisk_init" > "$asterisk_file"
sh -n "$asterisk_file"
if grep -Eiq 'password=[A-Fa-f0-9]{32,}' "$rendered"; then
  echo 'FAIL: a literal SIP password appeared in rendered manifests' >&2
  exit 1
fi

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-pilot.yaml" \
  --set asterisk.sipCore.ingressKamailioInstance=internal-wss > "$pilot"
assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-wss") | .spec.replicas == 1' 'a single-replica WSS pilot can coexist with the existing private-sbc Deployment' "$pilot"
assert_yq 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal") | .spec.replicas == 1' 'the legacy connection owner remains a single Deployment' "$pilot"
assert_yq 'select(.kind == "HTTPRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-wss") | .spec.rules[0].backendRefs[0].name == "core-home1-talos-prod-avoip-kamailio-internal-wss"' 'pilot can receive new WSS connections through its independent Service while Asterisk keeps the legacy return instance selected' "$pilot"
assert_yq 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-sip-policy") | .spec.ingress[0].fromEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"] == "kube-system" and .spec.ingress[1].fromEndpoints[0].matchLabels["app.kubernetes.io/controller"] == "asterisk"' 'the WSS pilot accepts only the configured Envoy and Asterisk workload identities' "$pilot"
wss_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-wss-config") | .data["kamailio.cfg"]' "$pilot")"
grep -Fq 'if ($proto == "ws" && $Rp == 8088)' <<<"$wss_config"
grep -Fq 'route(FROM_SIPCORE);' <<<"$wss_config"
grep -Fq '"rtpengine_sock"' <<<"$wss_config"
grep -Fq 'core-home1-talos-prod-avoip-rtpengine.core-prod.svc.cluster.local' <<<"$wss_config"
ws_route_line="$(grep -nF 'if ($proto == "ws" && $Rp == 8088)' <<<"$wss_config" | head -1 | cut -d: -f1)"
peer_guard_line="$(grep -nF 'Peer Not Authorized' <<<"$wss_config" | head -1 | cut -d: -f1)"
if [[ -z "$ws_route_line" || -z "$peer_guard_line" || "$ws_route_line" -ge "$peer_guard_line" ]]; then
  echo 'FAIL: dedicated WSS edge must route SIP Core WebSocket traffic before the generic private peer guard' >&2
  exit 1
fi
legacy_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$pilot")"
grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' <<<"$legacy_config"
! grep -Fq 'loadmodule "path.so"' <<<"$legacy_config"
grep -Fq 'loadmodule "outbound.so"' <<<"$legacy_config"
grep -Fq 'check_flow_token()' <<<"$legacy_config"
rm -f "$pilot"

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-pilot.yaml" \
  --set asterisk.sipCore.kamailioInstance=internal-wss \
  --set kamailio.instances[1].websocketHA.legacyOwner=true \
  --set kamailio.instances[2].replicas=3 \
  --set kamailio.instances[2].websocketHA.pilot=false \
  --set kamailio.instances[2].websocketHA.podDisruptionBudget.minAvailable=2 \
  --set-string kamailio.instances[2].websocketHA.legacyReturnServiceName=core-home1-talos-prod-business-kamailio-internal-sipcore-return.core-prod.svc.cluster.local > "$cutover"
assert_yq 'select(.kind == "HTTPRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-wss") | .spec.rules[0].backendRefs[0].name | test("internal-wss$")' 'the controlled cutover points the existing route at the separate HA WSS Service' "$cutover"
assert_yq 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-sipcore-return") | .spec.publishNotReadyAddresses == true and .spec.ports[].port == 5063' 'the legacy migration return address remains available to saved contacts while its pod drains' "$cutover"
grep -Fq 'outbound_proxy=sip:core-home1-talos-prod-business-kamailio-internal-sipcore-return.core-prod.svc.cluster.local:5063' "$cutover"
legacy_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$cutover")"
grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' <<<"$legacy_config"
grep -Fq 'loadmodule "ctl.so"' <<<"$legacy_config"
grep -Fq 'route[FROM_SIPCORE_ASTERISK]' <<<"$legacy_config"
legacy_tls="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["tls.cfg"]' "$cutover")"
grep -Fq 'server_name = core-home1-talos-prod-avoip-kamailio-internal-sipcore-return.core-prod.svc.cluster.local' <<<"$legacy_tls"
rm -f "$cutover"

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-pilot.yaml" \
  --set asterisk.sipCore.kamailioInstance=internal-wss \
  --set asterisk.sipCore.ingressKamailioInstance=internal \
  --set kamailio.instances[1].websocketHA.legacyOwner=true \
  --set kamailio.instances[2].replicas=3 \
  --set kamailio.instances[2].websocketHA.pilot=false \
  --set kamailio.instances[2].websocketHA.podDisruptionBudget.minAvailable=2 \
  --set-string kamailio.instances[2].websocketHA.legacyReturnServiceName=core-home1-talos-prod-business-kamailio-internal-sipcore-return.core-prod.svc.cluster.local > "$cutover"
assert_yq 'select(.kind == "HTTPRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-wss") | .spec.rules[0].backendRefs[0].name == "core-home1-talos-prod-avoip-kamailio-internal"' 'rollback can move new WSS connections to legacy while keeping Asterisk Path authority active' "$cutover"
grep -Fq 'support_path=yes' "$cutover"
rm -f "$cutover"

if helm template invalid-wss "$chart_dir" --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set asterisk.sipCore.routeTimeouts.request=forever >"$invalid" 2>&1; then
  echo 'FAIL: invalid WSS route duration rendered successfully' >&2
  exit 1
fi
grep -Fq 'routeTimeouts.request must be 0s or a positive duration' "$invalid"

helm template duplicate-topos-secret "$chart_dir" --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set kamailio.instances[2].name=internal-websocket \
  --set asterisk.sipCore.kamailioInstance=internal-websocket \
  --set kamailio.instances[2].topology.redis.secretName=avoip-kamailio-internal-topos >"$invalid"
assert_yq 'select(.kind == "ExternalSecret" and .metadata.name == "avoip-kamailio-internal-topos") | .spec.target.template.data.server | contains("db=52")' 'the existing private SBC keeps its TOPOS Secret and database' "$invalid"
assert_yq 'select(.kind == "ExternalSecret" and .metadata.name == "avoip-kamailio-internal-websocket-topos") | .spec.target.template.data.server | contains("db=53")' 'a repeated TOPOS Secret name is derived per instance while retaining its allocated database' "$invalid"
assert_yq 'select(.kind == "StatefulSet" and .metadata.name == "core-kamailio-internal-websocket") | .spec.template.spec.containers[] | select(.name == "kamailio-internal-websocket") | .env[] | select(.name == "TOPOS_REDIS_SERVER") | .valueFrom.secretKeyRef.name == "avoip-kamailio-internal-websocket-topos"' 'the WebSocket pod consumes its derived TOPOS Secret' "$invalid"

if helm template invalid-topos-database "$chart_dir" --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set kamailio.instances[2].name=internal-websocket \
  --set asterisk.sipCore.kamailioInstance=internal-websocket \
  --set kamailio.instances[2].topology.redis.secretName=avoip-kamailio-internal-topos \
  --set kamailio.instances[2].topology.redis.database=52 >"$invalid" 2>&1; then
  echo 'FAIL: duplicate TOPOS database rendered successfully' >&2
  exit 1
fi
grep -Fq 'Kamailio internal-websocket shares TOPOS database 52 with internal; assign a separate site-local database' "$invalid"

if helm template invalid-replicas "$chart_dir" --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set kamailio.instances[2].websocketHA.enabled=false >"$invalid" 2>&1; then
  echo 'FAIL: multiple replicas without HA rendered successfully' >&2
  exit 1
fi
grep -Fq 'cannot use multiple replicas unless websocketHA.enabled is true' "$invalid"

if helm template invalid-envoy-port "$chart_dir" --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set asterisk.sipCore.httpPort=8089 >"$invalid" 2>&1; then
  echo 'FAIL: mismatched Envoy WSS backend port rendered successfully' >&2
  exit 1
fi
grep -Fq 'requires asterisk.sipCore.httpPort=8088' "$invalid"

echo 'WSS HA render checks passed'
