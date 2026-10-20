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
      if (!($var(managed_did_user) =~ "^\\+1[0-9]{10}$")) return;
      $var(managed_number) = $var(managed_did_user);
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
      jansson_get("limit_profile_id", "$var(managed_route)", "$var(inbound_limit_profile)");
      jansson_get("calls_per_minute", "$var(managed_route)", "$var(inbound_calls_per_minute)");
      jansson_get("concurrent_calls", "$var(managed_route)", "$var(inbound_concurrent_calls)");
      jansson_get("max_duration_seconds", "$var(managed_route)", "$var(inbound_max_duration)");
      if ($var(inbound_limit_profile) == "legacy-default") {
        dlg_manage();
      } else {
        $var(inbound_rate_valid) = 0;
        $var(inbound_concurrent_valid) = 0;
        $var(inbound_duration_valid) = 0;
        if ($var(inbound_calls_per_minute) =~ "^[1-9][0-9]*$") $var(inbound_rate_valid) = 1;
        if ($var(inbound_concurrent_calls) =~ "^[1-9][0-9]*$") $var(inbound_concurrent_valid) = 1;
        if ($var(inbound_max_duration) =~ "^[1-9][0-9]*$") $var(inbound_duration_valid) = 1;
        if ($var(inbound_limit_profile) == $null || $var(inbound_rate_valid) != 1 || $var(inbound_concurrent_valid) != 1 || $var(inbound_duration_valid) != 1 || $var(inbound_max_duration) < 60) {
          xlog("L_ERR", "AVOIP inbound quota request invalid callid=$ci rate_valid=$var(inbound_rate_valid) concurrent_valid=$var(inbound_concurrent_valid) duration_valid=$var(inbound_duration_valid)\n");
          sl_send_reply("503", "Inbound Limits Unavailable"); exit;
        }
        $var(inbound_limit_key) = "avoip:limit:" + $var(inbound_limit_profile);
        $var(inbound_limit_script) = "local k=KEYS[1];local payload=ARGV[1] or '';local p1=string.find(payload,'|',1,true);local p2=p1 and string.find(payload,'|',p1+1,true);local p3=p2 and string.find(payload,'|',p2+1,true);if not p1 or not p2 or not p3 then return -3 end;local rate=tonumber(string.sub(payload,1,p1-1));local concurrent=tonumber(string.sub(payload,p1+1,p2-1));local duration=tonumber(string.sub(payload,p2+1,p3-1));local id=string.sub(payload,p3+1);if id=='' or not rate or not concurrent or not duration or rate<1 or concurrent<1 or duration<60 then return -3 end;local now=tonumber(redis.call('TIME')[1]);redis.call('ZREMRANGEBYSCORE',k,0,now);redis.call('ZREMRANGEBYSCORE',k,-now,0);if redis.call('ZSCORE',k,'call:'..id) then return 1 end;if redis.call('ZCOUNT',k,now,'+inf')>=concurrent then return -2 end;if redis.call('ZCOUNT',k,'-inf',-now-1)>=rate or redis.call('ZSCORE',k,'rate:'..id) then return -1 end;redis.call('ZADD',k,now+duration,'call:'..id);redis.call('ZADD',k,-(now+60),'rate:'..id);redis.call('EXPIRE',k,duration);return 1";
        $var(inbound_limit_payload) = "$var(inbound_calls_per_minute)|$var(inbound_concurrent_calls)|$var(inbound_max_duration)|$ci";
        if (!redis_cmd("topos", "EVAL %s 1 %s %s", "$var(inbound_limit_script)", "$var(inbound_limit_key)", "$var(inbound_limit_payload)", "inbound_limit")) {
          sl_send_reply("503", "Inbound Limits Unavailable"); exit;
        }
        if ($redis(inbound_limit=>type) != $redisd(rpl_int)) {
          xlog("L_ERR", "AVOIP inbound quota response invalid callid=$ci\n");
          sl_send_reply("503", "Inbound Limits Unavailable"); exit;
        }
        if ($redis(inbound_limit=>value) == -3) {
          xlog("L_ERR", "AVOIP inbound quota payload invalid callid=$ci\n");
          sl_send_reply("503", "Inbound Limits Unavailable"); exit;
        }
        if ($redis(inbound_limit=>value) != 1) {
          sl_send_reply("486", "Inbound Limit Reached"); exit;
        }
        $dlg_ctx(timeout_route) = "INBOUND_DIALOG_TIMEOUT";
        dlg_manage();
        dlg_set_property("timeout-noreset");
        $dlg_var(inbound_limit_key) = $var(inbound_limit_key);
        $dlg_var(inbound_limit_callid) = $ci;
        if (!dlg_set_timeout("$var(inbound_max_duration)")) {
          route(INBOUND_LIMIT_RELEASE);
          sl_send_reply("503", "Inbound Limit Setup Failed"); exit;
        }
      }
      jansson_get("host", "$var(managed_route)", "$var(managed_host)");
      jansson_get("port", "$var(managed_route)", "$var(managed_port)");
      jansson_get("site", "$var(managed_route)", "$var(managed_site)");
      jansson_get("codec_flags_by_provider", "$var(managed_route)", "$var(managed_provider_codec_flags)");
      jansson_get("$var(managed_provider)", "$var(managed_provider_codec_flags)", "$var(managed_codec_flags)");
      remove_hf("X-Core-Original-DID"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Provider");
      append_hf("X-Core-Provider: $var(managed_provider)\r\n");
      append_hf("X-Core-Original-DID: $var(managed_number)\r\n");
      $ru = "sips:" + $var(managed_number) + "@" + $var(managed_host);
      $du = "sip:" + $var(managed_host) + ":" + $var(managed_port) + ";transport=tls";
      $dlg_var(managed_target) = $var(managed_host);
      if ($var(managed_codec_flags) != $null && $var(managed_codec_flags) != "") {
        $dlg_var(managed_codec_flags) = $var(managed_codec_flags);
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=selected direction=inbound did=$var(managed_number) provider=$var(managed_provider) flags=$var(managed_codec_flags) call_id=$ci");
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
    route[INBOUND_LIMIT_RELEASE] {
      $var(inbound_limit_key) = $dlg_var(inbound_limit_key);
      $var(inbound_limit_callid) = $dlg_var(inbound_limit_callid);
      if ($var(inbound_limit_key) == $null || $var(inbound_limit_callid) == $null) return;
      $var(inbound_release_script) = "redis.call('ZREM',KEYS[1],'call:'..ARGV[1]);return 1";
      if (!redis_cmd("topos", "EVAL %s 1 %s %s", "$var(inbound_release_script)", "$var(inbound_limit_key)", "$var(inbound_limit_callid)", "inbound_release")) {
        xlog("L_ERR", "Inbound call limit release failed callid=$ci\n");
      }
      $dlg_var(inbound_limit_key) = "";
      $dlg_var(inbound_limit_callid) = "";
      return;
    }
    route[INBOUND_DIALOG_TIMEOUT] {
      route(INBOUND_LIMIT_RELEASE);
      dlg_bye("all");
      return;
    }
    {{- end }}
    route[MANAGED_EXTENSION] {
      # managed_extension_id is populated only by the Asterisk-only TLS
      # listener from its dialplan-stamped identity header, or by a verified
      # inter-site handoff below. SIP From is caller ID, not extension identity.
      if (!is_method("INVITE") || has_totag() || !($var(managed_extension_id) =~ "^[0-9]{2,12}$")) return;
      xlog("L_INFO", "AVOIP_POLICY managed_extension decision=evaluate extension=$var(managed_extension_id) side=$var(side) request_user=$rU from_user=$fU call_id=$ci method=$rm\n");
      if (!($rU =~ "^\\+1[0-9]{10}$")) {
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=destination_not_allowed extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm destination_class=restricted_or_invalid");
        {{- end }}
        return;
      }
      if ($var(managed_json) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_missing call_id=$ci extension=$var(managed_extension_id) destination_format=plus1-10\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=snapshot_unavailable extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm");
        {{- end }}
        return;
      }
      $var(managed_path) = "extensions." + $var(managed_extension_id);
      if (!jansson_get("$var(managed_path)", "$var(managed_json)", "$var(managed_route)") || $var(managed_route) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_extension_missing call_id=$ci extension=$var(managed_extension_id) destination_format=plus1-10\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=extension_missing extension=$var(managed_extension_id) site={{ .Values.region }} call_id=$ci method=$rm");
        {{- end }}
        return;
      }
      jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_expired call_id=$ci extension=$var(managed_extension_id) destination_format=plus1-10\n");
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
      if (t_check_trans()) exit;
      jansson_get("host", "$var(managed_route)", "$var(managed_host)");
      jansson_get("port", "$var(managed_route)", "$var(managed_port)");
      jansson_get("site", "$var(managed_route)", "$var(managed_site)");
      jansson_get("caller_id", "$var(managed_route)", "$var(managed_caller_id)");
      jansson_get("codec_flags", "$var(managed_route)", "$var(managed_codec_flags)");
      jansson_get("limit_profile_id", "$var(managed_route)", "$var(managed_limit_profile_id)");
      jansson_get("limit_scope", "$var(managed_route)", "$var(managed_limit_scope)");
      jansson_get("calls_per_minute", "$var(managed_route)", "$var(managed_calls_per_minute)");
      jansson_get("concurrent_calls", "$var(managed_route)", "$var(managed_concurrent_calls)");
      jansson_get("max_duration_seconds", "$var(managed_route)", "$var(managed_max_duration_seconds)");
      xlog("L_INFO", "AVOIP_POLICY managed_extension decision=authorized extension=$var(managed_extension_id) site=$var(managed_site) provider_host=$var(managed_host) request_user=$rU call_id=$ci method=$rm\n");
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=authorized extension=$var(managed_extension_id) site=$var(managed_site) provider=$var(managed_host) call_id=$ci method=$rm destination_class=nanp");
      {{- end }}
      remove_hf("Route"); remove_hf("P-Asserted-Identity"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Original-DID");
      append_hf("X-Core-Extension: $var(managed_extension_id)\r\n");
      $fU = $var(managed_caller_id);
      append_hf("P-Asserted-Identity: <sip:$var(managed_caller_id)@{{ include "avoip.sip.siteHost" . }}>\r\n");
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
      if ($var(managed_json) == $null) return;
      jansson_array_size("providers", "$var(managed_json)", "$var(managed_count)");
      $var(managed_i) = 0;
      while ($var(managed_i) < $var(managed_count)) {
        jansson_get("providers[$var(managed_i)].host", "$var(managed_json)", "$var(managed_host)");
        if ($rd == $var(managed_host)) {
          jansson_get("valid_until", "$var(managed_json)", "$var(managed_deadline)");
      if ($Ts > $var(managed_deadline)) { sl_send_reply("503", "Routing Snapshot Expired"); exit; }
          jansson_get("providers[$var(managed_i)].caller_ids", "$var(managed_json)", "$var(managed_ids)");
          $var(managed_caller_id) = $fU;
          if (!in_list("$var(managed_caller_id)", "$var(managed_ids)", ",")) {
            xlog("L_WARN", "AVOIP_POLICY reject=caller_id_not_verified call_id=$ci extension=$hdr(X-Core-Extension) provider_host=$var(managed_host)\n");
            {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
            hlog("$ci", "kamailio_event=authorization_result policy=provider_caller_id decision=deny reason=caller_id_not_verified extension=$hdr(X-Core-Extension) provider=$var(managed_host) site={{ .Values.region }} call_id=$ci");
            {{- end }}
            sl_send_reply("403", "Caller ID Not Verified"); exit;
          }
          $fU = $var(managed_caller_id);
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
      xlog("L_INFO", "AVOIP_POLICY managed_handoff decision=evaluate extension=$hdr(X-Core-Extension) side=$var(side) request_user=$rU from_user=$fU call_id=$ci method=$rm\n");
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
            xlog("L_INFO", "AVOIP_POLICY managed_handoff decision=dispatch extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm\n");
            route(MANAGED_EXTENSION);
            xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=returned reason=$var(managed_handoff_reason) extension=$hdr(X-Core-Extension) site=$var(managed_site) peer_side=$var(side) call_id=$ci method=$rm\n");
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
        if (!($rU =~ "^\\+1[0-9]{10}$")) {
          sl_send_reply("403", "Managed DID Mismatch"); exit;
        }
        $var(managed_number) = $rU;
        $var(expected_did) = $rU;
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
        xlog("L_WARN", "AVOIP_POLICY managed_handoff decision=deny reason=extension_header_unhandled extension=$hdr(X-Core-Extension) side=$var(side) request_user=$rU from_user=$fU call_id=$ci method=$rm\n");
        sl_send_reply("403", "Managed Extension Not Authorized"); exit;
      }
    }
{{- end -}}
