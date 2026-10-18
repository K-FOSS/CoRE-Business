#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

helm template core-home1-talos-prod "$repo_root/AVoIP" --namespace core-prod \
  -f "$repo_root/AVoIP/tests/fixtures/outbound-teardown.yaml" \
  > "$temp_dir/helm-output.yaml"
cp "$repo_root/AVoIP/kustomization.yaml" "$temp_dir/kustomization.yaml"
cp -R "$repo_root/AVoIP/patches" "$temp_dir/patches"
yq -y -i '.resources = ["helm-output.yaml"]' "$temp_dir/kustomization.yaml"
kustomize build "$temp_dir" > "$temp_dir/final-render.yaml"

yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.minReadySeconds == 60 and .spec.strategy.type == "RollingUpdate" and .spec.strategy.rollingUpdate.maxUnavailable == 0 and .spec.strategy.rollingUpdate.maxSurge == 1' "$temp_dir/final-render.yaml" >/dev/null
rtpengine_args="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | .args[0]' "$temp_dir/final-render.yaml")"
grep -Fq -- '--redis=' <<< "$rtpengine_args"
! grep -Fq -- '--no-redis-required' <<< "$rtpengine_args"
yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | .readinessProbe.exec.command[-1] == "test -f /tmp/rtpengine-redis-restored"' "$temp_dir/final-render.yaml" >/dev/null
yq -e 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-rtpengine") | .spec.template.spec.containers[] | select(.name == "rtpengine") | any(.volumeMounts[]; .mountPath == "/usr/local/bin/rtpengine-redis-restore-entrypoint.sh" and .readOnly == true)' "$temp_dir/final-render.yaml" >/dev/null
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

echo 'PASS: RTPEngine replacement waits for Redis restoration and 60 seconds of Ready status before advancing'
