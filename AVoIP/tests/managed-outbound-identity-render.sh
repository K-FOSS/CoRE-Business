#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart_dir="$repo_root/AVoIP"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT

helm template core-home1-talos-prod "$chart_dir" --namespace core-prod \
  -f "$chart_dir/tests/fixtures/outbound-teardown.yaml" \
  --set avoipAdmin.enabled=true \
  --set avoipAdmin.routing.enabled=true > "$render"

asterisk_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-asterisk-configs") | .data["extensions.conf"]' "$render")"
internal_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-internal-config") | .data["kamailio.cfg"]' "$render")"
carrier_cfg="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-kamailio-config") | .data["kamailio.cfg"]' "$render")"
asterisk_pjsip="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-asterisk-config-tpl") | .data["pjsip.conf"]' "$render")"
asterisk_deploy="$(yq -c 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-asterisk")' "$render")"
asterisk_secret_reload="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "core-home1-talos-prod-avoip-asterisk") | .spec.template.metadata.annotations["secret.reloader.stakater.com/reload"]' "$render")"

# The locked per-extension Asterisk dialplan stamps the trusted identity on a
# new outbound PJSIP channel; Admin mode does not turn the extension into the
# From caller ID before Kamailio has applied policy.
grep -Fq 'Dial(PJSIP/${EXTEN}@carrier-outbound,120,b(sipcore-managed-outbound-headers^s^1(7101)))' <<< "$asterisk_cfg"
grep -Fq 'PJSIP_HEADER(remove,X-Core-Extension)=' <<< "$asterisk_cfg"
grep -Fq 'PJSIP_HEADER(add,X-Core-Extension)=${ARG1}' <<< "$asterisk_cfg"
grep -Fq 'PJSIP_HEADER(add,X-Core-Call-Linkedid)=${CHANNEL(linkedid)}' <<< "$asterisk_cfg"
grep -Fq 'PJSIP_HEADER(add,X-Core-Origin-Uniqueid)=${CHANNEL(uniqueid)}' <<< "$asterisk_cfg"
! grep -Fq 'Set(CALLERID(num)=7101)' <<< "$asterisk_cfg"
grep -Fq 'ca_list_file=/tmp/avoip-ca-bundle.pem' <<< "$asterisk_pjsip"
grep -Fq 'verify_server=yes' <<< "$asterisk_pjsip"
grep -Fq '"secretName":"core-home1-talos-prod-avoip-kamailio-internal-sip-tls"' <<< "$asterisk_deploy"
grep -Fq '"key":"ca.crt"' <<< "$asterisk_deploy"
grep -Fq 'cat /etc/ssl/certs/ca-certificates.crt /etc/asterisk/sipcore-ca/ca.crt > /tmp/avoip-ca-bundle.pem' <<< "$asterisk_deploy"
grep -Fq 'core-home1-talos-prod-avoip-kamailio-internal-sip-tls' <<< "$asterisk_secret_reload"

# Only the Asterisk-only TLS path promotes the stamped extension into the
# policy variable. The route looks up that identity and then overwrites From
# and P-Asserted-Identity with the Admin-authorized caller ID.
grep -Fq '$var(managed_extension_id) = $hdr(X-Core-Extension);' <<< "$internal_cfg"
grep -Fq '$var(managed_path) = "extensions." + $var(managed_extension_id);' <<< "$internal_cfg"
grep -Fq 'X-Core-Extension: $var(managed_extension_id)' <<< "$internal_cfg"
grep -Fq '$fU = $var(managed_caller_id);' <<< "$internal_cfg"
grep -Fq 'reject=trusted_extension_missing' <<< "$internal_cfg"
grep -Fq 'record_route_preset("core-home1-talos-prod-avoip-kamailio-internal-sipcore-return.core-prod.svc.k8s.home1.resolvemy.host:5063;transport=tls;lr");' <<< "$internal_cfg"
grep -Fq 'if ($var(side) == "sipcore") {' <<< "$internal_cfg"

# The authenticated private Kamailio handoff uses the extension from the
# trusted header and revalidates it against the active Admin snapshot. SIP
# From may change across hops, so only inter-site handoffs require a From
# caller-ID match before the shared policy route applies the authorized ID.
grep -Fq '($var(side) == "internal-outbound" || $fU == $var(managed_caller_id))' <<< "$carrier_cfg"
grep -Fq '$var(managed_extension_id) = $hdr(X-Core-Extension);' <<< "$carrier_cfg"
grep -Fq 'route(MANAGED_EXTENSION);' <<< "$carrier_cfg"
grep -Fq 'reason=$var(managed_handoff_reason)' <<< "$carrier_cfg"
grep -Fq 'reason=provider_not_eligible' <<< "$carrier_cfg"
grep -Fq 'egress_prefix' <<< "$carrier_cfg"
grep -Fq '$rU = $var(managed_egress_prefix) + "*" + $rU;' <<< "$carrier_cfg"
grep -Fq 'reason=$var(managed_disabled_reason)' <<< "$carrier_cfg"
grep -Fq 'Extension Outbound Disabled' <<< "$carrier_cfg"
grep -Fq 'extension_destination_restricted' <<< "$internal_cfg"
grep -Fq 'Extension Destination Not Authorized' <<< "$internal_cfg"
grep -Fq 'private_bye_response' <<< "$internal_cfg"
grep -Fq 'private_bye_transaction_failure' <<< "$internal_cfg"
grep -Fq 'kamailio_event=outbound_attempt component=private_sipcore' <<< "$internal_cfg"
grep -Fq 'kamailio_event=outbound_result component=private_sipcore' <<< "$internal_cfg"
grep -Fq 'kamailio_event=registration_result component=kamailio' <<< "$internal_cfg"
grep -Fq 'kamailio_event=rtpengine_codec_policy' <<< "$internal_cfg"
grep -Fq 'codec_flags_by_provider' <<< "$carrier_cfg"
grep -Fq '$dlg_var(managed_codec_flags)' <<< "$carrier_cfg"
grep -Fq 'rtpengine_manage("$var(media_flags)")' <<< "$internal_cfg"
grep -Fq '$dlg_var(outbound_quota_key) = $var(outbound_quota_key);' <<< "$carrier_cfg"
grep -Fq '"$var(outbound_quota_key)"' <<< "$carrier_cfg"
! grep -Fq 'FLOWROUTE_TECH_PREFIX' "$render"
! grep -Fq 'Flowroute Tech Prefix Unavailable' "$render"
! grep -Fq 'flowroute-nanp-7101' "$render"
! grep -Fq 'asterisk.sipCore.outboundNANP' "$render"
grep -Fq 'egress_prefix' "$repo_root/AVoIP/image/flowroute-sms/web/admin.js"
grep -Fq 'Preferred upstream codec order' "$repo_root/AVoIP/image/flowroute-sms/web/admin.js"
grep -Fq 'DID-specific codec order override' "$repo_root/AVoIP/image/flowroute-sms/web/admin.js"

printf '%s\n' 'PASS: Admin outbound identity is derived from the locked Asterisk extension context'
printf '%s\n' 'PASS: Kamailio looks up the trusted extension and applies the policy caller ID'
printf '%s\n' 'PASS: authenticated site handoffs do not reject a rewritten SIP From user'
printf '%s\n' 'PASS: outbound authorization and registration events are correlated into Homer'
printf '%s\n' 'PASS: Asterisk trusts the selected site Kamailio CA without disabling TLS verification'
printf '%s\n' 'PASS: legacy static Flowroute prefixes and egress allowlists are absent'
