#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

helm template flowroute-check "$repo_root/AVoIP" --namespace core-prod \
  --set flowrouteSMS.enabled=false >"$tmp_dir/disabled.yaml"
if grep -Eq 'name: flowroute-check-avoip-flowroute-sms' "$tmp_dir/disabled.yaml"; then
  echo 'Disabling Flowroute SMS must omit its resources' >&2
  exit 1
fi

helm template flowroute-check "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=home1 \
  --set region=yvr \
  --set freeswitch.enabled=false \
  --set flowrouteSMS.enabled=true \
  --set flowrouteSMS.hostname=sms.mylogin.space \
  --set flowrouteSMS.image.repository=forge.example/core/flowroute-sms \
  --set flowrouteSMS.image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set flowrouteSMS.callbackSecret.name=flowroute-check-avoip-sms-callback \
  >"$tmp_dir/enabled.yaml"

for expected in \
  'kind: User' \
  'core-voice-core-home1-talos-prod-yvr' \
  'kind: ExternalSecret' \
  'name: flowroute-check-avoip-sms-callback' \
  'name: flowroute-check-avoip-flowroute-sms' \
  'kind: HTTPRoute' \
  'sms.mylogin.space' \
  "value: '/flowroute/'" \
  'wan-mode: public' \
  'FLOWROUTE_CALLBACK_TOKEN' \
  'DATABASE_URL'; do
  grep -Fq "$expected" "$tmp_dir/enabled.yaml" || {
    echo "Missing expected Flowroute SMS render value: $expected" >&2
    exit 1
  }
done

if helm template flowroute-invalid "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set flowrouteSMS.enabled=true \
  --set flowrouteSMS.hostname=sms.mylogin.space \
  --set flowrouteSMS.image.repository=forge.example/core/flowroute-sms \
  --set flowrouteSMS.image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set flowrouteSMS.callbackSecret.name=flowroute-invalid-avoip-sms-callback \
  >"$tmp_dir/non-primary.yaml" 2>&1; then
  echo 'Flowroute SMS should render only in its configured primary region' >&2
  exit 1
fi

echo 'Flowroute SMS rendering checks passed.'
