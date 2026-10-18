#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml"
rendered="$(mktemp)"
override="$(mktemp)"
trap 'rm -f "$rendered" "$override"' EXIT

helm template avoip-dns-check "$chart_dir" \
  --namespace core-prod \
  -f "$fixture" > "$rendered"

targeted_pods() {
  yq -r 'select((.kind == "Deployment" or .kind == "StatefulSet") and ((.metadata.labels["app.kubernetes.io/controller"] // "") == "asterisk" or (.metadata.labels["app.kubernetes.io/controller"] // "") == "freeswitch" or ((.metadata.labels["app.kubernetes.io/controller"] // "") | startswith("kamailio")))) | [.kind, .metadata.name, .metadata.labels["app.kubernetes.io/controller"], ((.spec.template.spec.dnsConfig.options // []) | map(select(.name == "ndots") | .value) | join(","))] | @tsv' "$1"
}

check_defaults() {
  local input="$1"
  local rows
  rows="$(targeted_pods "$input")"
  [[ -n "$rows" ]] || { echo 'FAIL: no SIP workload pods found' >&2; exit 1; }
  grep -q $'^Deployment\t.*\tasterisk\t0$' <<<"$rows" || { echo 'FAIL: Asterisk does not use ndots 0' >&2; exit 1; }
  grep -q $'^Deployment\t.*\tfreeswitch\t0$' <<<"$rows" || { echo 'FAIL: FreeSWITCH does not use ndots 0' >&2; exit 1; }
  if awk -F '\t' '$3 ~ /^kamailio/ && $4 != "0" { failed=1 } END { exit !failed }' <<<"$rows"; then
    echo 'FAIL: a Kamailio instance does not use ndots 0' >&2
    exit 1
  fi
  grep -q $'\tkamailio' <<<"$rows" || { echo 'FAIL: no Kamailio workload found' >&2; exit 1; }
}

check_defaults "$rendered"
echo 'PASS: Asterisk, FreeSWITCH, and every rendered Kamailio instance use ndots 0'

helm template avoip-dns-check "$chart_dir" \
  --namespace core-prod \
  -f "$fixture" \
  --set-string 'workloadNetworking.kamailio-internal.dnsConfig.options[0].name=ndots' \
  --set-string 'workloadNetworking.kamailio-internal.dnsConfig.options[0].value=2' > "$override"
override_rows="$(targeted_pods "$override")"
grep -q $'^Deployment\t.*\tasterisk\t0$' <<<"$override_rows" || { echo 'FAIL: Asterisk does not use ndots 0 with an instance override' >&2; exit 1; }
grep -q $'^Deployment\t.*\tfreeswitch\t0$' <<<"$override_rows" || { echo 'FAIL: FreeSWITCH does not use ndots 0 with an instance override' >&2; exit 1; }
grep -q $'\tkamailio-internal\t2$' <<<"$override_rows" || { echo 'FAIL: per-instance Kamailio ndots override was not rendered' >&2; exit 1; }
if awk -F '\t' '$3 ~ /^kamailio/ && $3 != "kamailio-internal" && $4 != "0" { failed=1 } END { exit !failed }' <<<"$override_rows"; then
  echo 'FAIL: a per-instance override changed another Kamailio DNS profile' >&2
  exit 1
fi
echo 'PASS: per-instance Kamailio DNS profile overrides only its selected controller'
