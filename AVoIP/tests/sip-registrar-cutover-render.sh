#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha.yaml" \
  --set asterisk.sipCore.kamailioInstance=internal \
  --set asterisk.sipCore.ingressKamailioInstance=internal-wss \
  --set asterisk.sipCore.tls.ingressKamailioInstance=internal \
  --set kamailio.instances[1].registrar.enabled=true \
  --set-string kamailio.instances[1].registrar.realm=sipcore.mylogin.space \
  --set-string kamailio.instances[1].registrar.accessPeerName=carrier \
  --set-string kamailio.instances[1].registrar.allowedUsers[0]=7101 \
  --set kamailio.instances[1].registrar.credentialSync.enabled=true \
  --set kamailio.instances[1].sipLogging.rawInbound=false \
  --set kamailio.instances[1].sipLogging.postToposResponses=false \
  --set kamailio.instances[1].sipLogging.carrierTraffic=false \
  --set kamailio.instances[1].sipLogging.diagnostics.enabled=false \
  --set kamailio.instances[1].sipLogging.diagnostics.sdp=false \
  --set-string kamailio.instances[1].privateRouting.peers[0].name=carrier \
  --set-string kamailio.instances[1].privateRouting.peers[0].controller=carrier \
  --set-string kamailio.instances[1].privateRouting.peers[0].cidr=192.0.2.0/24 \
  --set-string kamailio.instances[1].privateRouting.peers[0].sanHostname=carrier.test \
  > "$rendered"

yq -e 'select(.kind == "TLSRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-tls") | .spec.rules[0].backendRefs[0].name == "core-home1-talos-prod-avoip-kamailio-internal"' "$rendered" >/dev/null
yq -e 'select(.kind == "HTTPRoute" and .metadata.name == "core-home1-talos-prod-avoip-sipcore-wss") | .spec.rules[0].backendRefs[0].name == "core-home1-talos-prod-avoip-kamailio-internal-wss"' "$rendered" >/dev/null
yq -e 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal") | any(.spec.ports[]; .name == "sipcore-tls-in" and .port == 5064)' "$rendered" >/dev/null
yq -e 'select(.kind == "CronJob" and .metadata.name == "core-home1-talos-prod-avoip-reg-sync-7101") | .spec.schedule == "*/5 * * * *" and (.spec.jobTemplate.spec.template.spec.containers[0].env | any(.name == "SIP_PASSWORD" and .valueFrom.secretKeyRef.name == "core-home1-talos-prod-avoip-asterisk-sipcore-7101"))' "$rendered" >/dev/null

internal_config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$rendered")"
grep -Fq 'loadmodule "auth_db.so"' <<<"$internal_config"
grep -Fq '($proto == "tls" && $Rp ==' <<<"$internal_config"
grep -Fq 'www_authorize("sipcore.mylogin.space", "active_subscriber")' <<<"$internal_config"
grep -Fq 'proxy_authorize("sipcore.mylogin.space", "active_subscriber")' <<<"$internal_config"
! grep -Fq 'SIP_PASSWORD=' <<<"$rendered"

echo 'PASS: TLSRoute registration ingress is split from WSS, and the registrar plus secret-backed HA1 reconciler render for the selected TLS instance'
