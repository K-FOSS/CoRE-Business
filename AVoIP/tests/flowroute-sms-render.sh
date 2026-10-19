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
  --set flowrouteSMS.hostname=sms.mylogin.space \
  --set flowrouteSMS.image.repository=forge.example/core/flowroute-sms \
  --set flowrouteSMS.image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set flowrouteSMS.callbackSecret.name=flowroute-invalid-avoip-sms-callback \
  >"$tmp_dir/non-primary.yaml" 2>&1; then
  echo 'Flowroute SMS should render only in its configured primary region' >&2
  exit 1
fi

echo 'Flowroute SMS rendering checks passed.'
