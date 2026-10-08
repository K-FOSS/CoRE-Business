{{- define "avoip.kamailio.sip.outbound" -}}
    # Carrier-owned, opt-in PSTN egress. The peer was authenticated by the
    # dedicated SNI/mTLS branch before this route is entered.
    route[FROM_OUTBOUND_PEER] {
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

      # This pilot authorizes a single service identity, CLI and test number.
      # A user registration is not an outbound entitlement.
      if ($fU != "{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}") {
        sl_send_reply("403", "Caller Identity Not Authorized");
        exit;
      }
      if ($rU =~ "^[2-9][0-9]{9}$") {
        $rU = "+1" + $rU;
      } else if ($rU =~ "^1[2-9][0-9]{9}$") {
        $rU = "+" + $rU;
      }
      if (!($rU =~ "^\\+1[2-9][0-9]{2}[2-9][0-9]{6}$") ||
          $rU =~ "^\\+1900" ||
          $rU =~ "^\\+1[2-9][0-9]{2}976[0-9]{4}$" ||
          $rU != "{{ .Values.kamailio.carrierOutbound.testRoute.destination }}") {
        sl_send_reply("403", "Destination Not Authorized");
        exit;
      }

      # Dragonfly executes quota admission atomically across all carrier
      # replicas. A stale call expires after maxDurationSeconds even if a pod
      # disappears before BYE. A failed Redis operation fails closed.
      $var(quota_script) = "local k=KEYS[1];local id=ARGV[1];local now=tonumber(redis.call('TIME')[1]);redis.call('ZREMRANGEBYSCORE',k,0,now);redis.call('ZREMRANGEBYSCORE',k,-now,0);if redis.call('ZSCORE',k,'call:'..id) then return 1 end;if redis.call('ZCOUNT',k,now,'+inf')>={{ .Values.kamailio.carrierOutbound.limits.concurrentCalls }} then return -2 end;if redis.call('ZCOUNT',k,'-inf',-now-1)>={{ .Values.kamailio.carrierOutbound.limits.callsPerMinute }} or redis.call('ZSCORE',k,'rate:'..id) then return -1 end;redis.call('ZADD',k,now+{{ .Values.kamailio.carrierOutbound.limits.maxDurationSeconds }},'call:'..id);redis.call('ZADD',k,-(now+60),'rate:'..id);redis.call('EXPIRE',k,{{ .Values.kamailio.carrierOutbound.limits.maxDurationSeconds }});return 1";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(quota_script)",
        "avoip:out:quota:{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}",
        "$ci", "outbound_quota"
      )) {
        sl_send_reply("503", "Outbound Quota Unavailable");
        exit;
      }
      if ($redis(outbound_quota=>type) != $redisd(rpl_int) ||
          $redis(outbound_quota=>value) != 1) {
        sl_send_reply("486", "Outbound Limit Reached");
        exit;
      }

      remove_hf("P-Asserted-Identity");
      append_hf("P-Asserted-Identity: <sip:{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}@{{ include "avoip.sip.siteHost" . }}>\r\n");
      $ru = "sips:" + $rU + "@{{ .Values.flowroute.outboundHost }}";
      route(RR_BACKEND_TO_CARRIER);
      dlg_manage();
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("replace-origin internal external")) {
          route(OUTBOUND_RELEASE);
          sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
      }
      $du = "sips:{{ .Values.flowroute.outboundHost }}:5061;transport=tls";
      set_send_socket_name("public_tls");
      route(RELAY);
      exit;
    }

    route[OUTBOUND_RELEASE] {
      $var(release_script) = "redis.call('ZREM',KEYS[1],'call:'..ARGV[1]);return 1";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(release_script)",
        "avoip:out:quota:{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}",
        "$ci", "outbound_release"
      )) {
        xlog("L_ERR", "Outbound quota release failed callid=$ci\n");
      }
      return;
    }
{{- end -}}
