#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

helm template routr-check "$repo_root/AVoIP" --namespace core-prod >"$tmp_dir/disabled.yaml"
if grep -Eq 'name: routr-check-avoip-routr-(apiserver|location|registry)|fonoster/routr-' "$tmp_dir/disabled.yaml"; then
  echo 'Routr workloads rendered while routr.enabled=false' >&2
  exit 1
fi

location_digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
registry_digest='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
helm template routr-check "$repo_root/AVoIP" --namespace core-prod \
  --set routr.enabled=true \
  --set "routr.imageDigests.location=$location_digest" \
  --set "routr.imageDigests.registry=$registry_digest" \
  >"$tmp_dir/enabled.yaml"

for expected in \
  'kind: User' \
  'routr-check-avoip-routr-redis-config' \
  'dbNumber=155' \
  'dbNumber=156' \
  'fonoster/routr-location:2.13.6@sha256:' \
  'fonoster/routr-registry:2.13.6@sha256:' \
  'routr-check-avoip-routr-migrations'; do
  grep -Fq "$expected" "$tmp_dir/enabled.yaml" || {
    echo "Missing expected Routr render value: $expected" >&2
    exit 1
  }
done

if grep -Eq 'kind: (Deployment|StatefulSet|Service)[[:space:]]*$' "$tmp_dir/enabled.yaml" && \
   grep -Eq 'name: routr-check-avoip-(postgresql|redis)' "$tmp_dir/enabled.yaml"; then
  echo 'Routr must use shared PostgreSQL and Dragonfly, not bundled databases' >&2
  exit 1
fi

if helm template routr-invalid "$repo_root/AVoIP" --namespace core-prod \
  --set routr.enabled=true >/dev/null 2>&1; then
  echo 'Routr enablement without immutable patched image digests should fail' >&2
  exit 1
fi

if helm template routr-invalid "$repo_root/AVoIP" --namespace core-prod \
  --set routr.enabled=true \
  --set "routr.imageDigests.location=$location_digest" \
  --set "routr.imageDigests.registry=$registry_digest" \
  --set routr.edgeport.udp.enabled=true >/dev/null 2>&1; then
  echo 'Routr EdgePort listeners should fail until TLS and ingress policy support is implemented' >&2
  exit 1
fi

if helm template routr-invalid "$repo_root/AVoIP" --namespace core-prod \
  --set routr.enabled=true \
  --set "routr.imageDigests.location=$location_digest" \
  --set "routr.imageDigests.registry=$registry_digest" \
  --set routr.redis.locationDatabase=0 >/dev/null 2>&1; then
  echo 'Routr must reject non-allocated Dragonfly logical database values' >&2
  exit 1
fi

echo 'Routr Connect rendering checks passed.'
