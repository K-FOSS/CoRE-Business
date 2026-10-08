#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render_and_assert() {
  local site="$1" domain="$2" datacenter="$3" region="$4" tcp_enabled="$5"
  local output="$tmp_dir/$site.yaml"
  helm template "$site" "$chart_dir" --namespace core-prod \
    --set-string cluster.name="$site" --set-string cluster.domain="$domain" \
    --set-string datacenter="$datacenter" --set-string region="$region" \
    --set-string kamailio.instances[0].name=carrier \
    --set-string kamailio.instances[0].role=carrier-sbc \
    --set kamailio.instances[0].enabled=true \
    --set kamailio.instances[0].replicas=3 \
    --set kamailio.instances[0].publicExposure.sip.udpEnabled=true \
    --set kamailio.instances[0].publicExposure.sip.directService.enabled=true \
    --set kamailio.instances[0].publicExposure.sip.tcpEnabled="$tcp_enabled" \
    --show-only templates/Kamailio/KamailioConfig.yaml \
    --show-only templates/FreeSwitch/FreeSwitchSIPConfig.yaml \
    --show-only templates/FreeSwitch/FreeSwitchDialplanConfig.yaml \
    --show-only templates/FreeSwitch/FreeSwitchMiscConfig.yaml > "$output"

  # Public Kamailio listeners use source ACLs on every supported transport.
  grep -Fq '($proto == "udp" && $Rp == 5060)' "$output"
  if [[ "$tcp_enabled" == true ]]; then
    grep -Fq '($proto == "tcp" && $Rp == 5060)' "$output"
  fi
  grep -Fq '($proto == "tls" && $Rp == 5061)' "$output"
  grep -Fq 'src_ip == ' "$output"
  grep -Fq 'src_ip == 34.210.91.112/28' "$output"
  grep -Fq 'src_ip == 34.226.36.32/28' "$output"
  ! grep -Fq 'src_ip == 0.0.0.0/0' "$output"
  grep -Fq 'sl_send_reply("403", "Source Not Authorized")' "$output"
  grep -Fq 'sl_send_reply("403", "Registration Disabled")' "$output"
  grep -Fq 'sl_send_reply("403", "Outbound Calling Disabled")' "$output"
  ! grep -Fq 'route(FROM_OUTBOUND_PEER)' "$output"
  grep -Fq 'route(INITIAL_BACKEND)' "$output"

  # Public calls may reach configured DIDs, but unmatched destinations cannot
  # select a carrier gateway through the FreeSWITCH public dialplan.
  grep -Fq 'name="reject-unmatched-public-destination"' "$output"
  grep -Fq 'application="hangup" data="CALL_REJECTED"' "$output"
  grep -Fq '<profile name="kamailio">' "$output"
  grep -Fq '<param name="apply-inbound-acl" value="kamailio"/>' "$output"
  grep -Fq '<param name="auth-calls" value="true"/>' "$output"
  grep -Fq "ldaps://ldap-$datacenter.mylogin.space" "$output"
  grep -Fq '<param name="listen-ip" value="127.0.0.1"/>' "$output"
  ! grep -Fq '<param name="accept-blind-auth" value="true"/>' "$output"
  printf 'PASS %s rendered SIP source, registration, dialplan, and local event-socket guards\n' "$site"
}

render_and_assert 'core-home1-talos-prod' 'k8s.home1.resolvemy.host' 'home1' 'yvr' false
render_and_assert 'core-dc1-talos-prod' 'k3s.dc1.resolvemy.host' 'dc1' 'yxl' true
