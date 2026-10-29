#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

helm template core-home1-talos-prod "$repo_root/AVoIP" --namespace core-prod \
  -f "$repo_root/AVoIP/tests/fixtures/outbound-teardown.yaml" \
  --set freeswitch.flowrouteOutbound.kamailioInstance=internal \
  --set avoipAdmin.enabled=false \
  > "$temp_dir/helm-output.yaml"
cp "$repo_root/AVoIP/kustomization.yaml" "$temp_dir/kustomization.yaml"
cp -R "$repo_root/AVoIP/patches" "$temp_dir/patches"
yq -y -i '.resources = ["helm-output.yaml"]' "$temp_dir/kustomization.yaml"
kustomize build "$temp_dir" > "$temp_dir/final-render.yaml"

yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.replicas == 3 and .spec.minReadySeconds == 60 and .spec.strategy.type == "RollingUpdate" and .spec.strategy.rollingUpdate.maxUnavailable == 0 and .spec.strategy.rollingUpdate.maxSurge == 1 and .spec.template.spec.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight == 100' "$temp_dir/final-render.yaml" >/dev/null
yq -e 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.trafficDistribution == "PreferSameNode"' "$temp_dir/final-render.yaml" >/dev/null
yq -e 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "core-home1-talos-prod-avoip-rtp-valkey-network") | .metadata.namespace == "valkey-operator-system" and .spec.endpointSelector.matchLabels["valkey.io/cluster"] == "avoip-rtpengine" and any(.spec.ingress[]; any(.toPorts[].ports[]; .port == "16379"))' "$temp_dir/final-render.yaml" >/dev/null
operator_ports="$(yq -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "core-home1-talos-prod-avoip-rtp-valkey-network") | .spec.ingress[] | select(any(.fromEndpoints[]?.matchLabels; .["app.kubernetes.io/name"] == "valkey-operator")) | .toPorts[].ports[].port' "$temp_dir/final-render.yaml")"
grep -Fxq '6379' <<< "$operator_ports"
grep -Fxq '16379' <<< "$operator_ports"
rtpengine_args="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | .args[0]' "$temp_dir/final-render.yaml")"
grep -Fq -- '--redis=' <<< "$rtpengine_args"
! grep -Fq -- '--no-redis-required' <<< "$rtpengine_args"
grep -Fq -- '--timeout=120' <<< "$rtpengine_args"
grep -Fq -- '--silent-timeout=3600' <<< "$rtpengine_args"
grep -Fq -- '--offer-timeout=120' <<< "$rtpengine_args"
grep -Fq -- '--final-timeout=300' <<< "$rtpengine_args"
yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | .readinessProbe.exec.command[-1] == "test -f /tmp/rtpengine-redis-restored"' "$temp_dir/final-render.yaml" >/dev/null
yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | any(.volumeMounts[]; .mountPath == "/usr/local/bin/rtpengine-redis-restore-entrypoint.sh" and .readOnly == true)' "$temp_dir/final-render.yaml" >/dev/null
kamailio_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$temp_dir/final-render.yaml")"
assert_rtpengine_param() {
  local param="$1"
  local value="$2"
  local block
  block="$(grep -A4 -F "\"$param\"," <<< "$kamailio_config")"
  grep -Fq "$value" <<< "$block"
}
assert_rtpengine_param rtpengine_disable_tout '  2'
assert_rtpengine_param aggressive_redetection '  1'
assert_rtpengine_param rtpengine_tout_ms '  300'
assert_rtpengine_param rtpengine_retr '  2'
assert_rtpengine_param ping_mode '  1'
assert_rtpengine_param ping_interval '  2'
grep -Fq 'RTPEngine SIP Core trickle ICE update failed callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl' <<< "$kamailio_config"
grep -Fq 'RTPEngine SIP Core Asterisk trickle ICE update failed callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl' <<< "$kamailio_config"
restore_entrypoint="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine-redis-restore-gate") | .data["redis-restore-entrypoint.sh"]' "$temp_dir/final-render.yaml")"
grep -Fq "Redis restore time =" <<< "$restore_entrypoint"
grep -Fq 'rtpengine-redis-restored' <<< "$restore_entrypoint"
mkdir -p "$temp_dir/restore-gate-test"
RTPENGINE_REDIS_RESTORE_REQUIRED=true \
RTPENGINE_RESTORE_MARKER="$temp_dir/restore-gate-test/restored" \
RTPENGINE_RESTORE_OUTPUT_PIPE="$temp_dir/restore-gate-test/output" \
  /bin/sh "$repo_root/AVoIP/files/rtpengine/redis-restore-entrypoint.sh" \
    /bin/sh -c 'printf "%s\n" "Redis restore time = 25 ms"'
test -f "$temp_dir/restore-gate-test/restored"

echo 'PASS: RTPEngine replacement waits for Redis restoration; Kamailio retries timed-out control commands and probes for endpoint recovery'
