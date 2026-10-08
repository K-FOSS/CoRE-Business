#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render() {
  helm template instance-test "$chart_dir" --namespace core-prod \
    --set-string cluster.name=instance-test \
    --set-string cluster.domain=cluster.local \
    --set-string avoip.did=1000000000 \
    --set-string fax.did=1000000001 "$@"
}

instances='[{"name":"carrier","enabled":true,"role":"carrier-sbc","replicas":3},{"name":"internal","enabled":true,"role":"private-sbc","replicas":1,"image":{"tag":"6.1.4-bookworm"},"topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}},"resources":{"requests":{"cpu":"100m"}},"podLabels":{"role.example.com/name":"internal"},"extraEnv":[{"name":"INSTANCE_MARKER","value":"internal"}]}]'
render --set-json "kamailio.instances=$instances" > "$tmp_dir/two.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/two.yaml" > "$tmp_dir/two.json"

jq -e '
  [ .[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio") or endswith("-kamailio-internal"))) ] | length == 2
' "$tmp_dir/two.json" > /dev/null
jq -e '
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio")))][0].spec.selector.matchLabels["app.kubernetes.io/controller"] == "kamailio") and
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.selector.matchLabels["app.kubernetes.io/controller"] == "kamailio-internal") and
  ([.[] | select(.kind == "Service" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.selector["avoip.mylogin.space/kamailio-instance"] == "internal") and
  ([.[] | select(.kind == "Service" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.ports | all(.port == 5062)) and
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.replicas == 1) and
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.template.spec.containers[] | select(.name == "kamailio-internal") | .resources.requests.cpu == "100m") and
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio-internal")))][0].spec.template.spec.containers[] | select(.name == "kamailio-internal") | (.args[0] | contains("kamailio -m 128 "))) and
  ([.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio")))][0].spec.template.spec.containers[] | select(.name == "kamailio") | (.args[0] | contains("kamailio -m 64 "))) and
  ([.[] | select(.kind == "ExternalSecret" and .metadata.name == "avoip-kamailio-internal-topos")][0].spec.target.template.data.server | contains("db=52;")) and
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-internal-config")))][0].data["kamailio.cfg"] | contains("Registration Disabled") and contains("tcp_accept_haproxy=no") and (contains("loadmodule \"rtpengine.so\"") | not) and (contains("flowroute.outboundHost") | not))
' "$tmp_dir/two.json" > /dev/null
jq -e '[.[] | select(.kind == "TLSRoute" and (.metadata.name | contains("kamailio-internal")))] | length == 0' "$tmp_dir/two.json" > /dev/null
jq -e '[.[] | select(.metadata.name? | contains("kamailio-internal"))] | length > 0' "$tmp_dir/two.json" > /dev/null
jq -e '
  [.[] | select(.kind == "CiliumNetworkPolicy" and (.metadata.name | endswith("-kamailio-internal-sip-policy")))][0].spec.ingress == []
' "$tmp_dir/two.json" > /dev/null

pilot='[{"name":"carrier","enabled":true,"role":"carrier-sbc"},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}},"privateRouting":{"peers":[{"name":"pbx","controller":"asterisk","cidr":"10.0.0.10/32","sanHostname":"pbx.test.invalid","allowedUsers":["1000"]}],"destinations":[{"setId":10,"uri":"sips:pbx.test.invalid:5061","controller":"asterisk"}],"routes":[{"user":"1000","setId":10},{"user":"2000","setId":10}]}}]'
render --set-json "kamailio.instances=$pilot" > "$tmp_dir/pilot.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/pilot.yaml" > "$tmp_dir/pilot.json"
jq -e '
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-internal-config")))][0].data["kamailio.cfg"] | contains("$tls_peer_verified != 1") and contains("$tls_peer_san_hostname == \"pbx.test.invalid\"") and contains("$var(peer_name) == \"pbx\" && $rU == \"1000\"") and (contains("$rU == \"2000\"") | not) and contains("ds_select_dst") and (contains("us-west-or.sip.flowroute.com") | not)) and
  ([.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-kamailio-internal-config")))][0].data["dispatcher.list"] | contains("10 sips:pbx.test.invalid:5061 0")) and
  ([.[] | select(.kind == "CiliumNetworkPolicy" and (.metadata.name | endswith("-kamailio-internal-sip-policy")))][0].spec.ingress[0].fromEndpoints[0].matchLabels["app.kubernetes.io/controller"] == "asterisk")
' "$tmp_dir/pilot.json" > /dev/null

render --set-json 'kamailio.instances=[{"name":"carrier","enabled":false,"role":"carrier-sbc"}]' > "$tmp_dir/disabled.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/disabled.yaml" > "$tmp_dir/disabled.json"
jq -e '[.[] | select((.metadata.name? // "") | contains("kamailio"))] | length == 0' "$tmp_dir/disabled.json" > /dev/null

expect_invalid() {
  local expected="$1" value="$2"
  if render --set-json "kamailio.instances=$value" > "$tmp_dir/invalid.yaml" 2> "$tmp_dir/invalid.err"; then
    printf 'Expected invalid Kamailio instances: %s\n' "$expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp_dir/invalid.err"
}

expect_invalid 'duplicate Kamailio instance name' '[{"name":"carrier","role":"carrier-sbc"},{"name":"carrier","role":"carrier-sbc"}]'
expect_invalid 'invalid Kamailio instance name' '[{"name":"Bad_Name","role":"carrier-sbc"}]'
expect_invalid 'unsupported Kamailio role' '[{"name":"registrar","role":"endpoint-registrar"}]'
expect_invalid 'requires function authorization' '[{"name":"carrier","role":"carrier-sbc","functions":{"authorization":false}}]'
expect_invalid 'carrierOutbound requires a Gateway service host' '[{"name":"carrier","role":"carrier-sbc","carrierOutbound":{"enabled":true}}]'
expect_invalid 'private-sbc must not expose public SIP' '[{"name":"internal","role":"private-sbc","publicExposure":{"enabled":true}}]'
expect_invalid 'private-sbc must start with one replica' '[{"name":"internal","role":"private-sbc","replicas":2}]'
expect_invalid 'shmSizeMb must be between 16 and 4096' '[{"name":"internal","role":"private-sbc","shmSizeMb":8}]'
expect_invalid 'privateRouting route requires a numeric user and configured destination set' '[{"name":"internal","role":"private-sbc","privateRouting":{"routes":[{"user":"+12125550100","setId":10}]}}]'
expect_invalid 'allowedUsers must contain only numeric extensions' '[{"name":"internal","role":"private-sbc","privateRouting":{"peers":[{"name":"pbx","controller":"asterisk","cidr":"10.0.0.10/32","sanHostname":"pbx.test.invalid","allowedUsers":["+12125550100"]}]}}]'
expect_invalid 'allowedUsers contains unconfigured extension' '[{"name":"internal","role":"private-sbc","privateRouting":{"peers":[{"name":"pbx","controller":"asterisk","cidr":"10.0.0.10/32","sanHostname":"pbx.test.invalid","allowedUsers":["2000"]}]}}]'
expect_invalid 'duplicate route user' '[{"name":"internal","role":"private-sbc","privateRouting":{"destinations":[{"setId":10,"uri":"sips:pbx.test.invalid:5061","controller":"asterisk"}],"routes":[{"user":"1000","setId":10},{"user":"1000","setId":10}]}}]'
expect_invalid 'requires a dedicated TOPOS database and Secret' '[{"name":"carrier","enabled":true,"role":"carrier-sbc"},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"secretName":"avoip-kamailio-internal-topos"}}}]'
expect_invalid 'requires a dedicated TOPOS database and Secret' '[{"name":"carrier","enabled":true,"role":"carrier-sbc"},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52}}}]'
printf 'PASS Kamailio instance resources, isolation, disabled state, and invalid values\n'
