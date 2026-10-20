{{- define "avoip.admin.routing.modules" -}}
    loadmodule "htable.so"
    loadmodule "http_client.so"
    loadmodule "rtimer.so"
    loadmodule "jansson.so"
    loadmodule "ipops.so"
    modparam("htable", "htable", "managed=>size=4;autoexpire=0;")
    modparam("http_client", "timeout_mode", 2)
    modparam("http_client", "connection_timeout", 1000)
    modparam("http_client", "query_maxdatasize", 1048576)
    modparam("http_client", "httpredirect", 0)
    modparam("http_client", "query_result", 0)
    modparam("rtimer", "timer", "name=admin_pull;interval=5;mode=1;")
    modparam("rtimer", "exec", "timer=admin_pull;route=ADMIN_PULL")
{{- end -}}
{{- define "avoip.admin.routing.routes" -}}
    # Only this dedicated timer performs HTTP. SIP workers read an atomic
    # shared-memory snapshot; new dialogs never wait for the admin API.
    route[ADMIN_PULL] {
      $var(admin_headers) = "Authorization: Bearer " + $env(AVOIP_ROUTING_TOKEN);
      http_client_query("http://{{ include "avoip.fullname" . }}-admin.{{ $.Release.Namespace }}.svc.{{ .Values.cluster.domain }}:8081/routing/snapshot", "", "$var(admin_headers)", "$var(admin_response)");
      if ($rc == 200 && jansson_get("site", "$var(admin_response)", "$var(admin_site)") &&
          $var(admin_site) == "{{ .Values.region }}" &&
          jansson_get("version", "$var(admin_response)", "$var(admin_version)")) {
        if (jansson_get("valid_until", "$var(admin_response)", "$var(admin_deadline)")) {
          $sht(managed=>valid_until) = $var(admin_deadline);
          $sht(managed=>snapshot) = $var(admin_response);
          $sht(managed=>refreshed) = $Ts;
        }
      }
    }
    route[MANAGED_SOURCE] {
      $var(managed_provider) = "";
      if ($var(managed_json) == $null) return;
      jansson_array_size("providers", "$var(managed_json)", "$var(managed_count)");
      $var(managed_i) = 0;
      while ($var(managed_i) < $var(managed_count)) {
        jansson_get("providers[$var(managed_i)].cidrs", "$var(managed_json)", "$var(managed_cidrs)");
        if ($var(managed_cidrs) != "" && is_in_subnet("$si", "$var(managed_cidrs)")) {
          jansson_get("providers[$var(managed_i)].id", "$var(managed_json)", "$var(managed_provider)");
          return;
        }
        $var(managed_i) = $var(managed_i) + 1;
      }
    }
    {{- if ne .Values.kamailio.role "private-sbc" }}
    route[MANAGED_DID] {
      if (!is_method("INVITE") || has_totag()) return;
      # Flowroute uses a rendezvous Request-URI; the called DID is in To.
      # A verified inter-site handoff uses the canonical DID in Request-URI.
      if ($var(side) == "inter-site") $var(managed_did_user) = $rU;
      else $var(managed_did_user) = $tU;
      if (!($var(managed_did_user) =~ "^\\+?[1-9][0-9]{7,14}$")) return;
      $var(managed_number) = $(var(managed_did_user){re.subst,/^\+//});
      if ($var(managed_json) == $null) {
        sl_send_reply("503", "Routing Snapshot Unavailable"); exit;
      }
      $var(managed_path) = "dids." + $var(managed_number);
      if (!jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)") || $var(managed_route) == $null) {
        sl_send_reply("404", "DID Not Configured"); exit;
      }
      jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) { sl_send_reply("503", "Routing Snapshot Expired"); exit; }
      if ($var(managed_provider) == "") route(MANAGED_SOURCE);
      jansson_get("providers", "$var(managed_route)", "$var(managed_allowed)");
      $var(managed_match) = "," + $var(managed_provider) + ",";
      if ($var(managed_provider) == "" || !in_list("$var(managed_provider)", "$var(managed_allowed)", ",")) {
        sl_send_reply("403", "DID Provider Not Authorized"); exit;
      }
      if (t_check_trans()) exit;
      jansson_get("host", "$var(managed_route)", "$var(managed_host)");
      jansson_get("port", "$var(managed_route)", "$var(managed_port)");
      jansson_get("site", "$var(managed_route)", "$var(managed_site)");
      jansson_get("codec_flags_by_provider", "$var(managed_route)", "$var(managed_provider_codec_flags)");
      jansson_get("$var(managed_provider)", "$var(managed_provider_codec_flags)", "$var(managed_codec_flags)");
      remove_hf("X-Core-Original-DID"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Provider");
      append_hf("X-Core-Provider: $var(managed_provider)\r\n");
      append_hf("X-Core-Original-DID: +$var(managed_number)\r\n");
      $ru = "sips:" + $var(managed_number) + "@" + $var(managed_host);
      $du = "sip:" + $var(managed_host) + ":" + $var(managed_port) + ";transport=tls";
      dlg_manage(); $dlg_var(managed_target) = $var(managed_host);
      if ($var(managed_codec_flags) != $null && $var(managed_codec_flags) != "") {
        $dlg_var(managed_codec_flags) = $var(managed_codec_flags);
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=selected direction=inbound did=+$var(managed_number) provider=$var(managed_provider) flags=$var(managed_codec_flags) call_id=$ci");
        {{- end }}
      }
      route(RR_CARRIER_TO_BACKEND);
      {{ if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) }}
      route(MEDIA_INITIAL);
      {{ end }}
      $xavp(tls=>server_name) = $var(managed_host);
      set_send_socket_name("private_tls");
      {{ if .Values.kamailio.interSite.peers }}
      if ($var(managed_site) != "{{ .Values.region }}") {
        $var(interSitePeer) = $var(managed_site);
        $dlg_var(interSitePeer) = $var(managed_site); $dlg_var(interSiteDirection) = "origin";
        route(INTERSITE_TO_PEER);
      }
      {{ end }}
      route(RELAY); exit;
    }
    {{- end }}
    route[MANAGED_EXTENSION] {
      # managed_extension_id is populated only by the Asterisk-only TLS
      # listener from its dialplan-stamped identity header, or by a verified
      # inter-site handoff below. SIP From is caller ID, not extension identity.
      $var(managed_egress_prefix) = "";
      if (!is_method("INVITE") || has_totag() || !($var(managed_extension_id) =~ "^[0-9]{2,12}$")) return;
      if (!($rU =~ "^\\+1[2-9][0-9]{2}[2-9][0-9]{6}$") || $rU =~ "^\\+1900" || $rU =~ "^\\+1[2-9][0-9]{2}976[0-9]{4}$") {
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=destination_not_allowed extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm destination_class=restricted_or_invalid");
        {{- end }}
        return;
      }
      if ($var(managed_json) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_missing call_id=$ci extension=$var(managed_extension_id) destination_format=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=snapshot_unavailable extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm");
        {{- end }}
        return;
      }
      $var(managed_path) = "extensions." + $var(managed_extension_id);
      if (!jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)") || $var(managed_route) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_extension_missing call_id=$ci extension=$var(managed_extension_id) destination_format=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=extension_missing extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm");
        {{- end }}
        return;
      }
      jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_expired call_id=$ci extension=$var(managed_extension_id) destination_format=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=snapshot_expired extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm");
        {{- end }}
        sl_send_reply("503", "Routing Snapshot Expired"); exit;
      }
      $var(managed_disabled_reason) = "";
      jansson_get("disabled_reason", "$var(managed_route)", "$var(managed_disabled_reason)");
      if ($var(managed_disabled_reason) != $null && $var(managed_disabled_reason) != "") {
        xlog("L_WARN", "AVOIP_POLICY reject=$var(managed_disabled_reason) call_id=$ci extension=$var(managed_extension_id)\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=$var(managed_disabled_reason) extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm destination_class=nanp");
        {{- end }}
        sl_send_reply("403", "Extension Outbound Disabled"); exit;
      }
      jansson_get("allowed_destinations", "$var(managed_route)", "$var(managed_allowed_destinations)");
      jansson_get("blocked_destinations", "$var(managed_route)", "$var(managed_blocked_destinations)");
      if (($var(managed_allowed_destinations) != $null && $var(managed_allowed_destinations) != ",," &&
           !in_list("$rU", "$var(managed_allowed_destinations)", ",")) ||
          ($var(managed_blocked_destinations) != $null && $var(managed_blocked_destinations) != ",," &&
           in_list("$rU", "$var(managed_blocked_destinations)", ","))) {
        xlog("L_WARN", "AVOIP_POLICY reject=extension_destination_restricted call_id=$ci extension=$var(managed_extension_id) site={{ .Values.region }} destination_class=restricted\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=extension_destination_restricted extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm destination_class=restricted");
        {{- end }}
        sl_send_reply("403", "Extension Destination Not Authorized"); exit;
      }
      if (t_check_trans()) exit;
      jansson_get("host", "$var(managed_route)", "$var(managed_host)");
      jansson_get("port", "$var(managed_route)", "$var(managed_port)");
      jansson_get("site", "$var(managed_route)", "$var(managed_site)");
      jansson_get("caller_id", "$var(managed_route)", "$var(managed_caller_id)");
      jansson_get("egress_prefix", "$var(managed_route)", "$var(managed_egress_prefix)");
      jansson_get("codec_flags", "$var(managed_route)", "$var(managed_codec_flags)");
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=authorized extension=$var(managed_extension_id) site=$var(managed_site) provider=$var(managed_host) call_id=$ci method=$rm destination_class=nanp");
      {{- end }}
      remove_hf("Route"); remove_hf("P-Asserted-Identity"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Original-DID");
      append_hf("X-Core-Extension: $var(managed_extension_id)\r\n");
      $fU = $var(managed_caller_id);
      append_hf("P-Asserted-Identity: <sip:$var(managed_caller_id)@{{ include "avoip.sip.siteHost" . }}>\r\n");
      if ($var(managed_site) == "{{ .Values.region }}" && $var(managed_egress_prefix) != $null && $var(managed_egress_prefix) != "") {
        $rU = $var(managed_egress_prefix) + "*" + $(rU{re.subst,/^\+//});
      }
      $ru = "sips:" + $rU + "@" + $var(managed_host);
      $du = "sip:" + $var(managed_host) + ":" + $var(managed_port) + ";transport=tls";
      {{ if and (eq .Values.kamailio.role "private-sbc") .Values.asterisk.sipCore.enabled }}
      # Asterisk's dedicated SIP Core listener is the return path for its
      # managed outbound dialog. Generic record_route() can select the
      # carrier-facing send socket after the upstream route is chosen, causing
      # Asterisk's BYE to hit the public listener and be rejected as an
      # untrusted source. Pin this dialog's route set to the private return
      # Service/listener, independent of the upstream send socket.
      if ($var(side) == "sipcore") {
        record_route_preset("{{ include "avoip.sip.sipCoreReturnHost" (dict "root" $) }}:{{ .Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
      } else {
        record_route();
      }
      {{ else if eq .Values.kamailio.role "private-sbc" }}
      record_route();
      {{ end }}
      dlg_manage(); $dlg_var(managed_outbound) = "yes"; $dlg_var(managed_target) = $var(managed_host);
      if ($var(managed_codec_flags) != $null && $var(managed_codec_flags) != "") {
        $dlg_var(managed_codec_flags) = $var(managed_codec_flags);
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=selected direction=outbound extension=$var(managed_extension_id) provider=$var(managed_host) flags=$var(managed_codec_flags) call_id=$ci");
        {{- end }}
      }
      $xavp(tls=>server_name) = $var(managed_host); set_send_socket_name("private_tls");
      {{ if eq .Values.kamailio.role "private-sbc" }}
      $ru = "sips:" + $rU + "@{{ include "avoip.sip.siteHost" . }}";
      route(PRIVATE_TO_CARRIER_GATEWAY);
      route(PRIVATE_RELAY); exit;
      {{ else }}
      route(RR_CARRIER_TO_BACKEND);
      {{ if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) }}
      route(MEDIA_INITIAL);
      {{ end }}
      {{ if .Values.kamailio.interSite.peers }}
      if ($var(managed_site) != "{{ .Values.region }}") {
        $var(interSitePeer) = $var(managed_site);
        $dlg_var(interSitePeer) = $var(managed_site); $dlg_var(interSiteDirection) = "origin";
        route(INTERSITE_TO_PEER);
      }
      {{ end }}
      route(RELAY); exit;
      {{ end }}
    }
    route[MANAGED_EGRESS] {
      $var(managed_egress) = 0;
      $var(managed_egress_prefix) = "";
      if ($var(managed_json) == $null) return;
      jansson_array_size("providers", "$var(managed_json)", "$var(managed_count)");
      $var(managed_i) = 0;
      while ($var(managed_i) < $var(managed_count)) {
        jansson_get("providers[$var(managed_i)].host", "$var(managed_json)", "$var(managed_host)");
        if ($rd == $var(managed_host)) {
          jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) { sl_send_reply("503", "Routing Snapshot Expired"); exit; }
          jansson_get("providers[$var(managed_i)].caller_ids", "$var(managed_json)", "$var(managed_ids)");
          jansson_get("providers[$var(managed_i)].egress_prefix", "$var(managed_json)", "$var(managed_egress_prefix)");
          $var(managed_match) = "," + $fU + ",";
          if (!in_list("$fU", "$var(managed_ids)", ",")) {
            xlog("L_WARN", "AVOIP_POLICY reject=caller_id_not_verified call_id=$ci extension=$hdr(X-Core-Extension) provider_host=$var(managed_host)\n");
            {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
            hlog("$ci", "kamailio_event=authorization_result policy=provider_caller_id decision=deny reason=caller_id_not_verified extension=$hdr(X-Core-Extension) provider=$var(managed_host) site={{ .Values.region }} call_id=$ci");
            {{- end }}
            sl_send_reply("403", "Caller ID Not Verified"); exit;
          }
          $var(managed_egress) = 1;
          return;
        }
        $var(managed_i) = $var(managed_i) + 1;
      }
    }
    route[MANAGED_HANDOFF] {
      # Called only inside the existing verified inter-site SAN/CIDR branch.
      if (!is_method("INVITE") || has_totag()) return;
      $var(managed_handoff) = 0;
      if ($var(managed_json) == $null) {
        if ($hdr(X-Core-Original-DID) != $null || $hdr(X-Core-Extension) != $null) {
          xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=snapshot_unavailable extension=$hdr(X-Core-Extension) site={{ .Values.region }} peer_side=$var(side) call_id=$ci method=$rm\n");
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=authorization_result policy=managed_handoff decision=deny reason=snapshot_unavailable extension=$hdr(X-Core-Extension) call_id=$ci site={{ .Values.region }} method=$rm");
          {{- end }}
          sl_send_reply("503", "Routing Snapshot Unavailable"); exit;
        }
        return;
      }
      if ($hdr(X-Core-Extension) =~ "^[0-9]{2,12}$") {
        $var(managed_extension_id) = $hdr(X-Core-Extension);
        $var(managed_handoff_reason) = "extension_not_authorized";
        $var(managed_path) = "extensions." + $var(managed_extension_id);
        if (jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)")) {
          jansson_get("site", "$var(managed_route)", "$var(managed_site)");
          jansson_get("caller_id", "$var(managed_route)", "$var(managed_caller_id)");
          # The local Kamailio peer is authenticated by mTLS and has already
          # selected this extension's caller ID from the same policy snapshot.
          # Its SIP From can be rewritten by intermediate routing, so do not
          # use that mutable value as the extension identity check. For a
          # remote-site handoff, retain the explicit caller-ID match.
          if (($var(managed_site) == "{{ .Values.region }}" || $var(side) == "internal-outbound") &&
              ($var(side) == "internal-outbound" || $fU == $var(managed_caller_id))) {
            $var(managed_handoff_reason) = "extension_policy_rejected";
            $fU = $hdr(X-Core-Extension);
            xlog("L_INFO", "AVOIP_POLICY managed_handoff decision=authenticated extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm\n");
            {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
            hlog("$ci", "kamailio_event=managed_handoff decision=authenticated extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm");
            {{- end }}
            route(MANAGED_EXTENSION);
          } else if ($var(managed_site) != "{{ .Values.region }}" && $var(side) != "internal-outbound") {
            $var(managed_handoff_reason) = "site_mismatch";
            xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=site_mismatch extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm\n");
          } else {
            $var(managed_handoff_reason) = "caller_id_mismatch";
            xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=caller_id_mismatch extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm\n");
          }
        } else {
          $var(managed_handoff_reason) = "extension_missing";
          xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=extension_missing extension=$hdr(X-Core-Extension) site={{ .Values.region }} peer_side=$var(side) call_id=$ci method=$rm\n");
        }
        xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=$var(managed_handoff_reason) extension=$hdr(X-Core-Extension) site={{ .Values.region }} peer_side=$var(side) call_id=$ci method=$rm\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=managed_handoff decision=deny reason=$var(managed_handoff_reason) extension=$hdr(X-Core-Extension) site={{ .Values.region }} peer_side=$var(side) call_id=$ci method=$rm");
        {{- end }}
        sl_send_reply("403", "Managed Extension Not Authorized"); exit;
      }
      if ($hdr(X-Core-Original-DID) != $null) {
        if (!($rU =~ "^\\+?[1-9][0-9]{7,14}$")) {
          sl_send_reply("403", "Managed DID Mismatch"); exit;
        }
        $var(managed_number) = $(rU{re.subst,/^\+//});
        $var(expected_did) = "+" + $var(managed_number);
        if ($hdr(X-Core-Original-DID) != $var(expected_did)) {
          sl_send_reply("403", "Managed DID Mismatch"); exit;
        }
        $var(managed_path) = "dids." + $var(managed_number);
        if (jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)")) {
          jansson_get("site", "$var(managed_route)", "$var(managed_site)");
          if ($var(managed_site) == "{{ .Values.region }}") {
            $var(managed_provider) = $hdr(X-Core-Provider);
            jansson_get("providers", "$var(managed_route)", "$var(managed_allowed)");
            if ($var(managed_provider) == "" || !in_list("$var(managed_provider)", "$var(managed_allowed)", ",")) {
              sl_send_reply("403", "DID Provider Not Authorized"); exit;
            }
            $var(managed_handoff) = 1;
            return;
          }
        }
        sl_send_reply("403", "Managed DID Not Authorized"); exit;
      }
      if ($hdr(X-Core-Extension) != $null) {
        sl_send_reply("403", "Managed Extension Not Authorized"); exit;
      }
    }
{{- end -}}
