{{- define "avoip.kamailio.sip.private" -}}
    # Private role: mutual TLS and an explicit peer list are both required.
    # No carrier URI, Flowroute ACL, or public socket is reachable here.
    request_route {
      if (!sanity_check("1511", "7") || !mf_process_maxfwd_header("10")) {
        if (!is_method("ACK")) sl_send_reply("400", "Invalid Request");
        exit;
      }

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

    route[PRIVATE_RELAY] {
      if (!t_relay()) {
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
      if (!www_authorize("{{ .Values.kamailio.registrar.realm }}", "subscriber")) {
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
      if (!proxy_authorize("{{ .Values.kamailio.registrar.realm }}", "subscriber")) {
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
