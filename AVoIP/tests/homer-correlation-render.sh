#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT

helm template core-home1-talos-prod "$repo_root/AVoIP" --namespace core-prod \
  -f "$repo_root/AVoIP/tests/fixtures/outbound-teardown.yaml" > "$render"
homer_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-homer-config") | .data["homer.json"]' "$render")"
asterisk_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-asterisk-configs") | .data["extensions.conf"]' "$render")"
freeswitch_dialplan="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-freeswitch-dialplan-configs") | .data["asterisk.xml"]' "$render")"

grep -Fq 'PJSIP_HEADER(add,X-Call-ID)=${CHANNEL(linkedid)}' <<< "$asterisk_cfg"
grep -Fq 'sip_h_X-Call-ID=${sip_h_X-Call-ID}' <<< "$freeswitch_dialplan"
grep -Fq '"aleg_ids": ["X-Call-ID"]' <<< "$homer_cfg"
grep -Fq '"force_aleg_id": true' <<< "$homer_cfg"
grep -Fq '"custom_headers": ["X-Core-Call-Linkedid", "X-Core-Origin-Uniqueid"]' <<< "$homer_cfg"
grep -Fq '"correlation": {' <<< "$homer_cfg"
grep -Fq '"enable": true' <<< "$homer_cfg"

echo 'PASS: Homer correlation metadata renders without changing SIP Call-ID handling'
