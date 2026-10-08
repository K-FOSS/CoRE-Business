#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Deliberately non-routable test identities. This checks the opt-in manifest
# and Kamailio parser boundary; it does not place a billable PSTN call.
instances='[{"name":"carrier","enabled":true,"role":"carrier-sbc","carrierOutbound":{"enabled":true,"gatewayServiceHost":"envoy-gw.kube-system.svc.cluster.local","sniHost":"sip-egress.example.invalid","peer":{"cidr":"10.0.0.0/24","sanHostname":"sip-internal.example.invalid","serviceHost":"sip-internal.example.invalid","controller":"kamailio-internal"},"testRoute":{"extension":"9001","peerName":"pbx","destination":"+12125550100","callerId":"+12025550123"}}},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}},"carrierOutbound":{"enabled":true,"gatewayServiceHost":"envoy-gw.kube-system.svc.cluster.local","sniHost":"sip-egress.example.invalid","peer":{"cidr":"10.0.0.0/24","sanHostname":"sip-internal.example.invalid"},"testRoute":{"extension":"9001","peerName":"pbx","destination":"+12125550100","callerId":"+12025550123"}},"privateRouting":{"peers":[{"name":"pbx","controller":"asterisk","cidr":"10.0.0.10/32","sanHostname":"pbx.test.invalid","allowedUsers":[]},{"name":"carrier","controller":"kamailio","cidr":"10.0.0.0/24","sanHostname":"carrier.test.invalid","allowedUsers":[]}],"destinations":[],"routes":[]}}]'

helm template outbound-test "$chart_dir" --namespace core-prod \
  --set-string cluster.name=outbound-test \
  --set-string cluster.domain=cluster.local \
  --set-json "kamailio.instances=$instances" > "$tmp_dir/render.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/render.yaml" > "$tmp_dir/render.json"

jq -e '
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-config")))][0].data["kamailio.cfg"] |
    contains("tcp_accept_haproxy=yes") and
    contains("$tls_peer_san_hostname == \"sip-internal.example.invalid\"") and
    contains("loadmodule \"dialog.so\"") and
    contains("$var(quota_script)") and
    contains("replace-origin internal external") and
    contains("$rU != \"+12125550100\"") and
    contains("us-west-or.sip.flowroute.com")) and
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-internal-config")))][0].data["kamailio.cfg"] |
    contains("tcp_accept_haproxy=no") and
    contains("$rU == \"9001\"") and
    contains("$var(peer_name) != \"pbx\"") and
    contains("PRIVATE_TO_CARRIER_GATEWAY") and
    (contains("us-west-or.sip.flowroute.com") | not)) and
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-config")))][0].data["tls.cfg"] |
    contains("server_name = sip-egress.example.invalid") and
    contains("require_certificate = yes")) and
  ([.[] | select(.kind == "Certificate" and (.metadata.name | endswith("-kamailio-sip-tls")))][0].spec.dnsNames | index("sip-egress.example.invalid") != null) and
  ([.[] | select(.kind == "CiliumNetworkPolicy" and (.metadata.name | endswith("-kamailio-internal-sip-policy")))][0].spec.egress |
    any(.toEndpoints[]?.matchLabels["gateway.envoyproxy.io/owning-gateway-name"] == "main-gw"))
' "$tmp_dir/render.json" > /dev/null

echo 'PASS opt-in outbound render, mTLS boundary, exact test route and shared quota configuration'
