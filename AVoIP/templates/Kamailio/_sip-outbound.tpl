{{- define "avoip.kamailio.sip.outbound" -}}
    # Carrier-owned, opt-in PSTN egress. The peer was authenticated by the
    # existing site-SNI mTLS branch before this route is entered.
    route[FROM_OUTBOUND_PEER] {
      # Requests returning from FreeSWITCH can be retransmitted through this
      # authenticated peer path. Let TM replay the cached reply before
      # OUTBOUND_RELEASE or RTPEngine teardown runs again.
      if (is_method("BYE") && t_check_trans()) {
        exit;
      }
      if (is_method("CANCEL")) {
        route(OUTBOUND_RELEASE);
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) sl_send_reply("481", "Call Does Not Exist");
        else if ($var(cancel_result) < 0) sl_reply_error();
        exit;
      }
      if (has_totag()) {
        if (is_method("ACK") && !is_present_hf("Route") &&
            $(ru{uri.param,tps}) == "" && t_check_trans()) {
          route(RELAY);
          exit;
        }
        route(IN_DIALOG);
        exit;
      }
      if (is_method("ACK")) {
        if (t_check_trans()) route(RELAY);
        exit;
      }
      if (is_method("OPTIONS")) {
        sl_send_reply("200", "Keepalive");
        exit;
      }
      if (!is_method("INVITE")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
      if ($var(managed_json) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_missing call_id=$ci method=$rm destination_class=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=snapshot_unavailable site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
        {{- end }}
        sl_send_reply("503", "Routing Snapshot Unavailable"); exit;
      }
      route(MANAGED_EGRESS);
      {{- end }}
      {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
      route(MANAGED_HANDOFF);
      {{- end }}

      # New calls require the configured service identity and caller policy.
      {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
      if ($var(managed_egress) != 1) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_egress_unverified call_id=$ci extension=$hdr(X-Core-Extension) method=$rm\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=provider_egress decision=deny reason=provider_not_eligible extension=$hdr(X-Core-Extension) site={{ $.Values.region }} call_id=$ci method=$rm");
        {{- end }}
        sl_send_reply("403", "Managed Egress Not Authorized");
        exit;
      }
      {{- else }}
      xlog("L_WARN", "AVOIP_POLICY reject=admin_routing_required call_id=$ci method=$rm destination_class=nanp\n");
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=admin_routing_required site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
      {{- end }}
      sl_send_reply("503", "Admin Routing Required");
      exit;
      {{- end }}
      if (!($rU =~ "^\\+1[0-9]{10}$")) {
        sl_send_reply("403", "Destination Not Authorized");
        exit;
      }

      # The managed routing snapshot must provide complete, numeric limits.
      # Reject an incomplete record before constructing the Redis Lua payload;
      # otherwise tonumber(nil) can turn a policy error into a SIP 500.
      $var(outbound_concurrent_valid) = 0;
      $var(outbound_rate_valid) = 0;
      $var(outbound_duration_valid) = 0;
      if ($var(managed_concurrent_calls) =~ "^[1-9][0-9]*$") $var(outbound_concurrent_valid) = 1;
      if ($var(managed_calls_per_minute) =~ "^[1-9][0-9]*$") $var(outbound_rate_valid) = 1;
      if ($var(managed_max_duration_seconds) =~ "^[1-9][0-9]*$") $var(outbound_duration_valid) = 1;
      if ($var(outbound_concurrent_valid) != 1 ||
          $var(outbound_rate_valid) != 1 ||
          $var(outbound_duration_valid) != 1) {
        xlog(
          "L_ERR",
          "SIP outbound quota request invalid callid=$ci method=$rm concurrent_valid=$var(outbound_concurrent_valid) rate_valid=$var(outbound_rate_valid) duration_valid=$var(outbound_duration_valid)\n"
        );
        sl_send_reply("503", "Outbound Limits Unavailable");
        exit;
      }

      # Dragonfly executes quota admission atomically across all carrier
      # replicas. A stale call expires after maxDurationSeconds even if a pod
      # disappears before BYE. A failed Redis operation fails closed.
      $var(quota_script) = "local k=KEYS[1];local concurrent_text,rate_text,duration_text,id=string.match(ARGV[1],'^([^|]+)|([^|]+)|([^|]+)|(.+)$');if not concurrent_text or not rate_text or not duration_text or not id then return -3 end;local concurrent=tonumber(concurrent_text);local rate=tonumber(rate_text);local duration=tonumber(duration_text);if not concurrent or not rate or not duration or concurrent<1 or rate<1 or duration<60 then return -3 end;local now=tonumber(redis.call('TIME')[1]);redis.call('ZREMRANGEBYSCORE',k,0,now);redis.call('ZREMRANGEBYSCORE',k,-now,0);if redis.call('ZSCORE',k,'call:'..id) then return 1 end;if redis.call('ZCOUNT',k,now,'+inf')>=concurrent then return -2 end;if redis.call('ZCOUNT',k,'-inf',-now-1)>=rate or redis.call('ZSCORE',k,'rate:'..id) then return -1 end;redis.call('ZADD',k,now+duration,'call:'..id);redis.call('ZADD',k,-(now+60),'rate:'..id);redis.call('EXPIRE',k,duration);return 1";
      $var(quota_payload) = "$var(managed_concurrent_calls)|$var(managed_calls_per_minute)|$var(managed_max_duration_seconds)|$ci";
      if ($var(managed_limit_scope) == "legacy") {
        $var(outbound_quota_key) = "avoip:out:quota:" + $fU;
      } else {
        $var(outbound_quota_key) = "avoip:limit:" + $var(managed_limit_profile_id);
      }
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(quota_script)",
        "$var(outbound_quota_key)",
        "$var(quota_payload)", "outbound_quota"
      )) {
        sl_send_reply("503", "Outbound Quota Unavailable");
        exit;
      }
      if ($redis(outbound_quota=>type) != $redisd(rpl_int)) {
        xlog("L_ERR", "SIP outbound quota response invalid callid=$ci method=$rm\n");
        sl_send_reply("503", "Outbound Limits Unavailable");
        exit;
      }
      if ($redis(outbound_quota=>value) == -3) {
        xlog("L_ERR", "SIP outbound quota payload invalid callid=$ci method=$rm\n");
        sl_send_reply("503", "Outbound Limits Unavailable");
        exit;
      }
      if ($redis(outbound_quota=>value) != 1) {
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        $var(outbound_quota_cause) = "unknown";
        if ($redis(outbound_quota=>value) == -2) $var(outbound_quota_cause) = "concurrency_limit";
        else if ($redis(outbound_quota=>value) == -1) $var(outbound_quota_cause) = "rate_limit";
        hlog(
          "$ci",
          "kamailio_event=call_end call_id=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) site={{ $.Values.region }} gateway=flowroute final_sip_status=486 cause_source=local_policy local_cause=$var(outbound_quota_cause)"
        );
        {{- end }}
        sl_send_reply("486", "Outbound Limit Reached");
        exit;
      }

      remove_hf("P-Asserted-Identity");
      append_hf("P-Asserted-Identity: <sip:$fU@{{ include "avoip.sip.siteHost" . }}>\r\n");
      $ru = "sips:" + $rU + "@" + $var(managed_host);
      route(RR_BACKEND_TO_CARRIER);
      $dlg_ctx(timeout_route) = "OUTBOUND_DIALOG_TIMEOUT";
      dlg_manage();
      dlg_set_property("timeout-noreset");
      if (!dlg_set_timeout("$var(managed_max_duration_seconds)")) {
        route(OUTBOUND_RELEASE);
        sl_send_reply("503", "Outbound Limit Setup Failed"); exit;
      }
      $dlg_var(core_linkedid) = $hdr(X-Core-Call-Linkedid);
      $dlg_var(core_origin_uniqueid) = $hdr(X-Core-Origin-Uniqueid);
      $dlg_var(outbound_site) = "{{ $.Values.region }}";
      $dlg_var(outbound_gateway) = "flowroute";
      $dlg_var(outbound_quota_key) = $var(outbound_quota_key);
      $var(outbound_teardown_key) = "avoip:out:teardown:" + $ci;
      $dlg_var(outbound_teardown_key) = $var(outbound_teardown_key);
      # CoRE authorization/correlation headers are for trusted internal hops
      # only. Preserve the validated call IDs in dialog state for Homer and
      # quota diagnostics, then remove them before sending the INVITE upstream.
      remove_hf("X-Core-Extension");
      remove_hf("X-Core-Call-Linkedid");
      remove_hf("X-Core-Origin-Uniqueid");
      remove_hf("X-Core-Original-DID");
      remove_hf("X-Core-Provider");
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("replace-origin internal external address-family=IP4")) {
          route(OUTBOUND_RELEASE);
          sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
      }
      $du = "sips:" + $var(managed_host) + ":5061;transport=tls";
      $xavp(tls=>server_name) = $var(managed_host);
      $dlg_var(outbound_gateway) = $var(managed_host);
      set_send_socket_name("public_tls");
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog(
        "$ci",
        "kamailio_event=routing_decision route=authorized_outbound_to_flowroute call_id=$ci linkedid=$dlg_var(core_linkedid) origin_uniqueid=$dlg_var(core_origin_uniqueid) site=$dlg_var(outbound_site) gateway=$dlg_var(outbound_gateway) method=$rm cseq=$hdr(CSeq) transport=$proto"
      );
      {{- end }}
      route(RELAY);
      exit;
    }

    route[OUTBOUND_RELEASE] {
      $var(release_script) = "redis.call('ZREM',KEYS[1],'call:'..ARGV[1]);return 1";
      $var(outbound_quota_key) = $dlg_var(outbound_quota_key);
      if ($var(outbound_quota_key) == $null || $var(outbound_quota_key) == "") {
        $var(outbound_quota_key) = "avoip:out:quota:" + $fU;
      }
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(release_script)",
        "$var(outbound_quota_key)",
        "$ci", "outbound_release"
      )) {
        xlog("L_ERR", "Outbound quota release failed callid=$ci\n");
      }
      return;
    }

    # A dialog timer is local to the replica that handled the initial INVITE.
    # A BYE can terminate the dialog through another replica, so the timer
    # consults shared state before creating its own cleanup BYE.
    route[OUTBOUND_DIALOG_TIMEOUT] {
      $var(outbound_teardown_key) = $dlg_var(outbound_teardown_key);
      if ($var(outbound_teardown_key) == $null ||
          !redis_cmd(
            "topos",
            "EVAL %s 1 %s",
            "if redis.call('EXISTS',KEYS[1])==0 then redis.call('SET',KEYS[1],'timeout','EX',86400);return 1 else return 0 end",
            "$var(outbound_teardown_key)", "outbound_timeout_claim"
          )) {
        xlog(
          "L_ERR",
          "SIP dialog timeout action=skipped reason=shared-state-unavailable callid=$ci from_tag=$ft to_tag=$tt direction=outbound-flowroute rtpengine_delete=not-requested\n"
        );
        return;
      }
      if ($redis(outbound_timeout_claim=>type) != $redisd(rpl_int) ||
          $redis(outbound_timeout_claim=>value) != 1) {
        xlog(
          "L_INFO",
          "SIP dialog timeout action=suppressed reason=bye-already-processed callid=$ci from_tag=$ft to_tag=$tt direction=outbound-flowroute rtpengine_delete=not-requested\n"
        );
        return;
      }
      xlog(
        "L_WARN",
        "SIP dialog timeout action=cleanup-bye callid=$ci from_tag=$ft to_tag=$tt direction=outbound-flowroute rtpengine_delete=requested\n"
      );
      if (!rtpengine_delete()) {
        xlog(
          "L_ERR",
          "SIP dialog timeout media-delete=failed callid=$ci from_tag=$ft to_tag=$tt direction=outbound-flowroute\n"
        );
      }
      dlg_bye("all");
      return;
    }

    route[OUTBOUND_BYE_PENDING] {
      $var(outbound_teardown_key) = "avoip:out:teardown:" + $ci;
      $var(outbound_bye_new) = 0;
      $var(outbound_teardown_script) = "if redis.call('EXISTS',KEYS[1])==0 then redis.call('SET',KEYS[1],'pending','EX',86400);return 1 else return 0 end";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s",
        "$var(outbound_teardown_script)", "$var(outbound_teardown_key)",
        "outbound_teardown_write"
      ) || $redis(outbound_teardown_write=>type) != $redisd(rpl_int)) {
        xlog(
          "L_ERR",
          "SIP dialog teardown state=unavailable callid=$ci method=$rm from_tag=$ft to_tag=$tt direction=$var(side) response=503\n"
        );
        sl_send_reply("503", "Dialog Teardown State Unavailable");
        exit;
      }
      $var(outbound_bye_new) = $redis(outbound_teardown_write=>value);
      t_on_reply("OUTBOUND_BYE_REPLY");
      t_on_failure("OUTBOUND_BYE_FAILURE");
      return;
    }

    route[OUTBOUND_BYE_CLEAR] {
      $var(outbound_teardown_key) = "avoip:out:teardown:" + $ci;
      $var(outbound_teardown_script) = "if redis.call('GET',KEYS[1])=='pending' then return redis.call('DEL',KEYS[1]) else return 0 end";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s",
        "$var(outbound_teardown_script)", "$var(outbound_teardown_key)",
        "outbound_teardown_clear"
      )) {
        xlog(
          "L_ERR",
          "SIP dialog teardown state=clear-failed callid=$ci method=$rm from_tag=$ft to_tag=$tt\n"
        );
      }
      return;
    }

    failure_route[OUTBOUND_BYE_FAILURE] {
      route(OUTBOUND_BYE_CLEAR);
    }

    onreply_route[OUTBOUND_BYE_REPLY] {
      if ($rm == "BYE" && $rs >= 200) {
        $var(outbound_teardown_key) = "avoip:out:teardown:" + $ci;
        if ($rs < 300) {
          $var(outbound_teardown_script) = "redis.call('SET',KEYS[1],'complete','EX',86400);return 1";
          if (!redis_cmd(
            "topos", "EVAL %s 1 %s",
            "$var(outbound_teardown_script)", "$var(outbound_teardown_key)",
            "outbound_teardown_write"
          ) || $redis(outbound_teardown_write=>type) != $redisd(rpl_int) ||
              $redis(outbound_teardown_write=>value) != 1) {
            xlog(
              "L_ERR",
              "SIP dialog teardown state=completion-write-failed callid=$ci method=BYE status=$rs from_tag=$ft to_tag=$tt\n"
            );
          }
        } else {
          route(OUTBOUND_BYE_CLEAR);
        }
      }
    }
{{- end -}}
