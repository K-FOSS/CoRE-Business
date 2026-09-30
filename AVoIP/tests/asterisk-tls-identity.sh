#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

image_tag="$(sed -n '/^asterisk:$/,/^[^ ]/s/^    tag: '\''\([^'\'' ]*\)'\''$/\1/p' "$chart_dir/values.yaml")"
if ! awk -v version="$image_tag" 'BEGIN { split(version, v, "."); exit !(v[1] == 20 && (v[2] > 21 || (v[2] == 21 && v[3] >= 0))) }'; then
  printf 'Expected Asterisk 20.21.0 or newer within major 20, got: %s\n' "$image_tag" >&2
  exit 1
fi

render_and_assert() {
  local release_name="$1"
  local namespace="$2"
  local cluster_domain="$3"
  local expected_host="${release_name}-avoip-asterisk.${namespace}.svc.${cluster_domain}"
  local output="$tmp_dir/${release_name}.yaml"

  helm template "$release_name" "$chart_dir" \
    --namespace "$namespace" \
    --set-string nameOverride=avoip \
    --set-string cluster.domain="$cluster_domain" > "$output"

  grep -Fq "external_signaling_hostname=${expected_host}" "$output"
  grep -Fq 'external_signaling_port=5061' "$output"
  grep -Fq "value=\"${expected_host}:5061;transport=tls\"" "$output"
  grep -Fq "    - '${expected_host}'" "$output"
  ! grep -Fq 'external_signaling_address=' "$output"
  ! grep -Fq 'local_net=' "$output"
  grep -Fq 'checksum/asterisk-pjsip-config:' "$output"
  grep -Fq 'configmap.reloader.stakater.com/reload:' "$output"
  printf 'PASS %s -> %s (PJSIP hostname, port, certificate SAN, restart trigger)\n' "$release_name" "$expected_host"
}

render_and_assert \
  'core-dc1-talos-prod-business-avoip-prod' \
  'core-prod' \
  'k3s.dc1.resolvemy.host'

render_and_assert \
  'core-home1-talos-prod-business-avoip-prod' \
  'core-prod' \
  'k8s.home1.resolvemy.host'

printf 'PASS Asterisk image version %s is >= 20.21.0 and remains on major 20\n' "$image_tag"
