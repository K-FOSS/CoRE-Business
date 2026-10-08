#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

render_sipcore() {
  helm template siptest "$chart_dir" --namespace core-prod \
    --set-json 'kamailio.instances=[{"name":"carrier","enabled":true,"role":"carrier-sbc","replicas":3},{"name":"internal","enabled":true,"role":"private-sbc","topology":{"redis":{"database":52,"secretName":"avoip-kamailio-internal-topos"}}}]' \
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
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-kamailio-internal-config") | .data["tls.cfg"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/internal-tls.cfg"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-freeswitch-misc-configs") | .data["asterisk-peer.xml"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/asterisk-peer.xml"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-freeswitch-dialplan-configs") | .data["public.xml"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/public.xml"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-freeswitch-dialplan-configs") | .data["asterisk.xml"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/asterisk.xml"
if grep -Fq 'gg-audio' "$tmp_dir/sipcore-disabled.yaml"; then
  fail 'FreeSWITCH GG audio route is present while SIP Core is disabled'
fi
if render_sipcore --set-string asterisk.sipCore.extensions[0].secret.remoteKey= >"$tmp_dir/missing-secret.yaml" 2>&1; then
  fail 'SIP Core rendered without an ExternalSecret password reference'
fi
if render_sipcore --set rtpengine.enabled=false >"$tmp_dir/missing-rtpengine.yaml" 2>&1; then
  fail 'SIP Core rendered without the required existing RTPEngine'
fi
if render_sipcore --set asterisk.sipCore.media.enabled=true >"$tmp_dir/direct-media.yaml" 2>&1; then
  fail 'SIP Core rendered direct Asterisk media instead of RTPEngine'
fi
if render_sipcore --set asterisk.turn.enabled=true --set asterisk.turn.port=0 >"$tmp_dir/invalid-turn-port.yaml" 2>&1; then
  fail 'Asterisk TURN rendered with an invalid port'
fi
if render_sipcore --set asterisk.turn.enabled=true --set-string asterisk.turn.credentialLifetimeSeconds=31536001 >"$tmp_dir/invalid-turn-lifetime.yaml" 2>&1; then
  fail 'Asterisk TURN rendered with a credential lifetime over one year'
fi
if render_sipcore --set asterisk.sipCore.privateEgressPort=5061 >"$tmp_dir/invalid-private-egress-port.yaml" 2>&1; then
  fail 'SIP Core private TLS egress port collided with the existing TLS listener'
fi
if render_sipcore --set-string asterisk.sipCore.ggAudioDestination='bad destination' >"$tmp_dir/invalid-gg-destination.yaml" 2>&1; then
  fail 'invalid FreeSWITCH GG audio SIP destination rendered'
fi
if helm template siptest "$chart_dir" --set freeswitch.asterisk.tlsPort=5061 >"$tmp_dir/colliding-freeswitch-port.yaml" 2>&1; then
  fail 'FreeSWITCH Asterisk TLS listener rendered on the public/Kamailio TLS port'
fi
if helm template siptest "$chart_dir" --set freeswitch.asterisk.tlsPort=5064 --set freeswitch.publicExposure.kamailio.backendPort=5064 >"$tmp_dir/colliding-kamailio-port.yaml" 2>&1; then
  fail 'FreeSWITCH Asterisk TLS listener rendered on the configured Kamailio backend port'
fi
render_sipcore --set-string asterisk.sipCore.ggAudioDestination=custom-audio > "$tmp_dir/custom-gg-destination.yaml"
render_sipcore --set asterisk.turn.enabled=false > "$tmp_dir/turn-disabled.yaml"
render_sipcore --set asterisk.turn.enabled=true > "$tmp_dir/turn-enabled.yaml"
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
grep -Fq 'Dial(PJSIP/gg-audio@freeswitch,30)' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk GG extension does not transfer to gg-audio@freeswitch'
grep -Fq 'Dial(PJSIP/custom-audio@freeswitch,30)' "$tmp_dir/custom-gg-destination.yaml" || fail 'Asterisk GG destination is not configurable'
grep -Fq 'destination_number" expression="^custom-audio$"' "$tmp_dir/custom-gg-destination.yaml" || fail 'FreeSWITCH does not use the configured GG SIP destination'
grep -Fq 'max_contacts=2' "$tmp_dir/empty-matches.yaml" || fail 'existing AOR contact limit was not rendered'
grep -Fq 'webrtc=yes' "$tmp_dir/empty-matches.yaml" || fail 'WebRTC endpoint settings are missing'
grep -Fq 'direct_media=no' "$tmp_dir/empty-matches.yaml" || fail 'direct_media=no was not preserved'
grep -Fq 'allow=ulaw,alaw' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core codecs were not preserved'
grep -Fq 'transport=transport-tls' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio-to-Asterisk TLS transport was not rendered'
grep -Fq 'outbound_proxy=sip:siptest-avoip-kamailio-internal-sipcore-return.core-prod.svc.cluster.local:5063\\;transport=tls\\;lr' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core endpoint does not route outbound calls through the dedicated internal TLS service'
grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio WebSocket listener was not rendered'
grep -Fq 'listen=tls:0.0.0.0:5063 advertise "siptest-avoip-kamailio-internal.core-prod.svc.cluster.local":5063 name "sipcore_private_tls"' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk-only internal Kamailio TLS return listener is missing'
grep -Fq '[server:any]' "$tmp_dir/internal-tls.cfg" || fail 'Asterisk return listener is missing its SNI-selected TLS profile'
grep -A6 -F '[server:any]' "$tmp_dir/internal-tls.cfg" | grep -Fq 'server_name = siptest-avoip-kamailio-internal-sipcore-return.core-prod.svc.cluster.local' || fail 'Asterisk return TLS profile does not match its dedicated SNI'
grep -A6 -F '[server:any]' "$tmp_dir/internal-tls.cfg" | grep -Fq 'verify_certificate = no' || fail 'Asterisk return listener still verifies an incompatible client certificate'
grep -A6 -F '[server:any]' "$tmp_dir/internal-tls.cfg" | grep -Fq 'require_certificate = no' || fail 'Asterisk return listener still requests a client certificate'
grep -A5 -F '[server:default]' "$tmp_dir/internal-tls.cfg" | grep -Fq 'require_certificate = yes' || fail 'the private peer TLS listener lost strict mTLS'
grep -Fq 'if ($proto == "tls" && $Rp == 5063)' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk return route still requires an incompatible client certificate'
grep -Fq 'name: sipcore-tls' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio private TLS return Service port is missing'
grep -Fq 'route[FROM_SIPCORE_ASTERISK]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio Asterisk-to-WebSocket route is missing'
grep -Fq 'handle_ruri_alias()' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio does not route calls through the registered WebSocket flow'
if grep -Fq 'SIP Core Target Not Allowed' "$tmp_dir/empty-matches.yaml"; then
  fail 'Kamailio incorrectly treats the random WebSocket Contact user as an extension number'
fi
grep -Fq 'RTPEngine SIP Core SDP update failed' "$tmp_dir/empty-matches.yaml" && fail 'SIP Core requests fail on unnecessary msg_apply_changes'
grep -Fq 'RTPEngine SIP Core outbound SDP update failed' "$tmp_dir/empty-matches.yaml" && fail 'Asterisk-originated SIP Core requests fail on unnecessary msg_apply_changes'
msg_apply_changes_count="$(grep -Fc 'msg_apply_changes()' "$tmp_dir/empty-matches.yaml" || true)"
[[ "$msg_apply_changes_count" == '1' ]] || fail 'the invalid msg_apply_changes call remains in SIP Core reply handling or carrier behavior changed'
grep -Fq 'if (is_method("REGISTER") && is_present_hf("Contact") && $hdr(Contact) != "*")' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio does not preserve a WebSocket route alias on registration'
grep -Fq 'rtpengine_manage("WebRTC replace-origin internal external")' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk-originated Home Assistant media is not relayed through RTPEngine'
grep -Fq 'route[FROM_SIPCORE]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio SIP Core route is missing'
grep -Fq 'fix_nated_register' "$tmp_dir/empty-matches.yaml" && fail 'SIP Core route calls nathelper REGISTER helper without Kamailio registrar configuration'
grep -Fq 'route[TO_SIPCORE_ASTERISK]' "$tmp_dir/empty-matches.yaml" || fail 'Kamailio-to-Asterisk TLS route is missing'
grep -Fq 'rtpengine_manage("WebRTC replace-origin external internal")' "$tmp_dir/empty-matches.yaml" || fail 'Home Assistant media is not relayed through RTPEngine'
if grep -Eq 'record_route_preset\("sip:[^"]+;transport=wss"\)' "$tmp_dir/empty-matches.yaml"; then
  fail 'Kamailio passes an unsupported WSS Record-Route transport to Asterisk'
fi
if grep -Fq 'record_route_preset("sip:' "$tmp_dir/empty-matches.yaml"; then
  fail 'Kamailio record_route_preset incorrectly includes a scheme that the function adds itself'
fi
rtpengine_sdp_line="$(grep -n 'rtpengine_manage("WebRTC replace-origin external internal")' "$tmp_dir/empty-matches.yaml" | head -n 1 | cut -d: -f1)"
record_route_line="$(grep -n 'record_route_preset("siptest-avoip-kamailio-internal-sipcore-return.core-prod.svc.cluster.local:5063;transport=tls")' "$tmp_dir/empty-matches.yaml" | head -n 1 | cut -d: -f1)"
if [[ -z "$rtpengine_sdp_line" || -z "$record_route_line" || "$rtpengine_sdp_line" -ge "$record_route_line" ]]; then
  fail 'RTPEngine SDP updates must happen before adding Record-Route'
fi
grep -Fq 'password must be hexadecimal' "$tmp_dir/empty-matches.yaml" || fail 'startup hexadecimal password validation is missing'
grep -Fq 'at least 32 characters' "$tmp_dir/empty-matches.yaml" || fail 'startup password length validation is missing'
grep -Fq 'secretKeyRef:' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core secret is not mounted from a Secret'
grep -Fq 'remoteRef:' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core password is not sourced from External Secrets'
grep -Fq "key: 'unit/test/7101'" "$tmp_dir/empty-matches.yaml" || fail 'configured extension password remote key is not preserved'
grep -Fq 'pjsip set logger on' "$tmp_dir/empty-matches.yaml" && fail 'SIP packet logging could expose SIP Authorization headers'
grep -Fq 'matrix-turn-auth' "$tmp_dir/empty-matches.yaml" && fail 'default Asterisk TURN unexpectedly mounts the Social/Matrix Secret'
grep -Fq 'avoip-turn.conf' "$tmp_dir/empty-matches.yaml" && fail 'default Asterisk TURN unexpectedly generates runtime configuration'
grep -Fq 'openssl dgst -sha1 -hmac "$turn_shared_secret" -binary' "$tmp_dir/turn-enabled.yaml" || fail 'optional Asterisk REST TURN credential derivation is missing'
grep -Fq 'secretName: matrix-turn-auth' "$tmp_dir/turn-enabled.yaml" || fail 'enabled Asterisk TURN does not mount the existing Social/Matrix Secret'
grep -Fq 'cat /run/avoip/turn/TURN_SHARED_SECRET' "$tmp_dir/turn-enabled.yaml" || fail 'Asterisk TURN shared secret key is incorrect'
grep -Fq 'mountPath: /run/avoip/turn' "$tmp_dir/turn-enabled.yaml" || fail 'Asterisk TURN Secret mount is missing'
grep -Fq 'turnaddr=nat.mylogin.space:3478' "$tmp_dir/turn-enabled.yaml" || fail 'Asterisk TURN server config is missing'
grep -Fq 'stunaddr=nat.mylogin.space:3478' "$tmp_dir/turn-enabled.yaml" || fail 'Asterisk STUN server config is missing'
grep -Fq '#include /tmp/avoip-turn.conf' "$tmp_dir/turn-enabled.yaml" || fail 'Asterisk runtime TURN config include is missing'
if grep -Eq '^[[:space:]]*turnpassword=' "$tmp_dir/turn-enabled.yaml"; then
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
grep -Fq 'contact=sip:siptest-avoip-freeswitch.core-prod.svc.cluster.local:5064;transport=tls' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk FreeSWITCH peer does not use its dedicated Service TLS port'
grep -Fq 'internal_tls_port=5061' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH internal TLS port does not match its Service target'
grep -Fq 'asterisk_tls_port=5064' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH dedicated Asterisk TLS port is missing'
grep -Fq 'tls-sip-port" value="$${asterisk_tls_port}"' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH Asterisk profile does not listen on its dedicated TLS port'
grep -Fq 'tls-verify-policy" value="subjects_all"' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH Asterisk profile does not validate incoming and outgoing TLS certificates'
grep -Fq 'tls-verify-in-subjects" value="siptest-avoip-asterisk.core-prod.svc.cluster.local"' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH Asterisk profile does not restrict inbound mTLS to the Asterisk certificate identity'
yq -e 'select(.kind == "Certificate" and .metadata.name == "siptest-avoip-asterisk-sip-tls") | .spec.usages | contains(["server auth", "client auth"])' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'Asterisk TLS Certificate does not request both server and client authentication usages'
grep -Fq 'cert_file=/etc/asterisk/tls/tls.crt' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk PJSIP does not present its TLS client certificate'
grep -Fq 'priv_key_file=/etc/asterisk/tls/tls.key' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk PJSIP TLS client certificate has no private key configured'
yq -e 'select(.kind == "Service" and .metadata.name == "siptest-avoip-freeswitch") | any(.spec.ports[]; .name == "tls-asterisk" and .port == 5064 and .targetPort == "tls-asterisk")' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'FreeSWITCH dedicated Asterisk TLS Service port is missing'
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("freeswitch"))) | .spec.template.spec.containers[] | select(.name == "freeswitch") | any(.ports[]; .name == "tls-asterisk" and .containerPort == 5064)' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'FreeSWITCH pod does not declare the target port for its dedicated Asterisk TLS listener'
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("asterisk"))) | .spec.template.spec.containers[] | select(.name == "asterisk") | any(.ports[]?; .name == "tls-asterisk")' "$tmp_dir/empty-matches.yaml" >/dev/null && fail 'dedicated FreeSWITCH TLS port was mistakenly declared on the Asterisk pod'
grep -Fq 'freeswitch-inbound-auth' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH inbound auth object generation is missing'
grep -Fq 'username=freeswitch' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH SIP Digest username is missing'
grep -Fq '$(cat /tmp/avoip-freeswitch-peer-password)" > /tmp/avoip-pjsip-auth.conf' "$tmp_dir/empty-matches.yaml" || fail 'Asterisk outbound Digest auth is not sourced from the ExternalSecret password'
grep -Fq 'avoip-freeswitch-peer-password' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH peer password is not Secret-backed'
grep -Fq 'ASTERISK_PEER_PASSWORD' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH gateway does not receive peer credentials from a Secret'
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("freeswitch"))) | .spec.template.spec.containers[] | select(.name == "freeswitch") | any(.env[]; .name == "ASTERISK_PEER_PASSWORD" and .valueFrom.secretKeyRef.name == "siptest-avoip-asterisk-freeswitch-peer" and .valueFrom.secretKeyRef.key == "password")' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'FreeSWITCH SIP process does not receive the Asterisk peer password from its Secret'
yq -e 'select(.kind == "Deployment" and (.metadata.name | contains("freeswitch"))) | .spec.template.spec.initContainers[]? | any(.env[]?; .name == "ASTERISK_PEER_PASSWORD")' "$tmp_dir/empty-matches.yaml" >/dev/null && fail 'Asterisk peer password is exposed to an unrelated FreeSWITCH init container'
grep -Fq '<user id="freeswitch">' "$tmp_dir/asterisk-peer.xml" || fail 'FreeSWITCH has no static peer directory identity for the Secret-backed Asterisk Digest credential'
grep -Fq 'value="$${asterisk_peer_password}"' "$tmp_dir/asterisk-peer.xml" || fail 'FreeSWITCH peer directory password is not sourced from the generated Secret'
grep -Fq '<context name="from-asterisk">' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH dedicated Asterisk dialplan interface is missing'
grep -Fq '<extension name="gg-audio">' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH gg-audio dialplan user is missing'
grep -Fq 'destination_number" expression="^gg-audio$"' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH does not match the gg-audio destination'
grep -Fq 'sip_auth_username}" expression="^freeswitch$"' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH GG audio route is not restricted to the authenticated Asterisk peer'
grep -Fq 'data="shout://' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH GG audio route does not play the configured audio'
grep -Fq 'Add other site-specific destinations and transfer scripts here' "$tmp_dir/asterisk.xml" || fail 'FreeSWITCH Asterisk dialplan customization point is undocumented'
grep -Fq 'mountPath: /etc/freeswitch/dialplan/asterisk.xml' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH dedicated Asterisk dialplan file is not mounted'
grep -Fq 'from-user" value="freeswitch' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH From identity does not select the named Asterisk endpoint'
grep -Fq 'kind: Password' "$tmp_dir/empty-matches.yaml" || fail 'random peer password generator is missing'
grep -Fq "encoding: 'hex'" "$tmp_dir/empty-matches.yaml" || fail 'peer password is not generated as hex'
grep -Fq "refreshPolicy: 'CreatedOnce'" "$tmp_dir/empty-matches.yaml" || fail 'peer password is not stable across periodic syncs'
grep -Fq 'immutable: true' "$tmp_dir/empty-matches.yaml" || fail 'generated peer Secret can be overwritten on ExternalSecret recreation'
grep -Fq 'password" value="$${asterisk_peer_password}"' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH gateway Digest password is not sourced from its Secret'
grep -Fq 'pjsip set logger on' "$tmp_dir/empty-matches.yaml" && fail 'Asterisk SIP packet logging could expose Digest headers'
grep -Fq '<param name="sip-trace" value="false"/>' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH Asterisk profile SIP packet tracing is not disabled'
asterisk_profile="$(sed -n '/<profile name="asterisk">/,/<\/profile>/p' "$tmp_dir/empty-matches.yaml")"
grep -Fq '<param name="auth-calls" value="true"/>' <<<"$asterisk_profile" || fail 'FreeSWITCH Asterisk profile does not require SIP Digest authentication'
grep -Fq '<param name="context" value="from-asterisk"/>' <<<"$asterisk_profile" || fail 'FreeSWITCH Asterisk profile does not use its dedicated dialplan context'
grep -Fq '<param name="apply-inbound-acl" value="asterisk"/>' <<<"$asterisk_profile" && fail 'FreeSWITCH Asterisk profile can bypass Digest through a broad private-network ACL'
grep -Fq 'type=aor' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH AOR configuration was removed'
grep -Fq 'transport=transport-tls' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH TLS transport was removed'
grep -Fq 'application="rxfax"' "$tmp_dir/empty-matches.yaml" || fail 'existing FreeSWITCH fax receive configuration was removed'
grep -Fq 'mountPath: /tmp/avoip-freeswitch-peer-password' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH peer Secret mount is missing'
grep -Fq '<param name="auth-calls" value="true"/>' <<<"$asterisk_profile" || fail 'FreeSWITCH Asterisk profile does not validate the peer credentials'
grep -Fq 'mountPath: /etc/freeswitch/directory/asterisk-peer.xml' "$tmp_dir/empty-matches.yaml" || fail 'FreeSWITCH static peer directory identity is not mounted'
grep -Fq 'allowedOrigins: []' "$chart_dir/values.yaml" || fail 'configurable WSS allowedOrigins value was removed'
grep -Fq "value: '/ws'" "$tmp_dir/empty-matches.yaml" || fail 'SIP Core route no longer matches /ws'
grep -Fq 'port: 8088' "$tmp_dir/empty-matches.yaml" || fail 'SIP Core route no longer targets port 8088'
grep -Fq "name: 'siptest-avoip-kamailio-internal'" "$tmp_dir/empty-matches.yaml" || fail 'SIP Core HTTPRoute does not target the internal Kamailio Service'
yq -e 'select(.kind == "Service" and .metadata.name == "siptest-avoip-kamailio-internal-sipcore-return") | any(.spec.ports[]; .port == 5063 and .targetPort == "sipcore-tls")' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'Asterisk return listener lacks its dedicated SNI Service'
yq -e 'select(.kind == "Certificate" and .metadata.name == "siptest-avoip-kamailio-internal-sip-tls") | .spec.dnsNames | contains(["siptest-avoip-kamailio-internal-sipcore-return.core-prod.svc.cluster.local"])' "$tmp_dir/empty-matches.yaml" >/dev/null || fail 'internal Kamailio certificate does not cover the Asterisk return SNI'

yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-kamailio-config") | .data["kamailio.cfg"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/carrier-kamailio.cfg"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "siptest-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$tmp_dir/empty-matches.yaml" > "$tmp_dir/internal-kamailio.cfg"
grep -Fq 'listen=tcp:0.0.0.0:8088 name "sipcore_ws"' "$tmp_dir/internal-kamailio.cfg" || fail 'internal Kamailio is missing its SIP Core WebSocket listener'
grep -Fq 'route[FROM_SIPCORE]' "$tmp_dir/internal-kamailio.cfg" || fail 'internal Kamailio is missing the SIP Core routing path'
grep -Fq 'rtpengine_manage("WebRTC replace-origin external internal")' "$tmp_dir/internal-kamailio.cfg" || fail 'internal Kamailio is missing SIP Core RTPEngine media handling'
grep -Fq 'onreply_route[SIPCORE_WS_REPLY]' "$tmp_dir/internal-kamailio.cfg" || fail 'SIP Core WebSocket replies are not isolated from carrier reply handling'
grep -Fq 'onreply_route[SIPCORE_ASTERISK_REPLY]' "$tmp_dir/internal-kamailio.cfg" || fail 'Asterisk reverse-leg replies are not isolated from carrier reply handling'
grep -Fq 'RTPEngine SIP Core outbound answer handling failed' "$tmp_dir/internal-kamailio.cfg" || fail 'Asterisk-originated media answers are not relayed through RTPEngine'
grep -Fq 'SIP RX RAW pod=' "$tmp_dir/internal-kamailio.cfg" && fail 'internal Kamailio raw SIP logging could expose Digest Authorization headers'
grep -Fq 'SIP FLOWROUTE RX BEGIN' "$tmp_dir/internal-kamailio.cfg" && fail 'internal Kamailio has carrier packet logging enabled'
grep -Fq 'loadmodule "siptrace.so"' "$tmp_dir/internal-kamailio.cfg" && fail 'internal Kamailio SIP tracing could capture Digest headers'
grep -Fq 'SIP RX RAW pod=' "$tmp_dir/carrier-kamailio.cfg" && fail 'carrier raw SIP logging could expose Digest Authorization headers while SIP Core is enabled'
grep -Fq 'SIP FLOWROUTE RX BEGIN' "$tmp_dir/carrier-kamailio.cfg" && fail 'carrier packet logging remains active while SIP Core is enabled'
grep -Fq 'loadmodule "siptrace.so"' "$tmp_dir/carrier-kamailio.cfg" && fail 'carrier SIP tracing remains active while SIP Core is enabled'
if grep -Eq 'sipcore_ws|FROM_SIPCORE|sipcore_private_tls' "$tmp_dir/carrier-kamailio.cfg"; then
  fail 'carrier SBC still contains SIP Core WebSocket or Asterisk routing'
fi
grep -Fq 'route[FROM_CARRIER]' "$tmp_dir/carrier-kamailio.cfg" || fail 'carrier SBC lost its existing carrier ingress route'
grep -Fq "application=\"rxfax\"" "$tmp_dir/empty-matches.yaml" || fail 'existing FreeSWITCH fax receive configuration was removed'
grep -Fq "'k8s:io.kubernetes.pod.namespace': 'kube-system'" "$tmp_dir/empty-matches.yaml" || fail 'internal policy does not select the live Envoy Gateway namespace'
grep -Fq "port: '5063'" "$tmp_dir/empty-matches.yaml" || fail 'internal policy does not expose the Asterisk return port'

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
