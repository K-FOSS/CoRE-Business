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
  'name: flowroute-check-avoip-flowroute-sms-webhook' \
  'name: flowroute-check-avoip-flowroute-sms-api' \
  'name: flowroute-check-avoip-flowroute-sms-web' \
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

dns_rows="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("flowroute-sms"))) | [.metadata.name, ([.spec.template.spec.dnsConfig.options[]? | select(.name == "ndots") | .value] | join(","))] | @tsv' "$tmp_dir/enabled.yaml")"
[[ -n "$dns_rows" ]] || { echo 'No Flowroute SMS deployment was rendered for DNS validation' >&2; exit 1; }
while IFS=$'\t' read -r name ndots; do
  [[ "$ndots" == '0' ]] || {
    echo "Flowroute SMS deployment $name does not use ndots 0" >&2
    exit 1
  }
done <<< "$dns_rows"

rollout_rows="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("flowroute-sms"))) | [.metadata.name, .spec.strategy.type, (.spec.strategy.rollingUpdate.maxSurge | tostring), (.spec.strategy.rollingUpdate.maxUnavailable | tostring), .spec.template.spec.containers[0].startupProbe.httpGet.path, .spec.template.spec.containers[0].livenessProbe.httpGet.path, .spec.template.spec.containers[0].readinessProbe.httpGet.path] | @tsv' "$tmp_dir/enabled.yaml")"
[[ -n "$rollout_rows" ]] || { echo 'No Flowroute SMS deployment was rendered' >&2; exit 1; }
while IFS=$'\t' read -r name strategy surge unavailable startup liveness readiness; do
  [[ "$strategy" == 'RollingUpdate' && "$surge" == '1' && "$unavailable" == '0' ]] || {
    echo "Flowroute SMS deployment $name does not preserve availability during rollout" >&2
    exit 1
  }
  [[ "$startup" == '/healthz' && "$liveness" == '/healthz' && -n "$readiness" ]] || {
    echo "Flowroute SMS deployment $name does not render startup, liveness, and readiness checks" >&2
    exit 1
  }
done <<< "$rollout_rows"

if helm template flowroute-invalid "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set flowrouteSMS.enabled=true \
  --set flowrouteSMS.image.repository=forge.example/core/flowroute-sms \
  --set flowrouteSMS.image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set flowrouteSMS.callbackSecret.name=flowroute-invalid-avoip-sms-callback \
  >"$tmp_dir/non-primary.yaml" 2>&1; then
  echo 'Secondary-site SMS must not claim the default primary hostname' >&2
  exit 1
fi

helm template flowroute-yxl "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set freeswitch.enabled=false \
  --set flowrouteSMS.enabled=true \
  --set flowrouteSMS.hostname=sms-yxl.mylogin.space \
  --set flowrouteSMS.media.hostname=sms-media-yxl.mylogin.space \
  --set flowrouteSMS.media.endpoint=https://s3.core-home1-talos-prod.home1.yvr.mylogin.space \
  --set flowrouteSMS.media.existingCredentials=true \
  --set flowrouteSMS.media.credentialsSecretName=core-dc1-talos-prod-core-storage-s3-tenant-prod-core-home1-talos-prod-providercreds \
  --set flowrouteSMS.media.accessKeyKey=AWS_ACCESS_KEY_ID \
  --set flowrouteSMS.media.secretKeyKey=AWS_SECRET_ACCESS_KEY \
  --set flowrouteSMS.databaseHost=psql.core-dc1-talos-prod.dc1.yxl.mylogin.space \
  --set flowrouteSMS.legacyFlowroute.enabled=false \
  >"$tmp_dir/yxl.yaml"
yq -e 'select(.kind == "User" and .metadata.name == "core-voice-core-dc1-talos-prod-yxl") | .spec.psql.hostname == "psql.core-dc1-talos-prod.dc1.yxl.mylogin.space" and .spec.psql.crossplane.terraformProvider == "psql" and .spec.psql.crossplane.crossplaneProvider == "psql-main"' "$tmp_dir/yxl.yaml" >/dev/null
yq -e 'select(.kind == "User" and .metadata.name == "core-voice-core-dc1-talos-prod-yxl") | .spec | has("s3") | not' "$tmp_dir/yxl.yaml" >/dev/null
yq -e 'select(.kind == "HTTPRoute" and (.metadata.name | contains("flowroute-sms-media"))) | .spec.hostnames == ["sms-media-yxl.mylogin.space"]' "$tmp_dir/yxl.yaml" >/dev/null
yq -e 'select(.kind == "HTTPRoute" and (.metadata.name | contains("flowroute-sms")) and (.metadata.name | contains("media") | not) and (.metadata.name | contains("inbox") | not)) | .spec.hostnames == ["sms-yxl.mylogin.space"]' "$tmp_dir/yxl.yaml" >/dev/null
if grep -Fq 'FLOWROUTE_CALLBACK_TOKEN' "$tmp_dir/yxl.yaml"; then
  echo 'YXL must not receive the YVR legacy Flowroute callback token' >&2
  exit 1
fi

echo 'Flowroute SMS rendering checks passed.'
