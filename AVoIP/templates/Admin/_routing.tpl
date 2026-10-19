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
    route[MANAGED_DID] {
      if (!is_method("INVITE") || has_totag()) return;
      if (!($rU =~ "^\\+?[1-9][0-9]{7,14}$")) return;
      $var(managed_number) = $(rU{re.subst,/^\+//});
      if ($var(managed_json) == $null) return;
      $var(managed_path) = "dids." + $var(managed_number);
      if (!jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)") || $var(managed_route) == $null) {
        if ($var(managed_provider) != "" && $var(managed_provider) != "flowroute") {
          sl_send_reply("404", "DID Not Configured"); exit;
        }
        return;
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
      remove_hf("X-Core-Original-DID"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Provider");
      append_hf("X-Core-Provider: $var(managed_provider)\r\n");
      append_hf("X-Core-Original-DID: +$var(managed_number)\r\n");
      $ru = "sips:" + $var(managed_number) + "@" + $var(managed_host);
      $du = "sip:" + $var(managed_host) + ":" + $var(managed_port) + ";transport=tls";
      dlg_manage(); $dlg_var(managed_target) = $var(managed_host);
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
    route[MANAGED_EXTENSION] {
      if (!is_method("INVITE") || has_totag() || !($fU =~ "^[0-9]{2,12}$")) return;
      if (!($rU =~ "^\\+1[2-9][0-9]{2}[2-9][0-9]{6}$") || $rU =~ "^\\+1900" || $rU =~ "^\\+1[2-9][0-9]{2}976[0-9]{4}$") return;
      if ($var(managed_json) == $null) return;
      $var(managed_path) = "extensions." + $fU;
      if (!jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)") || $var(managed_route) == $null) return;
      jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) { sl_send_reply("503", "Routing Snapshot Expired"); exit; }
      if (t_check_trans()) exit;
      jansson_get("host", "$var(managed_route)", "$var(managed_host)");
      jansson_get("port", "$var(managed_route)", "$var(managed_port)");
      jansson_get("site", "$var(managed_route)", "$var(managed_site)");
      jansson_get("caller_id", "$var(managed_route)", "$var(managed_caller_id)");
      remove_hf("Route"); remove_hf("P-Asserted-Identity"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Original-DID");
      append_hf("X-Core-Extension: $fU\r\n");
      $fU = $var(managed_caller_id);
      append_hf("P-Asserted-Identity: <sip:$var(managed_caller_id)@{{ include "avoip.sip.siteHost" . }}>\r\n");
      $ru = "sips:" + $rU + "@" + $var(managed_host);
      $du = "sip:" + $var(managed_host) + ":" + $var(managed_port) + ";transport=tls";
      {{ if eq .Values.kamailio.role "private-sbc" }}
      record_route();
      {{ end }}
      dlg_manage(); $dlg_var(managed_outbound) = "yes"; $dlg_var(managed_target) = $var(managed_host);
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
      if ($var(managed_json) == $null) return;
      jansson_array_size("providers", "$var(managed_json)", "$var(managed_count)");
      $var(managed_i) = 0;
      while ($var(managed_i) < $var(managed_count)) {
        jansson_get("providers[$var(managed_i)].host", "$var(managed_json)", "$var(managed_host)");
        if ($rd == $var(managed_host)) {
          jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) { sl_send_reply("503", "Routing Snapshot Expired"); exit; }
          jansson_get("providers[$var(managed_i)].caller_ids", "$var(managed_json)", "$var(managed_ids)");
          $var(managed_match) = "," + $fU + ",";
          if (!in_list("$fU", "$var(managed_ids)", ",")) { sl_send_reply("403", "Caller ID Not Verified"); exit; }
          $var(managed_egress) = 1;
          return;
        }
        $var(managed_i) = $var(managed_i) + 1;
      }
    }
    route[MANAGED_HANDOFF] {
      # Called only inside the existing verified inter-site SAN/CIDR branch.
      if (!is_method("INVITE") || has_totag()) return;
      if ($var(managed_json) == $null) return;
      if ($hdr(X-Core-Extension) =~ "^[0-9]{2,12}$") {
        $var(managed_path) = "extensions." + $hdr(X-Core-Extension);
        if (jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)")) {
          jansson_get("site", "$var(managed_route)", "$var(managed_site)");
          jansson_get("caller_id", "$var(managed_route)", "$var(managed_caller_id)");
          if (($var(managed_site) == "{{ .Values.region }}" || $var(side) == "internal-outbound") && $fU == $var(managed_caller_id)) {
            $fU = $hdr(X-Core-Extension);
            route(MANAGED_EXTENSION);
          }
        }
        sl_send_reply("403", "Managed Extension Not Authorized"); exit;
      }
      if ($rU =~ "^\\+?[1-9][0-9]{7,14}$" && $hdr(X-Core-Original-DID) != $null) {
        $var(managed_number) = $(rU{re.subst,/^\+//});
        $var(managed_path) = "dids." + $var(managed_number);
        if (jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)")) {
          jansson_get("site", "$var(managed_route)", "$var(managed_site)");
          if ($var(managed_site) == "{{ .Values.region }}") {
            $var(managed_provider) = $hdr(X-Core-Provider);
            route(MANAGED_DID);
          }
        }
        sl_send_reply("403", "Managed DID Not Authorized"); exit;
      }
    }
{{- end -}}
