{{- define "avoip.kamailio.sip.private" -}}
{{- $sipCoreReturnHost := include "avoip.sip.sipCoreReturnHost" (dict "root" .) -}}
    # The private peer listener uses strict mTLS and an explicit allowlist.
    # The separate SIP Core return listener uses Cilium workload identity.
    request_route {
      if (!sanity_check("1511", "7") || !mf_process_maxfwd_header("10")) {
        if (!is_method("ACK")) sl_send_reply("400", "Invalid Request");
        exit;
      }

      {{- if and $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled (eq .Values.kamailio.name $.Values.asterisk.sipCore.kamailioInstance) }}
      # SIP Core WebSocket signaling has its own listener and handshake policy.
      if ($proto == "ws" && $Rp == {{ $.Values.asterisk.sipCore.httpPort }}) {
        $var(side) = "sipcore";
        {{- if .Values.kamailio.sipLogging.sipCore }}
        if (is_method("INVITE|BYE|CANCEL")) {
          xlog(
            "L_WARN",
            "SIPCORE FLOW stage=websocket-ingress pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp recv=$Ri:$Rp/$proto user=$fU target=$rU cseq=$hdr(CSeq)\n"
          );
        }
        {{- end }}
        route(FROM_SIPCORE);
        exit;
      }
      # This dedicated listener uses server-authenticated TLS. Cilium's
      # workload-identity policy restricts its source to the Asterisk pods.
      if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.privateEgressPort }}) {
        $var(side) = "sipcore";
        {{- if .Values.kamailio.sipLogging.sipCore }}
        if (is_method("INVITE|BYE|CANCEL")) {
          xlog(
            "L_WARN",
            "SIPCORE FLOW stage=asterisk-ingress pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp recv=$Ri:$Rp/$proto user=$fU target=$rU cseq=$hdr(CSeq)\n"
          );
        }
        {{- end }}
        route(FROM_SIPCORE_ASTERISK);
        exit;
      }
      {{- end }}

      if ($proto != "tls" || $Rp != 5062 || $tls_peer_verified != 1) {
        if (!is_method("ACK")) sl_send_reply("403", "Peer Not Authorized");
        exit;
      }

      $var(peer_allowed) = 0;
      $var(peer_name) = "";
      {{- range .Values.kamailio.privateRouting.peers }}
      if (src_ip == {{ .cidr }} && $tls_peer_san_hostname == "{{ .sanHostname }}") {
        $var(peer_allowed) = 1;
        $var(peer_name) = "{{ .name }}";
      }
      {{- end }}
      if ($var(peer_allowed) != 1) {
        if (!is_method("ACK")) sl_send_reply("403", "Peer Not Authorized");
        exit;
      }

      if (is_method("REGISTER")) {
        {{- if .Values.kamailio.registrar.enabled }}
        route(PRIVATE_REGISTER);
        {{- else }}
        sl_send_reply("403", "Registration Disabled");
        {{- end }}
        exit;
      }
      if (is_method("OPTIONS") && !has_totag()) {
        sl_send_reply("200", "Keepalive");
        exit;
      }
      if (is_method("CANCEL")) {
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) sl_send_reply("481", "Call Does Not Exist");
        else if ($var(cancel_result) < 0) sl_reply_error();
        exit;
      }

      if (has_totag()) {
        # Negative INVITE ACK belongs to its original transaction.
        if (is_method("ACK") && !is_present_hf("Route") && $(ru{uri.param,tps}) == "") {
          if (t_check_trans()) {
            route(PRIVATE_RELAY);
            exit;
          }
        }
        if (!is_method("ACK|BYE|INVITE|UPDATE|INFO|PRACK|REFER|NOTIFY") ||
            !loose_route_mode("1")) {
          if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
          exit;
        }
        {{- if .Values.kamailio.carrierOutbound.enabled }}
        # TOPOS presents Carrier's public Contact to the originating peer.
        # In-dialog traffic for that Contact still needs Envoy's PROXY v2.
        if ($var(peer_name) != "carrier" &&
            $(ru{uri.host}) == "{{ include "avoip.sip.siteHost" . }}") {
          route(PRIVATE_TO_CARRIER_GATEWAY);
        }
        {{- end }}
        # The Route/Contact selected on the initial request remains the owner.
        route(PRIVATE_RELAY);
        exit;
      }

      if (is_method("ACK")) {
        if (t_check_trans()) route(PRIVATE_RELAY);
        exit;
      }
      if (!is_method("INVITE")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      {{- if .Values.kamailio.registrar.enabled }}
      if ($var(peer_name) == "{{ .Values.kamailio.registrar.accessPeerName }}") {
        route(PRIVATE_AUTH_DEVICE);
        if ($var(auth_device) != 1) exit;
        $var(registered_destination) = 0;
        {{- range .Values.kamailio.registrar.allowedUsers }}
        if ($rU == "{{ . }}") $var(registered_destination) = 1;
        {{- end }}
        if ($var(registered_destination) == 1 &&
            $(ru{uri.host}) == "{{ .Values.kamailio.registrar.realm }}") {
          if (!is_subscriber("$ru", "active_subscriber", "3")) {
            sl_send_reply("404", "User Not Available");
            exit;
          }
          if (!lookup("location")) {
            sl_send_reply("404", "User Not Registered");
            exit;
          }
          record_route();
          route(PRIVATE_RELAY);
          exit;
        }
        # A Digest-authenticated registration grants no application/PSTN route.
        sl_send_reply("403", "Destination Not Authorized");
        exit;
      }
      {{- end }}

      {{- if .Values.kamailio.carrierOutbound.enabled }}
      # The pilot is a single exact extension and destination. Registration
      # alone never enters this branch; source mTLS and From caller ID are
      # checked against the one authorized service peer.
      if ($rU == "{{ .Values.kamailio.carrierOutbound.testRoute.extension }}") {
        if ($var(peer_name) != "{{ .Values.kamailio.carrierOutbound.testRoute.peerName }}" ||
            $fU != "{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}") {
          sl_send_reply("403", "Outbound Identity Not Authorized");
          exit;
        }
        $ru = "sips:{{ .Values.kamailio.carrierOutbound.testRoute.destination }}@{{ .Values.kamailio.carrierOutbound.sniHost }}";
        remove_hf("P-Asserted-Identity");
        append_hf("P-Asserted-Identity: <sip:{{ .Values.kamailio.carrierOutbound.testRoute.callerId }}@{{ .Values.kamailio.carrierOutbound.sniHost }}>\r\n");
        record_route();
        route(PRIVATE_TO_CARRIER_GATEWAY);
        route(PRIVATE_RELAY);
        exit;
      }
      {{- end }}

      # Exact extension mapping is deliberately narrower than a dial prefix.
      # An authenticated peer cannot gain PSTN access through this role.
      $var(destination_set) = 0;
      {{- range .Values.kamailio.privateRouting.routes }}
      {{- $route := . }}
      {{- range $peer := $.Values.kamailio.privateRouting.peers }}
      {{- if has $route.user ($peer.allowedUsers | default list) }}
      if ($var(peer_name) == "{{ $peer.name }}" && $rU == "{{ $route.user }}")
        $var(destination_set) = {{ $route.setId }};
      {{- end }}
      {{- end }}
      {{- end }}
      if ($var(destination_set) == 0 ||
          !ds_select_dst("$var(destination_set)", "0")) {
        sl_send_reply("404", "Destination Unavailable");
        exit;
      }

      record_route();
      route(PRIVATE_RELAY);
    }

    {{- if and $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled (eq .Values.kamailio.name $.Values.asterisk.sipCore.kamailioInstance) }}
    route[FROM_SIPCORE] {
      if (!is_method("REGISTER|INVITE|ACK|BYE|CANCEL|OPTIONS|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      force_rport();
      if (nat_uac_test(64)) {
        if (is_method("REGISTER") && is_present_hf("Contact") && $hdr(Contact) != "*") {
          if (!add_contact_alias()) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
        } else if (!has_totag() && is_method("INVITE") && is_present_hf("Contact")) {
          if (!add_contact_alias()) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
        }
      }

      t_on_reply("SIPCORE_WS_REPLY");
      if (is_method("CANCEL")) {
        rtpengine_manage();
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) sl_send_reply("481", "Call Does Not Exist");
        else if ($var(cancel_result) < 0) sl_reply_error();
        exit;
      }

      if (has_totag() && !loose_route()) {
        if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
        exit;
      }
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin external internal")) {
          xlog("L_ERR", "RTPEngine SIP Core SDP handling failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }
      if (is_method("INVITE") && !has_totag()) {
        record_route_preset("{{ $sipCoreReturnHost }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls");
      }
      route(TO_SIPCORE_ASTERISK);
      {{- if .Values.kamailio.sipLogging.sipCore }}
      if (is_method("INVITE|BYE|CANCEL")) {
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=forward-to-asterisk pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination=$du target=$rU cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}
      route(PRIVATE_RELAY);
    }

    route[FROM_SIPCORE_ASTERISK] {
      if (!is_method("INVITE|ACK|BYE|CANCEL|OPTIONS|UPDATE|INFO|PRACK|REFER|NOTIFY")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }
      if (is_method("CANCEL")) {
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) sl_send_reply("481", "Call Does Not Exist");
        else if ($var(cancel_result) < 0) sl_reply_error();
        exit;
      }

      $var(sipcore_dialog_routed) = 0;
      if (has_totag() && loose_route()) {
        $var(sipcore_dialog_routed) = 1;
        $var(sipcore_local_route_hops) = 0;

        # Asterisk has an outbound_proxy and the dialog has a Kamailio
        # Record-Route. Both can leave the private return service in the
        # Route set, so consume any repeated local hops before resolving the
        # WebSocket Contact alias.
        while ($du != $null &&
               $(du{uri.host}) == "{{ $sipCoreReturnHost }}" &&
               $(du{uri.port}) == "{{ $.Values.asterisk.sipCore.privateEgressPort }}" &&
               $var(sipcore_local_route_hops) < 4) {
          $du = $null;
          $var(sipcore_local_route_hops) = $var(sipcore_local_route_hops) + 1;
          loose_route();
        }
        if ($du != $null &&
            $(du{uri.host}) == "{{ $sipCoreReturnHost }}" &&
            $(du{uri.port}) == "{{ $.Values.asterisk.sipCore.privateEgressPort }}") {
          sl_send_reply("482", "Too Many Local Route Hops");
          exit;
        }

        # The WebSocket contact's alias carries the live transport address.
        # Only use it after all local Route hops were consumed; preserve any
        # non-local route selected by the dialog route set.
        if ($du == $null) {
          handle_ruri_alias();
          if ($rc != 1) {
            sl_send_reply("404", "WebSocket Contact Not Found");
            exit;
          }
        }
      }
      if ($var(sipcore_dialog_routed) != 1) {
        # This return listener is reachable only from the Asterisk workload.
        # Asterisk's Request-URI is the random WebSocket Contact user, not the
        # configured extension; require a live Kamailio alias instead of
        # comparing that Contact user to the extension allowlist.
        handle_ruri_alias();
        if ($rc != 1) {
          sl_send_reply("404", "WebSocket Contact Not Found");
          exit;
        }
        if (is_method("INVITE") && !has_totag()) {
          record_route_preset("{{ $sipCoreReturnHost }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls");
        }
      }
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin internal external")) {
          xlog("L_ERR", "RTPEngine SIP Core outbound SDP handling failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }
      if (is_method("BYE")) {
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=asterisk-bye pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp target=$rU cseq=$hdr(CSeq)\n"
        );
      }
      t_on_reply("SIPCORE_ASTERISK_REPLY");
      {{- if .Values.kamailio.sipLogging.sipCore }}
      if (is_method("INVITE|BYE|CANCEL")) {
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=forward-to-websocket pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination=$du target=$rU cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}
      route(PRIVATE_RELAY);
    }

    route[TO_SIPCORE_ASTERISK] {
      $du = "sip:{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}:5061;transport=tls";
      $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}";
      set_send_socket_name("private_tls");
    }

    onreply_route[SIPCORE_ASTERISK_REPLY] {
      {{- if .Values.kamailio.sipLogging.sipCore }}
      if ($rm == "INVITE" || $rm == "BYE") {
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=asterisk-response pod=$env(POD_NAME) callid=$ci method=$rm status=$rs source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin external internal")) {
          xlog("L_ERR", "RTPEngine SIP Core outbound answer handling failed callid=$ci status=$rs\n");
          drop;
        }
      }
    }

    onreply_route[SIPCORE_WS_REPLY] {
      {{- if .Values.kamailio.sipLogging.sipCore }}
      if ($rm == "INVITE" || $rm == "BYE") {
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=websocket-response pod=$env(POD_NAME) callid=$ci method=$rm status=$rs source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin internal external")) {
          xlog("L_ERR", "RTPEngine SIP Core WebSocket answer handling failed callid=$ci status=$rs\n");
          drop;
        }
      }
      if (nat_uac_test(64) && is_present_hf("Contact")) add_contact_alias();
    }
    {{- end }}

    route[PRIVATE_RELAY] {
      if (!t_relay()) {
        {{- if .Values.kamailio.sipLogging.sipCore }}
        if ($var(side) == "sipcore") {
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=relay-failure pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination=$du socket=$fsn cseq=$hdr(CSeq)\n"
          );
        }
        {{- end }}
        if (!is_method("ACK")) sl_reply_error();
      }
      exit;
    }

    {{- if .Values.kamailio.registrar.enabled }}
    route[PRIVATE_REGISTER] {
      if ($var(peer_name) != "{{ .Values.kamailio.registrar.accessPeerName }}" ||
          $tU == $null || $tU != $au && $au != $null ||
          $(tu{uri.host}) != "{{ .Values.kamailio.registrar.realm }}" ||
          $(ru{uri.host}) != "{{ .Values.kamailio.registrar.realm }}") {
        sl_send_reply("403", "AoR Not Authorized");
        exit;
      }
      $var(pilot_user) = 0;
      {{- range .Values.kamailio.registrar.allowedUsers }}
      if ($tU == "{{ . }}") $var(pilot_user) = 1;
      {{- end }}
      if ($var(pilot_user) != 1) {
        sl_send_reply("403", "AoR Not Authorized");
        exit;
      }
      if (!www_authorize("{{ .Values.kamailio.registrar.realm }}", "active_subscriber")) {
        www_challenge("{{ .Values.kamailio.registrar.realm }}", "1");
        exit;
      }
      if ($au != $tU || $fd != "{{ .Values.kamailio.registrar.realm }}") {
        sl_send_reply("403", "AoR Not Authorized");
        exit;
      }
      # registrar.save() sends its own 200 or error response.
      save("location");
      exit;
    }

    route[PRIVATE_AUTH_DEVICE] {
      $var(auth_device) = 0;
      if ($fd != "{{ .Values.kamailio.registrar.realm }}") {
        sl_send_reply("403", "Caller Not Authorized");
        return;
      }
      $var(pilot_user) = 0;
      {{- range .Values.kamailio.registrar.allowedUsers }}
      if ($fU == "{{ . }}") $var(pilot_user) = 1;
      {{- end }}
      if ($var(pilot_user) != 1) {
        sl_send_reply("403", "Caller Not Authorized");
        return;
      }
      if (!proxy_authorize("{{ .Values.kamailio.registrar.realm }}", "active_subscriber")) {
        proxy_challenge("{{ .Values.kamailio.registrar.realm }}", "1");
        return;
      }
      if ($au != $fU) {
        sl_send_reply("403", "Caller Not Authorized");
        return;
      }
      $var(auth_device) = 1;
    }
    {{- end }}

    {{- if .Values.kamailio.carrierOutbound.enabled }}
    route[PRIVATE_TO_CARRIER_GATEWAY] {
      $du = "sips:{{ .Values.kamailio.carrierOutbound.gatewayServiceHost }}:5061;transport=tls";
      $xavp(tls=>server_name) = "{{ .Values.kamailio.carrierOutbound.sniHost }}";
      set_send_socket_name("private_tls");
    }
    {{- end }}
{{- end -}}
