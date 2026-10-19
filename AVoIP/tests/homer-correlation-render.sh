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
kamailio_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$render")"

grep -Fq 'remove_hf("X-Call-ID");' <<< "$kamailio_cfg"
grep -Fq 'append_hf("X-Call-ID: $ci\r\n");' <<< "$kamailio_cfg"
grep -Fq 'remove_hf("X-Core-Call-Linkedid");' <<< "$kamailio_cfg"
grep -Fq 'onreply_route[SIPCORE_WS_REPLY]' <<< "$kamailio_cfg"
grep -Fq 'append_hf("X-Call-ID: $ci\r\n");' <<< "$kamailio_cfg"
grep -Fq 'if (is_method("INVITE|ACK|BYE|CANCEL|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {' <<< "$kamailio_cfg"
grep -Fq 'Set(_AVOIP_HOMER_CORRELATION_ID=${PJSIP_HEADER(read,X-Call-ID)})' <<< "$asterisk_cfg"
grep -Fq 'PJSIP_HEADER(add,X-Call-ID)=${AVOIP_HOMER_CORRELATION_ID}' <<< "$asterisk_cfg"
grep -Fq 'AVoIP outbound start linkedid=${CHANNEL(linkedid)} uniqueid=${UNIQUEID} browser_call_id=${PJSIP_HEADER(read,Call-ID)} extension=7101 destination_class=nanp' <<< "$asterisk_cfg"
! grep -Fq 'destination=${EXTEN}' <<< "$asterisk_cfg"
grep -Fq 'status=$rs extension=$fU site=yvr call_id=$ci' <<< "$kamailio_cfg"
grep -Fq 'sip_h_X-Call-ID=${sip_h_X-Call-ID}' <<< "$freeswitch_dialplan"
grep -Fq '"aleg_ids": ["X-Call-ID"]' <<< "$homer_cfg"
grep -Fq '"force_aleg_id": true' <<< "$homer_cfg"
grep -Fq '"custom_headers": ["X-Core-Call-Linkedid", "X-Core-Origin-Uniqueid"]' <<< "$homer_cfg"
grep -Fq '"correlation": {' <<< "$homer_cfg"
grep -Fq '"enable": true' <<< "$homer_cfg"
grep -Fq '"seed_default": true' <<< "$homer_cfg"
! grep -Eq 'rewrite(CallId|CallID)|set_callid\(' <<< "$kamailio_cfg"

grep -Fq 'hep_capture_id", 101' <<< "$kamailio_cfg"
grep -Fq 'capture_id=102' "$render"
grep -Fq -- '--homer-id=103' "$render"
! grep -Fq -- '--homer-id=102' "$render"
grep -Fq '"deduplicate": false' <<< "$homer_cfg"

echo 'PASS: SIP Core Call-ID correlation alias propagates through Asterisk and FreeSWITCH into Homer HEP mapping'
echo 'PASS: Native SIP dialog identifiers remain independent; Homer correlation scripts are seeded for activation'
echo 'PASS: Kamailio, FreeSWITCH, and RTPEngine use distinct Homer capture IDs'
