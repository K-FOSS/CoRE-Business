#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

helm template sms-inbox-check "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set datacenter=home1 \
  --set region=yvr \
  --set freeswitch.enabled=false \
  --set flowrouteSMS.enabled=true \
  --set flowrouteSMS.hostname=sms.mylogin.space \
  --set flowrouteSMS.callbackSecret.name=sms-inbox-check-token \
  --set flowrouteSMS.inbox.enabled=true \
  >"$tmp_dir/render.yaml"

for expected in \
  "name: 'sms-inbox-check-avoip-sms-inbox'" \
  "name: 'sms-inbox-check-avoip-sms-inbox-auth'" \
  "name: 'flowroute-sms-inbox-auth'" \
  "name: 'avoip-authentik-groups'" \
  'AVoIP Users' \
  'AVoIP Admins' \
  'resource "authentik_group" "avoip_users"' \
  'resource "authentik_group" "avoip_admins"' \
  'resource "authentik_policy_binding" "users_access"' \
  'resource "authentik_policy_binding" "admins_access"' \
  'X-Auth-Numbers' \
  'phone_number' \
  'if isinstance(phone_values, str):' \
  'if isinstance(phone_values, (list, tuple, set)):' \
  'sms_numbers' \
  'sms.mylogin.space'; do
  grep -Fq "$expected" "$tmp_dir/render.yaml" || {
    echo "Missing expected SMS inbox render value: $expected" >&2
    exit 1
  }
done

for component in web api webhook; do
  component="$component" yq -e 'select(.kind == "Deployment" and .metadata.name == "sms-inbox-check-avoip-flowroute-sms-" + env.component)' "$tmp_dir/render.yaml" >/dev/null || {
    echo "Missing $component deployment" >&2
    exit 1
  }
done

policy_count="$(yq -r 'select(.kind == "NetworkPolicy" and (.metadata.name | contains("flowroute-sms"))) | .metadata.name' "$tmp_dir/render.yaml" | wc -l)"
[[ "$policy_count" == '3' ]] || {
  echo 'Expected one Envoy-only ingress policy per SMS workload' >&2
  exit 1
}

helm template sms-inbox-non-primary "$repo_root/AVoIP" --namespace core-prod \
  --set cluster.name=core-dc1-talos-prod \
  --set datacenter=dc1 \
  --set region=yxl \
  --set freeswitch.enabled=false \
  --set flowrouteSMS.enabled=false \
  >"$tmp_dir/non-primary.yaml"

if grep -Fq "name: 'avoip-authentik-groups'" "$tmp_dir/non-primary.yaml"; then
  echo 'AVoIP Authentik group ownership must render only in its primary region' >&2
  exit 1
fi

if sed -n '/name: sms-inbox-check-avoip-sms-inbox$/,/^---$/p' "$tmp_dir/render.yaml" | grep -q 'wan-mode: public'; then
  echo 'The Authentik inbox route must not claim public DNS ownership' >&2
  exit 1
fi

echo 'Flowroute SMS inbox rendering checks passed.'
