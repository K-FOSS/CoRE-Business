#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-registrar.yaml" \
  --set avoipAdmin.bridgedCalls.enabled=false \
  > "$rendered"

yq -e 'select(.kind == "User" and (.metadata.name | contains("internal-wss-registrar-db"))) | .spec.username == "kamailio-test-wss"' "$rendered" >/dev/null
yq -e 'select(.kind == "User" and (.metadata.name | contains("internal-registrar-db"))) | .spec.username == "kamailio-test"' "$rendered" >/dev/null
yq -e 'select(.kind == "CronJob" and (.metadata.name | contains("reg-sync-7101"))) | .spec.jobTemplate.spec.template.spec.containers[0].env | any(.name == "SIP_PASSWORD" and .valueFrom.secretKeyRef.name != "")' "$rendered" >/dev/null
yq -e 'select(.kind == "StatefulSet" and (.metadata.name | contains("internal-wss"))) | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .env | any(.name == "PGSSLROOTCERT" and .value == "/etc/ssl/certs/ca-certificates.crt")' "$rendered" >/dev/null
yq -e 'select(.kind == "StatefulSet" and (.metadata.name | contains("internal-wss"))) | .spec.template.spec.containers[] | select(.name == "kamailio-internal-wss") | .env | any(.name == "PGCONNECT_TIMEOUT" and .value == "30")' "$rendered" >/dev/null
yq -e 'select(.kind == "CiliumNetworkPolicy" and (.metadata.name | contains("internal-wss-sip-policy"))) | (.spec.ingress | any(.fromEndpoints[]?.matchLabels."app.kubernetes.io/controller" == "kamailio-internal-wss")) and (.spec.egress | any(.toEndpoints[]?.matchLabels."app.kubernetes.io/controller" == "kamailio-internal-wss"))' "$rendered" >/dev/null
freeswitch_sip_config="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | contains("freeswitch-sip-configs"))) | .data["kamailio.xml"]' "$rendered")"
grep -Fq '<gateway name="sipcore-registrar">' <<<"$freeswitch_sip_config"
grep -Fq '<param name="tls-cert-dir" value="/etc/freeswitch/tls-kamailio"/>' <<<"$freeswitch_sip_config"
yq -e 'select(.kind == "Certificate" and (.metadata.name | contains("freeswitch-kamailio-client-tls"))) | .spec.usages | contains(["client auth"])' "$rendered" >/dev/null
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("freeswitch"))) | .spec.template.spec.volumes[] | select(.name | contains("freeswitch-kamailio-client-tls"))' "$rendered" >/dev/null
python3 - "$freeswitch_sip_config" <<'PY'
import sys
import xml.etree.ElementTree as ET

profile = ET.fromstring(sys.argv[1])
assert profile.tag == 'profile' and profile.get('name') == 'kamailio'
settings = {node.get('name'): node.get('value') for node in profile.findall('./settings/param')}
candidate_acls = [node.get('value') for node in profile.findall('./settings/param[@name="apply-candidate-acl"]')]
assert settings['apply-inbound-acl'] == 'kamailio'
assert candidate_acls == ['rtpengine'], candidate_acls
assert settings['NDLB-allow-crypto-in-avp'] == 'true'
assert settings['inbound-late-negotiation'] == 'true'
assert settings['liberal-dtmf'] == 'true'
assert settings['dtmf-type'] == 'rfc2833'
PY
managed_config="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | contains("freeswitch-managed"))) | .data["core-managed.xml"]' "$rendered")"
python3 - "$managed_config" <<'PY'
import sys
import xml.etree.ElementTree as ET

profile = ET.fromstring(sys.argv[1])
assert profile.tag == 'profile' and profile.get('name') == 'core-managed'
settings = {node.get('name'): node.get('value') for node in profile.findall('./settings/param')}
candidate_acls = [node.get('value') for node in profile.findall('./settings/param[@name="apply-candidate-acl"]')]
assert settings['apply-inbound-acl'] == 'kamailio'
assert candidate_acls == ['rtpengine'], candidate_acls
PY
python3 - "$rendered" <<'PY'
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

resources = json.loads(subprocess.check_output(['yq', '-s', '.', sys.argv[1]]))
dialplan = next(resource['data']['public.xml'] for resource in resources
                if resource and resource.get('kind') == 'ConfigMap'
                and resource['metadata']['name'].endswith('-freeswitch-dialplan-configs'))
root = ET.fromstring(dialplan)
for context, extension in [('ivr-targets', 'ivr-destination-7101'),
                           ('public', 'authorized-inter-site-extension')]:
    node = root.find(f"context[@name='{context}']/extension[@name='{extension}']")
    assert node is not None
    bridges = [action.get('data') for action in node.findall('.//action[@application="bridge"]')]
    assert bridges == ['sofia/gateway/sipcore-registrar/${destination_number}'], (context, bridges)
    assert node.find('.//action[@application="ring_ready"]') is not None or context == 'ivr-targets'
echo = root.find("context[@name='ivr-targets']/extension[@name='ivr-destination-9090']")
assert echo.find('.//action[@application="echo"]') is not None
assert not echo.findall('.//action[@application="bridge"]')
PY

voicemail_rendered="$(mktemp)"
trap 'rm -f "$rendered" "$voicemail_rendered"' EXIT
helm template core-home1-talos-prod "$chart_dir" \
  --namespace core-prod \
  -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/wss-ha-registrar.yaml" \
  --set avoipAdmin.bridgedCalls.enabled=false \
  --set asterisk.voicemail.enabled=true \
  --set-string asterisk.voicemail.accessCode='*97' \
  > "$voicemail_rendered"
python3 - "$voicemail_rendered" <<'PY'
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

resources = json.loads(subprocess.check_output(['yq', '-s', '.', sys.argv[1]]))
dialplan = next(resource['data']['public.xml'] for resource in resources
                if resource and resource.get('kind') == 'ConfigMap'
                and resource['metadata']['name'].endswith('-freeswitch-dialplan-configs'))
root = ET.fromstring(dialplan)
registered_voicemail = root.find("context[@name='core-managed-entry']/extension[@name='registered-client-voicemail']")
assert registered_voicemail is not None
assert any(action.get('data') == 'sofia/gateway/asterisk/*97'
           for action in registered_voicemail.findall('.//action[@application="bridge"]'))
node = root.find("context[@name='ivr-targets']/extension[@name='ivr-destination-7101']")
assert node is not None
bridges = [action.get('data') for action in node.findall('.//action[@application="bridge"]')]
assert bridges == [
    'sofia/gateway/sipcore-registrar/${destination_number}',
    'sofia/gateway/asterisk/voicemail',
], bridges
assert any('to Asterisk voicemail' in (action.get('data') or '')
           for action in node.findall('.//action[@application="log"]'))
registered = root.find("context[@name='ivr-targets']/extension[@name='ivr-destination-7101']")
actions = list(registered.findall('.//action'))
ring_index = next(i for i, action in enumerate(actions) if action.get('application') == 'ring_ready')
timeout_index = next(i for i, action in enumerate(actions)
                     if action.get('application') == 'set'
                     and action.get('data') == 'bridge_answer_timeout=30')
bridge_index = next(i for i, action in enumerate(actions) if action.get('application') == 'bridge'
                    and 'sipcore-registrar' in (action.get('data') or ''))
assert ring_index < bridge_index
assert timeout_index < bridge_index

asterisk = next(resource['data']['extensions.conf'] for resource in resources
                if resource and resource.get('kind') == 'ConfigMap'
                and resource['metadata']['name'].endswith('-asterisk-configs'))
assert 'exten => voicemail,1,VoiceMail(7101@default,u)' in asterisk
PY
yq -e 'select(.kind == "Service" and (.metadata.name | contains("asterisk-control"))) | .spec.clusterIP == "None"' "$voicemail_rendered" >/dev/null
yq -e 'select(.kind == "Service" and (.metadata.name | contains("freeswitch-control"))) | .spec.clusterIP == "None"' "$voicemail_rendered" >/dev/null
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("admin"))) | .spec.template.spec.containers[].env[] | select(.name == "AVOIP_KAMAILIO_CONTROL_ADDRESSES") | .value | contains(":2046")' "$rendered" >/dev/null
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("admin"))) | .spec.template.spec.containers[].env[] | select(.name == "AVOIP_SIPCORE_REGISTRAR_GATEWAY") | .value == "sipcore-registrar"' "$rendered" >/dev/null
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("freeswitch"))) | .spec.template.metadata.annotations["configmap.reloader.stakater.com/reload"] | contains("freeswitch-managed")' "$rendered" >/dev/null
asterisk_startup="$(yq -r 'select(.kind == "Deployment" and (.metadata.name | contains("asterisk"))) | .spec.template.spec.containers[] | select(.name == "asterisk") | .args[]' "$rendered")"
! grep -Fq 'sip_password=' <<<"$asterisk_startup"

ha_config="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | contains("internal-wss-config"))) | .data["kamailio.cfg"]' "$rendered")"
grep -Fq 'loadmodule "auth_db.so"' <<<"$ha_config"
grep -Fq 'sslmode=verify-full;connect_timeout=30' <<<"$ha_config"
grep -Fq 'route(PRIVATE_REGISTER);' <<<"$ha_config"
grep -Fq 'add_path_advertised_address(' <<<"$ha_config"
grep -Fq 'SIPCORE_OWNER_POD.core-home1-talos-prod-busines-kamailio-internal-wss-owner.core-prod.svc.k8s.home1.resolvemy.host:5063' <<<"$ha_config"
grep -Fq '"transport=tls"))' <<<"$ha_config"
grep -Fq 'modparam("registrar", "use_path", 1)' <<<"$ha_config"
grep -Fq 'www_authorize("sipcore.mylogin.space", "active_subscriber")' <<<"$ha_config"
grep -Fq 'X-Core-Extension: $au' <<<"$ha_config"
grep -Fq ':5072;transport=tls' <<<"$ha_config"
grep -Fq 'if ($var(peer_name) == "freeswitch-registrar")' <<<"$ha_config"
grep -Fq 'Private SIP peer rejected pod=$env(POD_NAME) source=$si:$sp transport=$proto receive_port=$Rp tls_verified=$tls_peer_verified tls_peer_san=$tls_peer_san_hostname method=$rm callid=$ci' <<<"$ha_config"

echo 'PASS: HA registrar and legacy database identities coexist; owner routing and Digest registration render'
