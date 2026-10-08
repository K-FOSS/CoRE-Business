#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render() {
  helm template registrar-test "$chart_dir" --namespace core-prod \
    --set-string cluster.name=core-home1-talos-prod \
    --set-string cluster.domain=cluster.local \
    --set-string avoip.did=1000000000 \
    --set-string fax.did=1000000001 "$@"
}

pilot='[{"name":"carrier","enabled":true,"role":"carrier-sbc"},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}},"privateRouting":{"peers":[{"name":"access","controller":"kamailio-access","cidr":"10.0.0.10/32","sanHostname":"access.test.invalid","allowedUsers":[]}]},"registrar":{"enabled":true,"realm":"pilot.test.invalid","accessPeerName":"access","allowedUsers":["2000"],"database":{"host":"psql.test.invalid","username":"avoipreg","secretName":"avoip-reg-db"}}}]'
render --set-json "kamailio.instances=$pilot" > "$tmp_dir/pilot.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/pilot.yaml" > "$tmp_dir/pilot.json"

jq -e '[.[] | select(.kind == "User" and (.metadata.name | endswith("-internal-registrar-db")))][0] | .spec.psql.enabled == true and .spec.psql.uri == "postgres://" and .spec.writeConnectionSecretToRef.name == "avoip-reg-db"' "$tmp_dir/pilot.json" >/dev/null
jq -e '[.[] | select(.kind == "Job" and (.metadata.name | endswith("-internal-registrar-schema")))][0] | .metadata.annotations["argocd.argoproj.io/hook"] == "Sync" and ([.spec.template.spec.containers[0].env[] | select(.name == "PGPASSWORD" and .valueFrom.secretKeyRef.name == "avoip-reg-db")] | length) == 1 and ([.spec.template.spec.containers[0].env[] | select(.name == "PGSSLMODE" and .value == "verify-full")] | length) == 1' "$tmp_dir/pilot.json" >/dev/null
jq -e '[.[] | select(.kind == "Deployment" and (.metadata.name | endswith("-kamailio-internal")))][0] | .metadata.annotations["argocd.argoproj.io/sync-wave"] == "1" and ([.spec.template.spec.containers[] | select(.name == "kamailio-internal") | .env[] | select(.name == "REGISTRAR_DB_URL" and .valueFrom.secretKeyRef.key == "psqlURI")] | length) == 1' "$tmp_dir/pilot.json" >/dev/null
jq -e '[.[] | select(.kind == "ConfigMap" and (.metadata.name | endswith("-internal-config")))][0].data["kamailio.cfg"] | contains("loadmodule \"auth_db.so\"") and contains("loadmodule \"registrar.so\"") and contains("sslmode=verify-full") and contains("db_mode\", 3") and contains("$au != $tU") and contains("$au != $fU") and contains("Destination Not Authorized") and (contains("rtpengine_manage") | not) and (contains("SIP RX RAW") | not)' "$tmp_dir/pilot.json" >/dev/null
jq -e '[.[] | select(.kind == "CiliumNetworkPolicy" and (.metadata.name | endswith("-internal-sip-policy")))][0].spec.egress | any(.toFQDNs[0].matchName? == "psql.test.invalid")' "$tmp_dir/pilot.json" >/dev/null

render > "$tmp_dir/default.yaml"
yq -s 'map(select(. != null))' "$tmp_dir/default.yaml" > "$tmp_dir/default.json"
jq -e '[.[] | select((.metadata.name? // "") | endswith("-registrar-db") or endswith("-registrar-schema") or endswith("-registrar-schema-policy"))] | length == 0' "$tmp_dir/default.json" >/dev/null

invalid='[{"name":"carrier","enabled":true,"role":"carrier-sbc"},{"name":"internal","enabled":true,"role":"private-sbc","registrar":{"enabled":true}}]'
if render --set-json "kamailio.instances=$invalid" > "$tmp_dir/invalid.yaml" 2> "$tmp_dir/invalid.err"; then
  echo 'Expected incomplete registrar values to fail rendering' >&2
  exit 1
fi
grep -Fq 'registrar requires an enabled private-sbc' "$tmp_dir/invalid.err"

unsafe='[{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}},"sipLogging":{"rawInbound":true},"registrar":{"enabled":true,"realm":"pilot.test.invalid","accessPeerName":"access","allowedUsers":["2000"],"database":{"host":"psql.test.invalid","username":"avoipreg","secretName":"avoip-reg-db"}}}]'
if render --set-json "kamailio.instances=$unsafe" > "$tmp_dir/unsafe.yaml" 2> "$tmp_dir/unsafe.err"; then
  echo 'Expected raw SIP logging to fail registrar validation' >&2
  exit 1
fi
grep -Fq 'registrar forbids raw SIP' "$tmp_dir/unsafe.err"

printf 'PASS opt-in registrar identity, PostgreSQL migration, Digest routing, and default-disabled render\n'
