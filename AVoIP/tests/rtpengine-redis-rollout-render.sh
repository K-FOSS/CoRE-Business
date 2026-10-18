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

echo 'PASS: RTPEngine replacement retains the prior pod until Redis-backed startup is Ready for 60 seconds'
