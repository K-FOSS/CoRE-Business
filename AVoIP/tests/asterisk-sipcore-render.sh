#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render_sipcore() {
  helm template siptest "$chart_dir" --namespace core-prod \
    --set asterisk.sipCore.enabled=true \
    --set-string asterisk.sipCore.hostname=sipcore.example.net \
    --set-string asterisk.sipCore.allowedOrigins[0]=https://home.example.net \
    --set-string asterisk.sipCore.extensions[0].number=7101 \
    --set-string asterisk.sipCore.extensions[0].secret.remoteKey=unit/test/7101 \
    --set-string asterisk.sipCore.extensions[0].secret.property=Password \
    --set-string asterisk.sipCore.extensions[0].allowCallsTo[0]=9090 "$@"
}

helm template siptest "$chart_dir" --namespace core-prod > "$tmp_dir/sipcore-disabled.yaml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_sipcore > "$tmp_dir/empty-matches.yaml"
if render_sipcore --set-string asterisk.sipCore.extensions[0].secret.remoteKey= >"$tmp_dir/missing-secret.yaml" 2>&1; then
  fail 'SIP Core rendered without an ExternalSecret password reference'
fi
if render_sipcore --set rtpengine.enabled=false >"$tmp_dir/missing-rtpengine.yaml" 2>&1; then
  fail 'SIP Core rendered without the required existing RTPEngine'
fi
if render_sipcore --set asterisk.sipCore.media.enabled=true >"$tmp_dir/direct-media.yaml" 2>&1; then
  fail 'SIP Core rendered direct Asterisk media instead of RTPEngine'
fi
if render_sipcore --set asterisk.turn.port=0 >"$tmp_dir/invalid-turn-port.yaml" 2>&1; then
  fail 'Asterisk TURN rendered with an invalid port'
fi
if render_sipcore --set-string asterisk.turn.credentialLifetimeSeconds=31536001 >"$tmp_dir/invalid-turn-lifetime.yaml" 2>&1; then
  fail 'Asterisk TURN rendered with a credential lifetime over one year'
fi
if render_sipcore --set asterisk.sipCore.privateEgressPort=5061 >"$tmp_dir/invalid-private-egress-port.yaml" 2>&1; then
  fail 'SIP Core private TLS egress port collided with the existing TLS listener'
fi
render_sipcore --set asterisk.turn.enabled=false > "$tmp_dir/turn-disabled.yaml"
grep -Fq 'matrix-turn-auth' "$tmp_dir/sipcore-disabled.yaml" && fail 'Asterisk TURN depends on the Matrix Secret when SIP Core is disabled'
grep -Fq 'endpoint_identifier_order=username,auth_username,ip,anonymous' "$tmp_dir/empty-matches.yaml" || fail 'PJSIP identifier order is incorrect'
grep -Fq 'require = res_pjsip_endpoint_identifier_user.so' "$tmp_dir/empty-matches.yaml" || fail 'username identifier module is not required'
grep -Fq 'require = res_pjsip_endpoint_identifier_ip.so' "$tmp_dir/empty-matches.yaml" || fail 'IP identifier module is not required'
grep -Fq 'require = res_pjsip_endpoint_identifier_anonymous.so' "$tmp_dir/empty-matches.yaml" || fail 'anonymous identifier module is not required'
grep -Fq 'identify_by=username,auth_username' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core endpoint is missing username identifiers'
grep -Fq 'auth={{ .number }}' "$tmp_dir/empty-matches.yaml" || grep -Fq 'auth=7101' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core endpoint is missing Digest auth'
grep -Fq 'context=from-sipcore-7101' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core extension context is missing'
grep -Fq 'exten => 9090,1,Answer()' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core echo destination is missing'
grep -Fq 'Echo()' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core echo dialplan is missing'
grep -Fq 'max_contacts=2' "$tmp_dir/empty-matches.yaml" || fail 'existing AOR contact limit was not rendered'
grep -Fq 'webrtc=yes' "$tmp_dir/empty-matches.yaml" || fail 'WebRTC endpoint settings are missing'
grep -Fq 'direct_media=no' "$tmp_dir/empty-matches.yaml" || fail 'direct_media=no was not preserved'
grep -Fq 'allow=ulaw,alaw' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core codecs were not preserved'
grep -Fq 'transport=transport-tls' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio-to-Asterisk TLS transport was not rendered'
grep -Fq 'outbound_proxy=sip:siptest-avoip-kamailio.core-prod.svc.cluster.local:5063\\;transport=tls\\;lr' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core endpoint does not route outbound calls through Kamailio TLS'
grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio WebSocket listener was not rendered'
grep -Fq 'listen=tls:0.0.0.0:5063 advertise "siptest-avoip-kamailio.core-prod.svc.cluster.local":5063 name "sipcore_private_tls"' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk-only Kamailio TLS return listener is missing'
grep -Fq 'name: sipcore-tls' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio private TLS return Service port is missing'
grep -Fq 'route[FROM_SIPCORE_ASTERISK]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio Asterisk-to-WebSocket route is missing'
grep -Fq 'handle_ruri_alias()' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio does not route calls through the registered WebSocket flow'
grep -Fq 'if (is_method("REGISTER") && is_present_hf("Contact") && $hdr(Contact) != "*")' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio does not preserve a WebSocket route alias on registration'
grep -Fq 'rtpengine_manage("WebRTC replace-origin internal external")' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk-originated Home Assistant media is not relayed through RTPEngine'
grep -Fq 'route[FROM_SIPCORE]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio SIP Core route is missing'
grep -Fq 'fix_nated_register' "$tmp_dir/empty-matches.yaml" && fail 'SIP Core route calls nathelper REGISTER helper without Kamailio registrar configuration'
grep -Fq 'route[TO_SIPCORE_ASTERISK]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio-to-Asterisk TLS route is missing'
grep -Fq 'rtpengine_manage("WebRTC replace-origin external internal")' "$tmp_dir/empty-matches.yaml" || fail 'Home Assistant media is not relayed through RTPEngine'
grep -Fq 'SIP RX RAW pod=' "$tmp_dir/empty-matches.yaml" && fail 'Kamailio raw SIP logging could expose Digest Authorization headers'
grep -Fq 'SIP FLOWROUTE RX BEGIN' "$tmp_dir/empty-matches.yaml" && fail 'Kamailio raw carrier logging remains enabled with SIP Core'
grep -Fq 'loadmodule "siptrace.so"' "$tmp_dir/empty-matches.yaml" && fail 'Kamailio SIP tracing could capture SIP Core Digest headers'
rtpengine_sdp_line="$(grep -n 'rtpengine_manage("WebRTC replace-origin external internal")' "$tmp_dir/empty-matches.yaml" | head -n 1 | cut -d: -f1)"
record_route_line="$(grep -n 'record_route_preset("sip:sipcore.example.net:443;transport=wss")' "$tmp_dir/empty-matches.yaml" | head -n 1 | cut -d: -f1)"
if [[ -z "$rtpengine_sdp_line" || -z "$record_route_line" || "$rtpengine_sdp_line" -ge "$record_route_line" ]]; then
  fail 'RTPEngine SDP updates must happen before adding Record-Route'
fi
grep -Fq 'password must be hexadecimal' "$tmp_dir/empty-matches.yaml" || fail 'startup hexadecimal password validation is missing'
grep -Fq 'at least 32 characters' "$tmp_dir/empty-matches.yaml" || fail 'startup password length validation is missing'
grep -Fq 'secretKeyRef:' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core secret is not mounted from a Secret'
grep -Fq 'remoteRef:' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core password is not sourced from External Secrets'
grep -Fq "key: 'unit/test/7101'" "$tmp_dir/empty-matches.yaml" || fail 'configured extension password remote key is not preserved'
grep -Fq 'pjsip set logger on' "$tmp_dir/empty-matches.yaml" && fail 'SIP packet logging could expose SIP Authorization headers'
grep -Fq 'secretName: matrix-turn-auth' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk does not mount the existing Social/Matrix TURN Secret'
grep -Fq 'cat /run/avoip/turn/TURN_SHARED_SECRET' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk TURN shared secret key is incorrect'
grep -Fq 'mountPath: /run/avoip/turn' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk TURN Secret mount is missing'
grep -Fq 'openssl dgst -sha1 -hmac "$turn_shared_secret" -binary' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk REST TURN credential derivation is missing'
grep -Fq 'turnaddr=nat.mylogin.space:3478' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk TURN server config is missing'
grep -Fq 'stunaddr=nat.mylogin.space:3478' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk STUN server config is missing'
grep -Fq '#include /tmp/avoip-turn.conf' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk runtime TURN config include is missing'
if grep -Eq '^[[:space:]]*turnpassword=' "$tmp_dir/empty-matches.yaml"; then
  fail 'Asterisk TURN password was rendered into a Kubernetes manifest'
fi
grep -Fq 'matrix-turn-auth' "$tmp_dir/turn-disabled.yaml" && fail 'disabled Asterisk TURN still mounts the existing Secret'
grep -Fq 'avoip-turn.conf' "$tmp_dir/turn-disabled.yaml" && fail 'disabled Asterisk TURN still generates runtime configuration'
grep -Fq 'type=aor' "$tmp_dir/empty-matches.yaml" || fail 'runtime AOR generation is missing'
grep -Fq 'type=auth' "$tmp_dir/empty-matches.yaml" || fail 'runtime Digest auth generation is missing'
grep -Fq 'allowed_origins=' "$tmp_dir/empty-matches.yaml" && fail 'unsupported allowed_origins directive remains'
grep -Fq 'http.conf: |' "$tmp_dir/empty-matches.yaml" && fail 'Asterisk HTTP listener remains exposed for SIP Core'
grep -Fq 'path: /etc/asterisk/http.conf' "$tmp_dir/empty-matches.yaml" && fail 'Asterisk still mounts a removed HTTP configuration file'
grep -Fq 'match=10.0.0.0/8' "$tmp_dir/empty-matches.yaml" && fail 'broad 10/8 FreeSWITCH match remains'
grep -Fq 'match=172.16.0.0/12' "$tmp_dir/empty-matches.yaml" && fail 'broad 172.16/12 FreeSWITCH match remains'
grep -Fq 'type=identify' "$tmp_dir/empty-matches.yaml" && fail 'FreeSWITCH endpoint still uses source-IP identification'
grep -Fq 'auth=freeswitch-inbound-auth' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH inbound Digest auth is missing'
grep -Fq 'identify_by=username,auth_username' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH endpoint is not selected by SIP identity'
grep -Fq 'outbound_auth=freeswitch-auth' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH outbound authentication was removed'
grep -Fq 'freeswitch-inbound-auth' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH inbound auth object generation is missing'
grep -Fq 'username=freeswitch' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH SIP Digest username is missing'
grep -Fq '$(cat /tmp/avoip-freeswitch-peer-password)" > /tmp/avoip-pjsip-auth.conf' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk outbound Digest auth is not sourced from the ExternalSecret password'
grep -Fq 'avoip-freeswitch-peer-password' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH peer password is not Secret-backed'
grep -Fq 'ASTERISK_PEER_PASSWORD' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH gateway does not receive peer credentials from a Secret'
grep -Fq 'from-user" value="freeswitch' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH From identity does not select the named Asterisk endpoint'
grep -Fq 'kind: Password' "$tmp_dir/empty-matches.yaml" || fail 'random peer password generator is missing'
grep -Fq "encoding: 'hex'" "$tmp_dir/empty-matches.yaml" || fail 'peer password is not generated as hex'
grep -Fq "refreshPolicy: 'CreatedOnce'" "$tmp_dir/empty-matches.yaml" || fail 'peer password is not stable across periodic syncs'
grep -Fq 'immutable: true' "$tmp_dir/empty-matches.yaml" || fail 'generated peer Secret can be overwritten on ExternalSecret recreation'
grep -Fq 'password" value="$${asterisk_peer_password}"' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH gateway Digest password is not sourced from its Secret'
grep -Fq 'pjsip set logger on' "$tmp_dir/empty-matches.yaml" && fail 'Asterisk SIP packet logging could expose Digest headers'
grep -Fq '<param name="sip-trace" value="false"/>' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH Asterisk profile SIP packet tracing is not disabled'
grep -Fq 'type=aor' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH AOR configuration was removed'
grep -Fq 'transport=transport-tls' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH TLS transport was removed'
grep -Fq 'application="rxfax"' "$tmp_dir/empty-matches.yaml" || fail 'existing FreeSWITCH fax receive configuration was removed'
grep -Fq 'mountPath: /tmp/avoip-freeswitch-peer-password' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH peer Secret mount is missing'
grep -Fq 'allowedOrigins: []' "$chart_dir/values.yaml" || fail 'configurable WSS allowedOrigins value was removed'
grep -Fq "value: '/ws'" "$tmp_dir/empty-matches.yaml" || fail 'SIP Core route no longer matches /ws'
grep -Fq 'port: 8088' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core route no longer targets port 8088'
grep -Fq "name: 'siptest-avoip-kamailio'" "$tmp_dir/empty-matches.yaml" || fail 'SIP Core HTTPRoute does not target Kamailio'

# The WebSocket TCP peer is Envoy (172.20.57.213). Endpoint selection is
# username-first and does not consume HTTP upgrade headers. A spoofed XFF value
# therefore cannot select an endpoint or satisfy SIP Digest.
if grep -Fq 'X-Forwarded-For' "$tmp_dir/empty-matches.yaml"; then
  fail 'rendered Asterisk configuration consumes forwarded client identity'
fi
grep -Fq 'endpoint_identifier_order=username,auth_username,ip,anonymous' "$tmp_dir/empty-matches.yaml" || fail 'Envoy peer regression does not select by SIP username'
grep -Fq 'auth=7101' "$tmp_dir/empty-matches.yaml" || fail 'Envoy peer regression endpoint does not require Digest auth'
grep -Fq 'context=from-sipcore-7101' "$tmp_dir/empty-matches.yaml" || fail 'Envoy peer regression uses the wrong dialplan context'
grep -Fq 'exten => 9090,1,Answer()' "$tmp_dir/empty-matches.yaml" || fail 'Envoy peer regression destination is missing'
grep -Fq '172.20.57.213' "$tmp_dir/empty-matches.yaml" && fail 'Envoy TCP peer was rendered as a trusted identity'
grep -Fq 'auth=7101' "$tmp_dir/empty-matches.yaml" || fail 'spoofed XFF regression has no SIP Digest authentication check'

if grep -En '^[[:space:]]*#[[:space:]]' "$chart_dir/templates/Asterisk/AsteriskConfigTemplate.yaml" "$chart_dir/templates/Asterisk/AsteriskConfigs.yaml"; then
  fail 'invalid Asterisk # comment line found'
fi
grep -Fq '#include /tmp/avoip-pjsip-auth.conf' "$chart_dir/templates/Asterisk/AsteriskConfigTemplate.yaml" || fail 'Asterisk PJSIP auth include was removed'
grep -Fq '#include /tmp/avoip-sipcore-pjsip.conf' "$chart_dir/templates/Asterisk/AsteriskConfigTemplate.yaml" || fail 'Asterisk SIP Core include was removed'

printf 'Asterisk SIP Core render checks passed. These are static render checks, not live SIP authentication or call tests.\n'
