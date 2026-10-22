#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-registrar.yaml" \
  > "$rendered"

yq -e 'select(.kind == "User" and (.metadata.name | contains("internal-wss-registrar-db"))) | .spec.username == "kamailio-test-wss"' "$rendered" >/dev/null
yq -e 'select(.kind == "User" and (.metadata.name | contains("internal-registrar-db"))) | .spec.username == "kamailio-test"' "$rendered" >/dev/null
yq -e 'select(.kind == "CronJob" and (.metadata.name | contains("reg-sync-7101"))) | .spec.jobTemplate.spec.template.spec.containers[0].env | any(.name == "SIP_PASSWORD" and .valueFrom.secretKeyRef.name != "")' "$rendered" >/dev/null
yq -e 'select(.kind == "StatefulSet" and (.metadata.name | contains("internal-wss"))) | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .env | any(.name == "PGSSLROOTCERT" and .value == "/etc/ssl/certs/ca-certificates.crt")' "$rendered" >/dev/null
yq -e 'select(.kind == "CiliumNetworkPolicy" and (.metadata.name | contains("internal-wss-sip-policy"))) | (.spec.ingress | any(.fromEndpoints[]?.matchLabels."app.kubernetes.io/controller" == "kamailio-internal-wss")) and (.spec.egress | any(.toEndpoints[]?.matchLabels."app.kubernetes.io/controller" == "kamailio-internal-wss"))' "$rendered" >/dev/null
freeswitch_sip_config="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | contains("freeswitch-sip-configs"))) | .data["kamailio.xml"]' "$rendered")"
grep -Fq '<gateway name="sipcore-registrar">' <<<"$freeswitch_sip_config"
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("admin"))) | .spec.template.spec.containers[].env[] | select(.name == "AVOIP_SIPCORE_REGISTRAR_GATEWAY") | .value == "sipcore-registrar"' "$rendered" >/dev/null
asterisk_startup="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("asterisk"))) | .spec.template.spec.containers[] | select(.name == "asterisk") | .args[]' "$rendered")"
! grep -Fq 'sip_password=' <<<"$asterisk_startup"

ha_config="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | contains("internal-wss-config"))) | .data["kamailio.cfg"]' "$rendered")"
grep -Fq 'loadmodule "auth_db.so"' <<<"$ha_config"
grep -Fq 'route(PRIVATE_REGISTER);' <<<"$ha_config"
grep -Fq 'Path: <sip:SIPCORE_OWNER_POD.' <<<"$ha_config"
grep -Fq 'www_authorize("sipcore.mylogin.space", "active_subscriber")' <<<"$ha_config"
grep -Fq 'X-Core-Extension: $au' <<<"$ha_config"
grep -Fq ':5072;transport=tls' <<<"$ha_config"
grep -Fq 'if ($var(peer_name) == "freeswitch-registrar")' <<<"$ha_config"

echo 'PASS: HA registrar and legacy database identities coexist; owner routing and Digest registration render'
