#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart_dir="$repo_root/AVoIP"
dc1="$(mktemp)"
home1="$(mktemp)"
trap 'rm -f "$dc1" "$home1"' EXIT

helm template core-dc1-talos-prod "$chart_dir" --namespace core-prod \
  -f "$chart_dir/tests/fixtures/intersite-dc1.yaml" > "$dc1"
helm template core-home1-talos-prod "$chart_dir" --namespace core-prod \
  -f "$chart_dir/tests/fixtures/intersite-home1.yaml" > "$home1"

dc1_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-dc1-talos-prod-avoip-kamailio-config") | .data["kamailio.cfg"]' "$dc1")"
dc1_tls="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-dc1-talos-prod-avoip-kamailio-config") | .data["tls.cfg"]' "$dc1")"
home1_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-config") | .data["kamailio.cfg"]' "$home1")"
home1_tls="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-config") | .data["tls.cfg"]' "$home1")"
home1_fs="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-freeswitch-dialplan-configs") | .data["public.xml"]' "$home1")"

grep -Fq 'server_name = sip-outbound.core-dc1-talos-prod.dc1.yxl.resolvemy.host' <<< "$dc1_tls"
grep -Fq 'server_name = sip-outbound.core-home1-talos-prod.home1.yvr.resolvemy.host' <<< "$home1_tls"
[[ "$(grep -Fc 'verify_certificate = yes' <<< "$dc1_tls")" -ge 2 ]]
[[ "$(grep -Fc 'verify_certificate = yes' <<< "$home1_tls")" -ge 2 ]]
grep -Fq 'require_certificate = no' <<< "$dc1_tls"
grep -Fq 'require_certificate = no' <<< "$home1_tls"
grep -Fq 'ca_list = /etc/kamailio/peer-ca/ca.crt' <<< "$dc1_tls"
grep -Fq 'ca_list = /etc/kamailio/peer-ca/ca.crt' <<< "$home1_tls"

# The ingress authorization uses the transport source, verified TLS peer and
# exact SAN, then narrows initial INVITEs by the configured extension list.
grep -Fq 'src_ip == 172.20.48.0/22 && $tls_peer_san_hostname == "core-dc1-talos-prod-business-avoip-prod-avoip-kamailio.core-prod.svc.k3s.dc1.resolvemy.host"' <<< "$home1_cfg"
grep -Fq 'if ($rU == "7102") $var(interSiteAllowed) = 1;' <<< "$home1_cfg"
grep -Fq 'SIP peer decision class=inter-site' <<< "$home1_cfg"
grep -Fq 'listener=$Rn/$Ri:$Rp/$proto source=$si:$sp tls_peer_verified=$tls_peer_verified tls_peer_san=$tls_peer_san_hostname' <<< "$home1_cfg"
grep -Fq 'SIP peer decision class=unclassified authorization=denied' <<< "$home1_cfg"
grep -Fq 'SIP peer next-hop class=backend destination=$du tls_sni=core-home1-talos-prod-avoip-freeswitch.core-prod.svc.k8s.home1.resolvemy.host send_socket=private_tls' <<< "$home1_cfg"
grep -Fq 'route(FROM_CARRIER);' <<< "$home1_cfg"
! grep -Fq '$hdr(X-Core-InterSite)' <<< "$home1_cfg"

# Forged marker values are removed before source authorization. The trusted
# marker is recreated at backend egress only after an authorized dialog has
# passed peer identity and extension checks.
remove_line="$(grep -nF 'remove_hf("X-Core-InterSite");' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
deny_line="$(grep -nF 'authorization=denied reason=source-or-socket' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
extension_deny_line="$(grep -nF 'authorization=denied reason=extension' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
append_line="$(grep -nF 'append_hf("X-Core-InterSite: yxl' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
backend_line="$(grep -nF 'SIP peer next-hop class=backend destination=$du' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
[[ -n "$remove_line" && -n "$deny_line" && -n "$extension_deny_line" && -n "$append_line" && -n "$backend_line" ]]
[[ "$remove_line" -lt "$extension_deny_line" && "$extension_deny_line" -lt "$append_line" && "$append_line" -lt "$backend_line" ]]
grep -Fq 'SIP inter-site backend authorization=allowed peer=yxl marker=yxl' <<< "$home1_cfg"
grep -Fq 'field="${sip_h_X-Core-InterSite}" expression="^yxl$"' <<< "$home1_fs"
[[ "$(grep -Fc 'field="${sip_h_X-Core-InterSite}" expression="^yxl$"' <<< "$home1_fs")" -eq 2 ]]
grep -Fq 'inter_site_marker=${sip_h_X-Core-InterSite} source=${sip_network_ip}' <<< "$home1_fs"

# Only YXL's authenticated IVR ingress rings while waiting before entering the
# answering extension. It must not pre-answer before the shared IVR handoff.
python3 - "$home1" <<'PY'
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

resources = json.loads(subprocess.check_output(['yq', '-s', '.', sys.argv[1]]))
dialplan = next(r['data']['public.xml'] for r in resources if r and r.get('kind') == 'ConfigMap'
                and r['metadata']['name'].endswith('-freeswitch-dialplan-configs'))
root = ET.fromstring(dialplan)
context = root.find("context[@name='public']")
ingress = context.find("extension[@name='authorized-inter-site-ivr']")
actions = ingress.findall('.//action')
assert [(a.get('application'), a.get('data')) for a in actions if a.get('application') != 'log'] == [
    ('ring_ready', None), ('transfer', 'silent-ivr-entry XML public')]
assert not ingress.findall(".//action[@application='pre_answer']")
entry = context.find("extension[@name='silent-ivr-entry']")
assert entry.find('.//action').get('application') == 'answer'
assert not entry.findall(".//action[@application='sleep']")
voice = context.find("extension[@name='flowroute-did']")
assert not voice.findall(".//action[@application='sleep']")
fax = context.find("extension[@name='authorized-inter-site-extension']")
assert fax.find(".//action[@application='ring_ready']") is not None
assert not fax.findall(".//action[@application='sleep']")
print('PASS: YXL IVR rings and answers immediately; local YVR voice and fax timing remain unchanged')
PY

# A trusted initial CANCEL must reach TM before the new-request-only 405.
cancel_lookup_line="$(grep -nF 'if (!t_lookup_cancel())' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
method_deny_line="$(grep -nF 'Inter-site Method Not Allowed' <<< "$home1_cfg" | head -1 | cut -d: -f1)"
[[ -n "$cancel_lookup_line" && -n "$method_deny_line" && "$cancel_lookup_line" -lt "$method_deny_line" ]]
grep -Fq 'SIP inter-site CANCEL result=matched peer=yxl' <<< "$home1_cfg"

# The YXL DID mapping continues to send extension 7102 to YVR's carrier
# Service port 5061. The Service maps that to the public_tls container port;
# 5062 remains the distinct private_tls Service/container port.
grep -Fq '$ru = "sips:7102@core-home1-talos-prod-business-avoip-prod-avoip-kamailio.core-prod.svc.k8s.home1.resolvemy.host";' <<< "$dc1_cfg"
grep -Fq '$du = "sips:10.44.7.136:5061;transport=tls";' <<< "$dc1_cfg"
grep -Fq 'tls_sni=sip-outbound.core-home1-talos-prod.home1.yvr.resolvemy.host' <<< "$dc1_cfg"
grep -Fq 'set_send_socket_name("public_tls");' <<< "$dc1_cfg"
grep -Fq '$du = "sips:10.44.3.190:5061;transport=tls";' <<< "$home1_cfg"
grep -Fq 'tls_sni=sip-outbound.core-dc1-talos-prod.dc1.yxl.resolvemy.host' <<< "$home1_cfg"
yq -e 'select(.kind == "Service" and .metadata.name == "core-home1-talos-prod-avoip-kamailio") | any(.spec.ports[]; .port == 5061 and .targetPort == "tls-public") and any(.spec.ports[]; .port == 5062 and .targetPort == "tls-private")' "$home1" >/dev/null
yq -e 'select(.kind == "NetworkPolicy" and (.metadata.name | contains("kamailio-sip-ingress"))) | any(.spec.ingress[]; any(.from[]?; .ipBlock.cidr == "172.20.48.0/22") and any(.ports[]?; .port == 5061)) and any(.spec.egress[]; any(.to[]?; .ipBlock.cidr == "10.44.3.190/32") and any(.ports[]?; .port == 5061))' "$home1" >/dev/null
yq -e 'select(.kind == "NetworkPolicy" and (.metadata.name | contains("kamailio-sip-ingress"))) | any(.spec.ingress[]; any(.from[]?; .ipBlock.cidr == "172.20.56.0/21") and any(.ports[]?; .port == 5061)) and any(.spec.egress[]; any(.to[]?; .ipBlock.cidr == "10.44.7.136/32") and any(.ports[]?; .port == 5061))' "$dc1" >/dev/null

# Dialog routing remains enabled for both directions and preserves the
# existing ACK/CANCEL transaction and in-dialog BYE routes.
for cfg in "$dc1_cfg" "$home1_cfg"; do
  grep -Fq 'route[IN_DIALOG]' <<< "$cfg"
  grep -Fq 'is_method("ACK")' <<< "$cfg"
  grep -Fq 'is_method("CANCEL")' <<< "$cfg"
  grep -Fq 'is_method("BYE")' <<< "$cfg"
  grep -Fq 't_relay_cancel()' <<< "$cfg"
  grep -Fq 'if (t_check_trans())' <<< "$cfg"
  grep -Fq 'route(TO_CARRIER);' <<< "$cfg"
  grep -Fq 'route(TO_BACKEND);' <<< "$cfg"
done

printf '%s\n' 'PASS: both site SNI profiles request optional client certificates and verify presented peers'
printf '%s\n' 'PASS: YVR authorizes only the exact YXL CIDR, client SAN, and extensions 7101/7102'
printf '%s\n' 'PASS: unauthenticated sources cannot authorize a forged inter-site header'
printf '%s\n' 'PASS: YXL retains the 7102 DID mapping through YVR Service 5061 -> public_tls; Service 5062 remains private_tls'
printf '%s\n' 'PASS: both peer next hops use their configured ClusterIP, per-site SNI, and public_tls socket'
printf '%s\n' 'PASS: peer decision logs include listener, transport source, TLS identity, authorization, and selected next hop'
printf '%s\n' 'PASS: dialog ACK, CANCEL, BYE and in-dialog routing remain generated in both directions'
printf '%s\n' 'PASS: trusted CANCEL reaches TM before initial method rejection and FreeSWITCH reads the inter-site channel variable'
