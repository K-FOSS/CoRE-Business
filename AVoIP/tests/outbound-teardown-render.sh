#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart_dir="$repo_root/AVoIP"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT

helm template core-home1-talos-prod "$chart_dir" --namespace core-prod \
  -f "$chart_dir/tests/fixtures/outbound-teardown.yaml" \
  --set avoipAdmin.bridgedCalls.enabled=false > "$render"

carrier_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-config") | .data["kamailio.cfg"]' "$render")"
internal_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$render")"
internal_rollout="$(yq -r 'select(.kind == "Deployment" and .metadata.labels["app.kubernetes.io/controller"] == "kamailio-internal") | .spec.strategy.rollingUpdate' "$render")"
internal_policy="$(yq 'select(.kind == "CiliumNetworkPolicy" and .spec.endpointSelector.matchLabels["app.kubernetes.io/controller"] == "kamailio-internal") | .spec' "$render")"
internal_tls="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["tls.cfg"]' "$render")"
carrier_tls="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-config") | .data["tls.cfg"]' "$render")"
freeswitch_dialplan="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-freeswitch-dialplan-configs") | .data["asterisk.xml"]' "$render")"
asterisk_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-asterisk-configs") | .data["extensions.conf"]' "$render")"
flowroute_profile="$(yq -r 'select(.kind == "ExternalSecret" and .metadata.name == "core-home1-talos-prod-avoip-freeswitch-flowroute") | .spec.target.template.data["flowroute.xml"]' "$render")"

# The carrier tier's shared TOPOS store and three-way route restoration remain
# enabled; the internal tier has its own store and a private_tls socket only.
grep -Fq 'modparam("topos", "storage", "redis")' <<< "$carrier_cfg"
grep -Fq 'modparam("topos", "storage", "redis")' <<< "$internal_cfg"
grep -Fq 'listen=tls:KAMAILIO_POD_IP:5062 advertise' <<< "$internal_cfg"
! grep -Fq 'name "public_tls"' <<< "$internal_cfg"

# A carrier-originated dialog arrives on the authenticated carrier peer path.
# The route uses the TOPOS-restored target, keeps Route headers, and chooses
# the socket actually bound by the internal tier.
grep -Fq 'if ($var(peer_name) == "carrier") {' <<< "$internal_cfg"
grep -Fq 'set_send_socket_name("private_tls");' <<< "$internal_cfg"
grep -Fq '$du = "sip:" + $rd + ":" + $rp + ";transport=tls";' <<< "$internal_cfg"
grep -Fq '$rp != 5081' <<< "$internal_cfg"
grep -Fq '$xavp(tls=>server_name) =' <<< "$internal_cfg"
grep -Fq 'topos_result=route-restored' <<< "$internal_cfg"
grep -Fq 'route=$hdr(Route)' <<< "$internal_cfg"
! grep -Fq '$du = $ru;' <<< "$internal_cfg"
! grep -Fq 'stage=asterisk-to-carrier-fallback' <<< "$internal_cfg"
managed_outbound_setup="$(sed -n '/Select the actual carrier next hop before building Record-Route/,/route(PRIVATE_RELAY); exit;/p' <<< "$internal_cfg")"
gateway_line="$(grep -n -m1 'route(PRIVATE_TO_CARRIER_GATEWAY);' <<< "$managed_outbound_setup" | cut -d: -f1)"
record_route_line="$(grep -n -m1 'record_route();' <<< "$managed_outbound_setup" | cut -d: -f1)"
[[ -n "$gateway_line" && -n "$record_route_line" && "$gateway_line" -lt "$record_route_line" ]]
grep -Fq '$dlg_var(outbound_carrier) = "yes";' <<< "$managed_outbound_setup"
managed_extension_route="$(sed -n '/route\[MANAGED_EXTENSION\]/,/^    }/p' <<< "$internal_cfg")"
grep -Fq 'core_managed_from=$ft' <<< "$managed_extension_route"
grep -Fq '$(route_uri{uri.param,core_managed_from})' <<< "$internal_cfg"
grep -Fq 'if ($ft == $var(core_managed_from_tag))' <<< "$internal_cfg"
grep -Fq 'else if ($tt == $var(core_managed_from_tag))' <<< "$internal_cfg"
grep -Fq 'route(PRIVATE_TO_CARRIER_GATEWAY);' <<< "$internal_cfg"
grep -Fq 'route(TO_SIPCORE_ASTERISK);' <<< "$internal_cfg"
managed_dialog_routes="$(sed -n '/$var(core_managed_from_tag) = "";/,/if (has_totag() && $dlg_var(managed_outbound)/p' <<< "$internal_cfg")"
[[ "$(grep -Fc 'loose_route()' <<< "$managed_dialog_routes")" -eq 1 ]]
grep -Fq '<param name="tls-bind-params" value="transport=tls"/>' <<< "$flowroute_profile"
grep -Fq '<param name="bind-params" value="transport=udp"/>' <<< "$flowroute_profile"
grep -Fq '<param name="reuse-connections" value="true"/>' <<< "$flowroute_profile"
flowroute_settings="$(sed -n '/<settings>/,/<\/settings>/p' <<< "$flowroute_profile")"
grep -Fq '<param name="rtp-timer-name" value="soft"/>' <<< "$flowroute_settings"
grep -Fq '<param name="rtp-notimer-during-bridge" value="false"/>' <<< "$flowroute_settings"
registration_gateway="$(sed -n '/<gateway name="flowroute">/,/<\/gateway>/p' <<< "$flowroute_profile")"
tls_gateway="$(sed -n '/<gateway name="flowroute-tls">/,/<\/gateway>/p' <<< "$flowroute_profile")"
grep -Fq '<param name="register-transport" value="udp"/>' <<< "$registration_gateway"
grep -Fq '<param name="register" value="true"/>' <<< "$registration_gateway"
grep -Fq '<param name="register-transport" value="tls"/>' <<< "$tls_gateway"
grep -Fq '<param name="register" value="false"/>' <<< "$tls_gateway"
grep -Fq '<param name="from-domain" value="sip.core-home1-talos-prod.home1.yvr.resolvemy.host"/>' <<< "$tls_gateway"
grep -Fq '<param name="caller-id-in-from" value="true"/>' <<< "$tls_gateway"
# Provider legs are generated by the authenticated Admin XML dialplan and use
# the configured site gateway. The Helm bootstrap must not restore the legacy
# static Flowroute-specific route; the Admin runtime route is covered by Go
# tests in image/flowroute-sms/admin_test.go.
! grep -Fq 'sofia/gateway/flowroute-tls/' <<< "$freeswitch_dialplan"
! grep -Fq 'sofia/gateway/flowroute/' <<< "$freeswitch_dialplan"
grep -Fq 'PJSIP_HEADER(add,X-Call-ID)=${AVOIP_HOMER_CORRELATION_ID}' <<< "$asterisk_cfg"
grep -Fq 'sip_h_X-Core-Call-Linkedid' "$chart_dir/image/flowroute-sms/routing.go"
grep -Fq 'sip_h_X-Core-Origin-Uniqueid' "$chart_dir/image/flowroute-sms/routing.go"
grep -Fq 'sip_h_X-Core-Extension=${bridged_call_extension}' <<< "$freeswitch_dialplan"
grep -Fq 'sip_h_X-Core-Call-Linkedid=${bridged_call_id}' <<< "$freeswitch_dialplan"
grep -Fq 'sip_h_X-Core-Origin-Uniqueid=${origination_uuid}' <<< "$freeswitch_dialplan"
! grep -Fq 'sofia/gateway/flowroute/' <<< "$freeswitch_dialplan"
! grep -Fq 'sip_invite_contact_params=' <<< "$freeswitch_dialplan"
freeswitch_tls="$(sed -n '/server_name = core-home1-talos-prod-avoip-freeswitch.core-prod.svc.k8s.home1.resolvemy.host/,/certificate = \/etc\/kamailio\/mtls\/tls.crt/p' <<< "$internal_tls")"
grep -Fq 'verify_certificate = yes' <<< "$freeswitch_tls"
grep -Fq 'ca_list = /etc/kamailio/peer-ca/ca.crt' <<< "$freeswitch_tls"
grep -Fq 'certificate = /etc/kamailio/mtls/tls.crt' <<< "$freeswitch_tls"

# SIP Core's dedicated return Service has a separate SAN from the carrier's
# internal Kamailio peer Service. Its restored Route must use the internal
# socket, exact SNI, internal trust bundle, and Vault mTLS client identity.
sipcore_return_host="$(yq -r 'select(.kind == "Certificate") | .spec.dnsNames[] | select(contains("sipcore-return"))' "$render" | head -n1)"
[[ -n "$sipcore_return_host" ]]
grep -Fq "advertise \"$sipcore_return_host\":5063 name \"sipcore_private_tls\"" <<< "$internal_cfg"
grep -Fq "alias=\"$sipcore_return_host:5063\"" <<< "$internal_cfg"
sipcore_client_profile="$(sed -n "/server_name = ${sipcore_return_host}/,/certificate = \/etc\/kamailio\/mtls\/tls.crt/p" <<< "$carrier_tls")"
grep -Fq "server_name = $sipcore_return_host" <<< "$sipcore_client_profile"
grep -Fq 'verify_certificate = yes' <<< "$sipcore_client_profile"
grep -Fq 'ca_list = /etc/kamailio/peer-ca/ca.crt' <<< "$sipcore_client_profile"
grep -Fq 'private_key = /etc/kamailio/mtls/tls.key' <<< "$sipcore_client_profile"
grep -Fq 'certificate = /etc/kamailio/mtls/tls.crt' <<< "$sipcore_client_profile"
grep -Fq "if (\$(du{uri.host}) == \"$sipcore_return_host\")" <<< "$carrier_cfg"
grep -Fq 'class=internal-sipcore route_source=topos-or-loose-route' <<< "$carrier_cfg"
! grep -Fq 'class=internal-sipcore' <<< "$internal_cfg"

# TM reports its negative relay result and handles duplicate requests before
# media/quota teardown side effects in both hops.
grep -Fq 't_relay_result=$var(private_relay_result)' <<< "$internal_cfg"
grep -Fq 'failure_route[PRIVATE_BYE_FAILURE]' <<< "$internal_cfg"
! grep -Eq '\$T_[[:alnum:]_]+' <<< "$internal_cfg"
grep -Fq '"maxSurge": 1' <<< "$internal_rollout"
grep -Fq '"maxUnavailable": 0' <<< "$internal_rollout"
yq -e 'any(.egress[]; any(.toEndpoints[]?.matchLabels; .["app.kubernetes.io/controller"] == "freeswitch") and any(.toPorts[]?.ports[]; .port == "5081" and .protocol == "TCP"))' <<< "$internal_policy" >/dev/null
grep -Fq 'SIP BYE wire attempt' <<< "$internal_cfg"
grep -Fq 'connection_id=$conid transport=$snd(proto)' <<< "$internal_cfg"
grep -Fq 'route=$route_uri next_hop=$du' <<< "$carrier_cfg"
grep -Fq 'destination_ip=$snd(ip) destination_port=$snd(port)' <<< "$carrier_cfg"
grep -Fq 'SIP relay result=failed tier=private' <<< "$internal_cfg"
grep -Fq 'destination_host=$dd destination_port=$dp transport=$dP socket=$fsn' <<< "$internal_cfg"
grep -Fq 'stage=websocket-flow-unavailable' <<< "$internal_cfg"
grep -Fq 'route=$route_uri next_hop=$du' <<< "$internal_cfg"
grep -Fq 'local id=ARGV[1];local concurrent=tonumber(" + $var(managed_concurrent_calls)' <<< "$carrier_cfg"
grep -Fq 'local id=ARGV[1];local rate=tonumber(" + $var(inbound_calls_per_minute)' <<< "$carrier_cfg"
grep -Fq '"topos", "EVAL %s 1 %s %s"' <<< "$carrier_cfg"
grep -Fq 'AVOIP inbound quota request invalid' <<< "$carrier_cfg"
grep -Fq 'AVOIP inbound quota payload invalid' <<< "$carrier_cfg"
grep -Fq 'tls_sni=$xavp(tls=>server_name)' <<< "$internal_cfg"
grep -Fq 'if (is_method("BYE") && t_check_trans()) {' <<< "$internal_cfg"
grep -Fq 'if (is_method("BYE") && t_check_trans()) {' <<< "$carrier_cfg"
# Carrier Kamailio must not own a wall-clock dialog timeout for a FreeSWITCH
# B2BUA call. The quota reservation is shared separately and FreeSWITCH owns
# the call-leg lifecycle.
grep -Fq 'avoip:out:call:' <<< "$carrier_cfg"
grep -Fq 'outbound_call_mapping' <<< "$carrier_cfg"
grep -Fq 'local q=redis.call('\''GET'\'',KEYS[1])' <<< "$carrier_cfg"
! grep -Fq 'OUTBOUND_DIALOG_TIMEOUT' <<< "$carrier_cfg"
grep -Fq 'inbound_call_mapping' <<< "$carrier_cfg"
! grep -Fq 'INBOUND_DIALOG_TIMEOUT' <<< "$carrier_cfg"
! grep -Fq 'dlg_set_timeout("$var(inbound_max_duration)")' <<< "$carrier_cfg"
outbound_lifecycle_cfg="$(sed -n '/route\[FROM_OUTBOUND_PEER\]/,/route\[OUTBOUND_BYE_PENDING\]/p' <<< "$carrier_cfg")"
! grep -Fq 'dlg_set_timeout("$var(managed_max_duration_seconds)")' <<< "$outbound_lifecycle_cfg"
! grep -Fq 'dlg_bye("all")' <<< "$outbound_lifecycle_cfg"
grep -Fq 'rtpengine_delete=requested' <<< "$carrier_cfg"
grep -Fq 'modparam("dialog", "send_bye", 0)' <<< "$carrier_cfg"
grep -Fq 'OUTBOUND_BYE_PENDING' <<< "$carrier_cfg"
grep -Fq 'onreply_route[OUTBOUND_BYE_REPLY]' <<< "$carrier_cfg"
grep -Fq "redis.call('EXISTS',KEYS[1])==0" <<< "$carrier_cfg"
grep -Fq 't_on_failure("OUTBOUND_BYE_FAILURE");' <<< "$carrier_cfg"
grep -Fq 'route[OUTBOUND_BYE_CLEAR]' <<< "$carrier_cfg"
grep -Fq 'Set SNI from the restored next hop before relaying' <<< "$carrier_cfg"
grep -Fq '$xavp(tls=>server_name) = $(du{uri.host});' <<< "$carrier_cfg"
clear_cfg="$(sed -n '/route\[OUTBOUND_BYE_CLEAR\]/,/failure_route\[OUTBOUND_BYE_FAILURE\]/p' <<< "$carrier_cfg")"
grep -Fq '"topos", "EVAL %s 1 %s",' <<< "$clear_cfg"
! grep -Fq '"topos", "EVAL %s 1 %s %s",' <<< "$clear_cfg"
grep -Fq 'rtpengine_delete_result=$var(rtpengine_delete_result)' <<< "$carrier_cfg"

printf '%s\n' 'PASS: outbound teardown route renders the carrier-to-internal mTLS path with independent TOPOS stores'
printf '%s\n' 'PASS: carrier BYEs use TLS to the restored FreeSWITCH owner; the Helm bootstrap contains no legacy provider-specific outbound route'
printf '%s\n' 'PASS: SIP Core carrier BYEs follow the dialog route; outbound Record-Route is built after selecting the carrier socket'
printf '%s\n' 'PASS: relay results and topology decisions are logged; retransmissions exit before teardown side effects'
printf '%s\n' 'PASS: private Kamailio retains its ready pod until a replacement passes startup validation'
printf '%s\n' 'PASS: internal Kamailio may send TLS signaling only to the FreeSWITCH dialog listener on port 5081'
