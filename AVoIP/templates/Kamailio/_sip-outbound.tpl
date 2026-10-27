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

      {{- if include "avoip.kamailio.adminRoutingEnabled" (dict "root" . "instance" .Values.kamailio) | trim }}
      if ($var(managed_json) == $null) {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_missing call_id=$ci method=$rm destination_class=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=snapshot_unavailable site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
        {{- end }}
        sl_send_reply("503", "Routing Snapshot Unavailable"); exit;
      }
      route(MANAGED_EGRESS);
      {{- end }}
      {{- if include "avoip.kamailio.adminRoutingEnabled" (dict "root" . "instance" .Values.kamailio) | trim }}
      if ($var(managed_egress) == 1) route(MANAGED_CARRIER_IDENTITY);
      else route(MANAGED_HANDOFF);
      {{- end }}

      # New calls require the configured service identity and caller policy.
      {{- if include "avoip.kamailio.adminRoutingEnabled" (dict "root" . "instance" .Values.kamailio) | trim }}
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
      # Preserve full +1 E.164 through Asterisk, FreeSWITCH, and the private
      # Kamailio hop. Apply the selected provider prefix only at carrier egress.
      if ($var(managed_egress_prefix) != $null && $var(managed_egress_prefix) != "") {
        $rU = $var(managed_egress_prefix) + "*" + $(rU{re.subst,/^\\+//});
        xlog("L_INFO", "AVOIP_POLICY managed_egress decision=prefix_applied provider_host=$var(managed_host) request_user=$rU call_id=$ci method=$rm\n");
      }

      # FreeSWITCH sends the carrier's Digest challenge response as a new
      # INVITE with the same Call-ID. It is already admitted by the original
      # INVITE's reservation; do not charge that authenticated retry as a new
      # call. Only skip admission when the trusted peer presents an auth
      # header and the original Call-ID reservation exists in Dragonfly.
      $var(outbound_call_key) = "avoip:out:call:" + $ci;
      $var(outbound_auth_retry) = 0;
      if ((is_present_hf("Authorization") || is_present_hf("Proxy-Authorization")) &&
          redis_cmd("topos", "GET %s", "$var(outbound_call_key)", "outbound_call_existing") &&
          $redis(outbound_call_existing=>type) == $redisd(rpl_str)) {
        $var(outbound_auth_retry) = 1;
        xlog("L_INFO", "SIP outbound auth retry callid=$ci cseq=$hdr(CSeq)\n");
      }

      if ($var(outbound_auth_retry) == 0) {
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
      $var(quota_script) = "local k=KEYS[1];local id=ARGV[1];local concurrent=tonumber(" + $var(managed_concurrent_calls) + ");local rate=tonumber(" + $var(managed_calls_per_minute) + ");local duration=tonumber(" + $var(managed_max_duration_seconds) + ");if not id or id=='' or not concurrent or not rate or not duration or concurrent<1 or rate<1 or duration<60 then return -3 end;local now=tonumber(redis.call('TIME')[1]);redis.call('ZREMRANGEBYSCORE',k,0,now);redis.call('ZREMRANGEBYSCORE',k,-now,0);if redis.call('ZSCORE',k,'call:'..id) then return 1 end;if redis.call('ZCOUNT',k,now,'+inf')>=concurrent then return -2 end;if redis.call('ZCOUNT',k,'-inf',-now-1)>=rate or redis.call('ZSCORE',k,'rate:'..id) then return -1 end;redis.call('ZADD',k,now+duration,'call:'..id);redis.call('ZADD',k,-(now+60),'rate:'..id);redis.call('EXPIRE',k,duration);return 1";
      if ($var(managed_limit_scope) == "legacy") {
        $var(outbound_quota_key) = "avoip:out:quota:" + $fU;
      } else {
        $var(outbound_quota_key) = "avoip:limit:" + $var(managed_limit_profile_id);
      }
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(quota_script)",
        "$var(outbound_quota_key)",
        "$ci", "outbound_quota"
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

      # Quota admission is shared across carrier replicas. Keep the mapping
      # outside Kamailio's process-local dialog table so a later BYE handled by
      # another replica can release the same reservation.
      $var(outbound_call_ttl) = $var(managed_max_duration_seconds) + 86400;
      $var(outbound_call_map_script) = "redis.call('SET',KEYS[1],ARGV[1],'EX'," + $var(outbound_call_ttl) + ");return 1";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s",
        "$var(outbound_call_map_script)", "$var(outbound_call_key)",
        "$var(outbound_quota_key)",
        "outbound_call_mapping"
      ) || $redis(outbound_call_mapping=>type) != $redisd(rpl_int) ||
          $redis(outbound_call_mapping=>value) != 1) {
        xlog("L_ERR", "SIP outbound quota mapping failed callid=$ci method=$rm\n");
        route(OUTBOUND_RELEASE);
        sl_send_reply("503", "Outbound Limits Unavailable");
        exit;
      }
      }

      remove_hf("P-Asserted-Identity");
      append_hf("P-Asserted-Identity: <sip:$fU@{{ include "avoip.sip.siteHost" . }}>\r\n");
      $ru = "sips:" + $rU + "@" + $var(managed_host);
      route(RR_BACKEND_TO_CARRIER);
      # CoRE authorization/correlation headers are for trusted internal hops
      # only. Remove them before sending the INVITE upstream.
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
      set_send_socket_name("public_tls");
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog(
        "$ci",
        "kamailio_event=routing_decision route=authorized_outbound_to_flowroute call_id=$ci site={{ $.Values.region }} gateway=$var(managed_host) method=$rm cseq=$hdr(CSeq) transport=$proto"
      );
      {{- end }}
      route(RELAY);
      exit;
    }

    route[OUTBOUND_RELEASE] {
      # Resolve and release the reservation from shared state. This route is
      # deliberately independent of $dlg_var(): Kamailio dialogs are local to
      # one replica, while the BYE may arrive on another replica.
      $var(outbound_call_key) = "avoip:out:call:" + $ci;
      $var(release_script) = "local q=redis.call('GET',KEYS[1]);if not q then return 0 end;redis.call('ZREM',q,'call:'..ARGV[1]);redis.call('DEL',KEYS[1]);return 1";
      if (!redis_cmd(
        "topos", "EVAL %s 1 %s %s", "$var(release_script)",
        "$var(outbound_call_key)",
        "$ci", "outbound_release"
      ) || $redis(outbound_release=>type) != $redisd(rpl_int) ||
          $redis(outbound_release=>value) < 0) {
        xlog("L_ERR", "Outbound quota release failed callid=$ci\n");
      }
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
