#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="$(mktemp)"
invalid="$(mktemp)"
trap 'rm -f "$rendered" "$invalid"' EXIT

helm template avoip "$repo_root/AVoIP" \
  --show-only templates/Asterisk/AsteriskConfigs.yaml > "$rendered"

modules="$(yq -r '.data["modules.conf"]' "$rendered")"
rtp="$(yq -r '.data["rtp.conf"]' "$rendered")"
grep -Fqx 'require = res_rtp_asterisk.so' <<< "$modules"
grep -Fqx 'stunaddr=nat.mylogin.space:3478' <<< "$rtp"
grep -Fqx 'icesupport=true' <<< "$rtp"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" \
  --show-only templates/Asterisk/AsteriskConfigs.yaml > "$rendered"
rtp="$(yq -r '.data["rtp.conf"]' "$rendered")"
grep -Fqx 'stunaddr=nat-home1.mylogin.space:3478' <<< "$rtp"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" > "$rendered"
grep -Fqx '#include /tmp/avoip-turn.conf' <(yq -r '.data["rtp.conf"]' "$rendered")
grep -Fq 'turn_shared_secret="$(cat /run/avoip/turn/TURN_SHARED_SECRET)"' "$rendered"
grep -Fq 'turnaddr=nat-home1.mylogin.space:3478' "$rendered"
grep -Fq 'secretName: matrix-turn-auth' "$rendered"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" \
  --set region=yxl > "$rendered"
grep -Fq 'turnaddr=nat.mylogin.space:3478' "$rendered"

helm template avoip "$repo_root/AVoIP" \
  --show-only templates/Asterisk/AsteriskConfigs.yaml \
  --set-string asterisk.rtp.stunAddress=stun.example.test:3479 > "$rendered"
rtp="$(yq -r '.data["rtp.conf"]' "$rendered")"
grep -Fqx 'stunaddr=stun.example.test:3479' <<< "$rtp"

helm template avoip "$repo_root/AVoIP" \
  --show-only templates/Asterisk/AsteriskConfigs.yaml \
  --set asterisk.rtp.stunEnabled=false > "$rendered"
rtp="$(yq -r '.data["rtp.conf"]' "$rendered")"
if grep -q '^stunaddr=' <<< "$rtp"; then
  echo 'FAIL: disabled STUN setting was rendered' >&2
  exit 1
fi

if helm template avoip "$repo_root/AVoIP" \
  --show-only templates/Asterisk/AsteriskConfigs.yaml \
  --set-string asterisk.rtp.stunAddress=stun.example.test:70000 >"$invalid" 2>&1; then
  echo 'FAIL: invalid STUN port was accepted' >&2
  exit 1
fi
grep -Fq 'asterisk.rtp.stunAddress port must be between 1 and 65535' "$invalid"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" \
  --show-only templates/Kamailio/KamailioConfig.yaml > "$rendered"
kamailio="$(yq -r 'select(.kind == "ConfigMap" and .data["kamailio.cfg"] != null) | .data["kamailio.cfg"]' "$rendered")"
grep -Fq 'dns_try_ipv6=off' <<< "$kamailio"
grep -Fq 'address-family=IP4' <<< "$kamailio"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" \
  --show-only templates/common.yaml > "$rendered"
asterisk_args="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("asterisk"))) | .spec.template.spec.containers[] | select(.name == "asterisk") | .args[0]' "$rendered")"
grep -Fq 'rtp_ipv6=no' <<< "$asterisk_args"

helm template avoip "$repo_root/AVoIP" \
  -f "$repo_root/AVoIP/tests/fixtures/intersite-home1.yaml" \
  --show-only templates/FreeSwitch/FreeSwitchSIPConfig.yaml > "$rendered"
freeswitch_sip="$(yq -r '.data["asterisk.xml"]' "$rendered")"
grep -Fq 'Disable the image default IPv6 internal profile' "$rendered"
grep -Fq 'Disable the image default IPv6 external profile' "$rendered"
grep -Fq 'local_ip_v4' <<< "$freeswitch_sip"

echo 'PASS: Asterisk site-local STUN/TURN, shared-secret credential generation, and IPv4-only SIP/RTP settings render'
