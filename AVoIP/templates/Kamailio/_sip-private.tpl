{{- define "avoip.kamailio.sip.private" -}}
{{- $sipCoreReturnHost := include "avoip.sip.sipCoreReturnHost" (dict "root" .) -}}
{{- $sipCoreEnabled := and (eq .Values.kamailio.role "private-sbc") (or (eq .Values.kamailio.name $.Values.asterisk.sipCore.kamailioInstance) .Values.kamailio.websocketHA.enabled .Values.kamailio.websocketHA.legacyOwner) $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled -}}
    # The private peer listener uses strict mTLS and an explicit allowlist.
    # The separate SIP Core return listener uses Cilium workload identity.
    request_route {
      {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
      $var(managed_json) = $sht(managed=>snapshot);
      $var(managed_provider) = "";
      {{- end }}
      if (!sanity_check("1511", "7") || !mf_process_maxfwd_header("10")) {
        if (!is_method("ACK")) sl_send_reply("400", "Invalid Request");
        exit;
      }

      {{- if and $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled (or (eq .Values.kamailio.name $.Values.asterisk.sipCore.kamailioInstance) .Values.kamailio.websocketHA.enabled .Values.kamailio.websocketHA.legacyOwner) }}
      # SIP Core WebSocket signaling has its own listener and handshake policy.
      if ($proto == "ws" && $Rp == {{ $.Values.asterisk.sipCore.httpPort }}) {
        $var(side) = "sipcore";
        {{- if .Values.kamailio.sipLogging.sipCore }}
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=websocket-ingress pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt\n"
        );
        {{- end }}
        route(FROM_SIPCORE);
        exit;
      }
      # This dedicated listener uses server-authenticated TLS. Cilium's
      # workload-identity policy restricts its source to the Asterisk pods.
      if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.privateEgressPort }}) {
        $var(side) = "sipcore";
        {{- if .Values.kamailio.sipLogging.sipCore }}
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=asterisk-ingress pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq)\n"
        );
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
      {{- if and .Values.freeswitch.enabled .Values.freeswitch.flowrouteOutbound.enabled .Values.kamailio.carrierOutbound.enabled }}
      # FreeSWITCH presents its Vault-issued SIP identity on the private TLS
      # listener when placing Flowroute-registered outbound calls. Limit this
      # peer to its exact service SAN and pod CIDR before applying the +1
      # caller-ID verification and full +1 format check below.
      if (src_ip == {{ .Values.kamailio.backend.podCIDR }} &&
          $tls_peer_verified == 1 &&
          $tls_peer_san_hostname == "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}") {
        $var(peer_allowed) = 1;
        $var(peer_name) = "freeswitch-flowroute";
      }
      {{- end }}
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

      # Let TM replay the cached final response to a retransmitted BYE before
      # topology, media, or teardown side effects run again.
      if (is_method("BYE") && t_check_trans()) {
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
        $var(private_loose_route_result) = loose_route_mode("1");
        if (!is_method("ACK|BYE|INVITE|UPDATE|INFO|PRACK|REFER|NOTIFY") ||
            $var(private_loose_route_result) <= 0) {
          xlog(
            "L_WARN",
            "SIP dialog route stage=private-topos-restore pod=$env(POD_NAME) callid=$ci method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=$var(peer_name) topos_result=route-miss loose_route_result=$var(private_loose_route_result) ruri=$ru route=$hdr(Route)\n"
          );
          if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
          exit;
        }
        xlog(
          "L_INFO",
          "SIP dialog route stage=private-topos-restore pod=$env(POD_NAME) callid=$ci method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=$var(peer_name) topos_result=route-restored loose_route_result=$var(private_loose_route_result) ruri=$ru route=$hdr(Route) selected_next_hop=$du\n"
        );
        {{- if .Values.kamailio.carrierOutbound.enabled }}
        # TOPOS presents Carrier's public Contact to the originating peer.
        # In-dialog traffic for that Contact still needs Envoy's PROXY v2.
        if ($var(peer_name) != "carrier" &&
            $(ru{uri.host}) == "{{ include "avoip.sip.siteHost" . }}") {
          route(PRIVATE_TO_CARRIER_GATEWAY);
        }
        # A remote BYE arriving through the authenticated carrier Kamailio
        # peer has already traversed the public tier. TOPOS restores this
        # tier's FreeSWITCH Contact into the Request-URI. Older dialogs can
        # still carry the UDP registration gateway's transport parameter, so
        # select a TLS next hop to the validated owner/listener. New outbound
        # calls use a separate TLS-only gateway and advertise a matching TLS
        # Contact. Retain the Request-URI, Route set, and dialog identifiers.
        if ($var(peer_name) == "carrier") {
          # SIP Core/Asterisk-owned outbound dialogs return through this
          # listener after the carrier has stripped the public topology. The
          # managed_outbound marker is stored on the dialog when the original
          # Asterisk INVITE is authorized. Send its in-dialog requests back to
          # Asterisk; only unmarked legacy dialogs use the FreeSWITCH owner.
          {{- if $sipCoreEnabled }}
          if ($dlg_var(managed_outbound) == "yes" || $hdr(Route) =~ "sipcore-return") {
            route(TO_SIPCORE_ASTERISK);
            xlog(
              "L_INFO",
              "SIP dialog route stage=carrier-to-sipcore pod=$env(POD_NAME) callid=$ci method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=carrier-originated destination=$du transport=$dP socket=$fsn ruri=$ru route=$hdr(Route) rtpengine_delete=requested-upstream\n"
            );
            route(PRIVATE_RELAY);
            exit;
          }
          {{- end }}
          if (!($rd =~ "^[0-9.]+$") ||
              $rp != {{ .Values.freeswitch.flowrouteOutbound.tlsPort }}) {
            xlog(
              "L_WARN",
              "SIP dialog route stage=carrier-to-freeswitch result=invalid-owner-target pod=$env(POD_NAME) callid=$ci method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) ruri=$ru route=$hdr(Route)\n"
            );
            if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
            exit;
          }
          $du = "sip:" + $rd + ":" + $rp + ";transport=tls";
          $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}";
          set_send_socket_name("private_tls");
          xlog(
            "L_WARN",
            "SIP dialog route stage=carrier-to-freeswitch pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=carrier-originated topos_result=restored-owner destination=$du transport=$dP tls_sni=$xavp(tls=>server_name) socket=$fsn ruri=$ru route=$hdr(Route) rtpengine_delete=requested-upstream\n"
          );
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

      {{- if and .Values.freeswitch.enabled .Values.freeswitch.flowrouteOutbound.enabled .Values.kamailio.carrierOutbound.enabled }}
      # Admin policy is authoritative for calls from the registered Flowroute
      # gateway. Static extension and caller-ID fallback routes are removed.
      if ($var(peer_name) == "freeswitch-flowroute") {
        {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
        if ($var(managed_json) == $null) {
          xlog("L_WARN", "AVOIP_POLICY reject=managed_snapshot_missing call_id=$ci method=$rm destination_class=nanp\n");
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=authorization_result policy=provider_egress decision=deny reason=snapshot_unavailable site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
          {{- end }}
          sl_send_reply("503", "Routing Snapshot Unavailable"); exit;
        }
        route(MANAGED_EGRESS);
        if ($var(managed_egress) != 1) {
          xlog("L_WARN", "AVOIP_POLICY reject=managed_egress_unverified call_id=$ci method=$rm destination_class=nanp\n");
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=authorization_result policy=provider_egress decision=deny reason=provider_not_eligible site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
          {{- end }}
          sl_send_reply("403", "Managed Egress Not Authorized"); exit;
        }
        if (!is_method("INVITE") || !($rU =~ "^\\+1[0-9]{10}$")) {
          xlog("L_WARN", "AVOIP_POLICY reject=destination_not_allowed call_id=$ci method=$rm destination_class=restricted_or_invalid\n");
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=destination_not_allowed site={{ $.Values.region }} call_id=$ci method=$rm destination_class=restricted_or_invalid");
          {{- end }}
          sl_send_reply("403", "Destination Not Authorized"); exit;
        }
        remove_hf("Route"); remove_hf("P-Asserted-Identity"); remove_hf("X-Core-Extension"); remove_hf("X-Core-Original-DID");
        append_hf("P-Asserted-Identity: <sip:$fU@{{ include "avoip.sip.siteHost" . }}>\r\n");
        # Select the actual carrier next hop before building Record-Route so
        # Kamailio records both the private egress socket and SIP Core return
        # listener for this dialog. dlg_manage() adds its dialog cookie to
        # both Record-Route headers; recording before socket selection can
        # leave only one RR lump and prevent dialog state from being created.
        route(PRIVATE_TO_CARRIER_GATEWAY);
        record_route();
        dlg_manage();
        $dlg_var(outbound_carrier) = "yes";
        route(PRIVATE_RELAY); exit;
        {{- else }}
        xlog("L_WARN", "AVOIP_POLICY reject=admin_routing_required call_id=$ci method=$rm destination_class=nanp\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=authorization_result policy=outbound decision=deny reason=admin_routing_required site={{ $.Values.region }} call_id=$ci method=$rm destination_class=nanp");
        {{- end }}
        sl_send_reply("503", "Admin Routing Required"); exit;
        {{- end }}
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

    {{- if and $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled (or (eq .Values.kamailio.name $.Values.asterisk.sipCore.kamailioInstance) .Values.kamailio.websocketHA.enabled .Values.kamailio.websocketHA.legacyOwner) }}
    route[FROM_SIPCORE] {
      if (!is_method("REGISTER|INVITE|ACK|BYE|CANCEL|OPTIONS|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      # Asterisk assigns its linkedid only after this originating dialog
      # already exists. Use the dialog's native Call-ID as a deterministic
      # Homer correlation alias, discard caller-supplied values, and do not
      # attach call metadata to REGISTER/OPTIONS transactions.
      remove_hf("X-Core-Call-Linkedid");
      remove_hf("X-Core-Origin-Uniqueid");
      if (is_method("INVITE|ACK|BYE|CANCEL|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        remove_hf("X-Call-ID");
        append_hf("X-Call-ID: $ci\r\n");
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
      route(SIPCORE_CONTENT_TYPE);
      if ($var(sipcore_content_type) == "application/trickle-ice-sdpfrag" && has_body()) {
        if (!is_method("INFO")) {
          xlog("L_ERR", "SIPCORE FLOW stage=reject-trickle-fragment pod=$env(POD_NAME) callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl\n");
          if (!is_method("ACK")) sl_send_reply("488", "Trickle ICE Requires INFO");
          exit;
        }
        if (!rtpengine_info()) {
          xlog("L_ERR", "RTPEngine SIP Core trickle ICE update failed callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl cseq=$hdr(CSeq) branch=trickle-ice status=503\n");
          sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
        xlog("L_INFO", "SIPCORE INFO callid=$ci cseq=$hdr(CSeq) method=$rm content_type=$cT branch=trickle-ice relay_result=consumed status=200\n");
        sl_send_reply("200", "OK");
        exit;
      }
      $var(sipcore_managed_codec_flags) = "";
      if (is_method("INVITE") && !has_totag() &&
          $rU =~ "^\\+1[0-9]{10}$" &&
          $hdr(X-Core-Extension) =~ "^[0-9]{2,12}$" && $var(managed_json) != $null) {
        $var(sipcore_managed_extension_path) = "extensions." + $hdr(X-Core-Extension);
        if (jansson_get("$var(sipcore_managed_extension_path)", "$var(managed_json)", "$var(sipcore_managed_extension)")) {
          jansson_get("codec_flags", "$var(sipcore_managed_extension)", "$var(sipcore_managed_codec_flags)");
        }
      }
      if (has_body("application/sdp")) {
        if (!($rb =~ "m=")) {
          xlog("L_ERR", "SIPCORE FLOW stage=reject-incomplete-sdp pod=$env(POD_NAME) callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl\n");
          if (!is_method("ACK")) sl_send_reply("488", "Incomplete SDP Offer");
          exit;
        }
        $var(sipcore_media_flags) = "WebRTC replace-origin external internal address-family=IP4";
        if ($var(sipcore_managed_codec_flags) != $null && $var(sipcore_managed_codec_flags) != "") {
          $var(sipcore_media_flags) = $var(sipcore_media_flags) + " " + $var(sipcore_managed_codec_flags);
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=selected direction=outbound extension=$hdr(X-Core-Extension) stage=asterisk_sdp_offer flags=$var(sipcore_managed_codec_flags) call_id=$ci");
          {{- end }}
        }
        if (!rtpengine_manage("$var(sipcore_media_flags)")) {
          xlog("L_ERR", "RTPEngine SIP Core SDP handling failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
        if ($var(sipcore_managed_codec_flags) != $null && $var(sipcore_managed_codec_flags) != "") {
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=applied direction=outbound extension=$hdr(X-Core-Extension) stage=asterisk_sdp_offer flags=$var(sipcore_managed_codec_flags) call_id=$ci");
          {{- end }}
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }
      {{- if .Values.kamailio.websocketHA.enabled }}
      route(TO_SIPCORE_ASTERISK);
      if (is_method("REGISTER")) {
        # PJSIP_DIAL_CONTACTS() sends the stored Contact URI directly, so a
        # browser's randomized .invalid host cannot be resolved by Asterisk.
        # Give each registration the receiving StatefulSet pod's stable owner
        # hostname; keep the Contact alias so the owner can find its live WS
        # flow when the INVITE returns. The matching Path remains owner-pod
        # addressed for path-aware AOR requests.
        if (is_present_hf("Contact") && $hdr(Contact) != "*" &&
            !subst_hf("Contact", "/@[^;>; ]+;transport=ws/@SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls/ig", "a")) {
          sl_send_reply("400", "Unsupported WebSocket Contact");
          exit;
        }
        remove_hf("Path");
        set_send_socket_name("sipcore_owner_tls");
        if (!add_path_received()) {
          sl_send_reply("503", "SIP Owner Path Unavailable");
          exit;
        }
      }
      {{- end }}
      if (is_method("INVITE") && !has_totag()) {
        {{- if .Values.kamailio.websocketHA.enabled }}
        record_route_preset("SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
        {{- else }}
        record_route_preset("{{ $sipCoreReturnHost }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
        {{- end }}
      }
      {{- if not .Values.kamailio.websocketHA.enabled }}
      route(TO_SIPCORE_ASTERISK);
      {{- end }}
      {{- if .Values.kamailio.sipLogging.sipCore }}
      xlog(
        "L_WARN",
        "SIPCORE FLOW stage=forward-to-asterisk pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt content_type=$cT\n"
      );
      {{- end }}
      route(PRIVATE_RELAY);
    }

    route[FROM_SIPCORE_ASTERISK] {
      if (!is_method("INVITE|ACK|BYE|CANCEL|OPTIONS|UPDATE|INFO|PRACK|REFER|NOTIFY")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }
      {{- if .Values.kamailio.sipLogging.sipCore }}
      xlog(
        "L_INFO",
        "SIPCORE FLOW stage=asterisk-return-in pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp ruri_host=$rd transport=$proto cseq=$hdr(CSeq)\n"
      );
      {{- end }}
      if (is_method("CANCEL")) {
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) sl_send_reply("481", "Call Does Not Exist");
        else if ($var(cancel_result) < 0) sl_reply_error();
        exit;
      }

      {{- if and .Values.avoipAdmin.enabled .Values.avoipAdmin.routing.enabled (not (dig "websocketHA" "enabled" false .Values.kamailio)) }}
      $var(core_managed_from_tag) = "";
      $var(core_managed_route_processed) = 0;
      if (has_totag() && is_present_hf("Route")) {
        $var(core_managed_from_tag) = $(route_uri{uri.param,core_managed_from});
        if ($var(core_managed_from_tag) != "" && loose_route()) {
          $var(core_managed_route_processed) = 1;
        }
      }
      if ($var(core_managed_route_processed) == 1) {
        if ($ft == $var(core_managed_from_tag)) {
          # The Asterisk-originated leg heads back through the selected
          # carrier gateway. The Route set, rather than dlg_var, identifies it.
          route(PRIVATE_TO_CARRIER_GATEWAY);
          route(PRIVATE_RELAY); exit;
        } else if ($tt == $var(core_managed_from_tag)) {
          # A carrier-originated teardown belongs to Asterisk's SIP service;
          # do not interpret its service Contact as a WebSocket alias.
          route(TO_SIPCORE_ASTERISK);
          route(PRIVATE_RELAY); exit;
        }
        if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
        exit;
      }
      if (has_totag() && $dlg_var(managed_outbound) == "yes") {
        if (!loose_route()) { if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist"); exit; }
        # Asterisk is the originator of this managed dialog. Its BYE (and
        # other in-dialog requests) must follow the carrier gateway, not the
        # SIP Core return route back toward the WebSocket contact.
        route(PRIVATE_TO_CARRIER_GATEWAY);
        route(PRIVATE_RELAY); exit;
      }
      if (!has_totag() && is_method("INVITE") &&
          $rU =~ "^\\+1[0-9]{10}$") {
        # This listener is reachable only from the Asterisk workload under
        # Cilium policy. Asterisk creates this header in its locked extension
        # context; never derive the extension from the caller-ID From user.
        if (!($hdr(X-Core-Extension) =~ "^[0-9]{2,12}$")) {
          xlog("L_WARN", "AVOIP_POLICY reject=trusted_extension_missing call_id=$ci source=asterisk-tls destination_format=plus1-10\n");
          sl_send_reply("403", "Managed Extension Identity Missing"); exit;
        }
        $var(managed_extension_id) = $hdr(X-Core-Extension);
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=outbound_attempt component=private_sipcore extension=$var(managed_extension_id) site={{ .Values.region }} linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) call_id=$ci method=$rm destination_class=plus1-10");
        {{- end }}
      }
      route(MANAGED_EXTENSION);
      # Database routing is authoritative for canonical +1 destinations. A
      # missing, expired, or unauthorized extension mapping must be rejected.
      if (!has_totag() && is_method("INVITE") &&
          $rU =~ "^\\+1[0-9]{10}$") {
        xlog("L_WARN", "AVOIP_POLICY reject=managed_extension_unmatched call_id=$ci extension=$var(managed_extension_id) destination_format=plus1-10\n");
        sl_send_reply("403", "Managed Extension Not Authorized");
        exit;
      }
      {{- end }}
      {{- if .Values.kamailio.carrierOutbound.enabled }}
      if (has_totag() && $dlg_var(outbound_carrier) == "yes") {
        if (is_method("ACK") && !is_present_hf("Route") && $(ru{uri.param,tps}) == "") {
          if (t_check_trans()) route(PRIVATE_RELAY);
          exit;
        }
        if (!loose_route()) {
          if (!is_method("ACK")) sl_send_reply("481", "Call Does Not Exist");
          exit;
        }
        route(PRIVATE_TO_CARRIER_GATEWAY);
        route(PRIVATE_RELAY);
      }
      {{- end }}

      {{- if .Values.kamailio.websocketHA.enabled }}
      # PJSIP_DIAL_CONTACTS() fans out explicit Contact URIs. Some Asterisk
      # versions do not attach the contact's Path on those initial INVITEs.
      # The Contact URI itself is rewritten to its owning StatefulSet pod, so
      # allow this narrowly scoped case only on that exact owner's Asterisk-
      # only TLS listener. Keep rejecting a missing/invalid Path for all other
      # initial requests; never fall back to the shared Service.
      if (!has_totag() && (!is_present_hf("Route") || !loose_route())) {
        if (is_method("INVITE") &&
            $(ru{uri.host}) == "SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}") {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_WARN",
            "SIPCORE FLOW stage=asterisk-invite-owner-uri-fallback pod=$env(POD_NAME) callid=$ci method=$rm ruri_host=$rd cseq=$hdr(CSeq)\n"
          );
          {{- end }}
        } else {
          if (!is_method("ACK")) sl_send_reply("404", "SIP Contact Owner Path Missing");
          exit;
        }
      }
      if (!has_totag()) {
        # During the migration window Asterisk may append its legacy shared
        # return proxy after the contact-specific Path. Path is first and
        # authoritative; discard only the residual Route set on initial
        # requests before resolving the live local Contact alias.
        remove_hf("Route");
      }
      {{- end }}

      $var(sipcore_dialog_routed) = 0;
      $var(sipcore_flow_token_result) = -1;
      $var(sipcore_loose_route_result) = 0;
      $var(sipcore_local_route_hops) = 0;
      $var(sipcore_alias_result) = 0;
      if (has_totag()) {
        $var(sipcore_flow_token_result) = check_flow_token();
        $var(sipcore_loose_route_result) = loose_route();
      }
      if ($var(sipcore_loose_route_result) > 0) {
        $var(sipcore_dialog_routed) = 1;
        $var(sipcore_local_route_hops) = 0;

        # A valid RFC 5626 flow token identifies the existing WebSocket
        # connection. Preserve it for t_relay instead of replacing it with a
        # Contact alias or another local Service hop.
        if ($var(sipcore_flow_token_result) != 1) {
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
            # Asterisk's outbound proxy and the dialog route set can repeat
            # this same internal return service. Once bounded cleanup reaches
            # that loop, use the saved Contact alias from the live
            # WebSocket connection and remove the stale local Route headers.
            handle_ruri_alias();
            $var(sipcore_alias_result) = $rc;
            if ($var(sipcore_alias_result) != 1) {
              {{- if .Values.kamailio.sipLogging.sipCore }}
              xlog(
                "L_ERR",
                "SIPCORE FLOW stage=asterisk-local-route-loop-failure pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) alias_result=$var(sipcore_alias_result) ruri_host=$rd ruri_port=$rp\n"
              );
              {{- end }}
              sl_send_reply("404", "WebSocket Contact Not Found");
              exit;
            }
            remove_hf("Route");
            {{- if .Values.kamailio.sipLogging.sipCore }}
            xlog(
              "L_WARN",
              "SIPCORE FLOW stage=asterisk-local-route-collapsed pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) local_route_hops=$var(sipcore_local_route_hops) destination_host=$dd destination_port=$dp destination_transport=$dP\n"
            );
            {{- end }}
          }
        }

        # A dialog without a valid flow token may use the nathelper Contact
        # alias. Resolve it only after local return-service routes are gone.
        if ($du == $null) {
          handle_ruri_alias();
          if ($rc != 1) {
            $var(sipcore_alias_result) = $rc;
            xlog(
              "L_ERR",
              "SIPCORE FLOW stage=asterisk-contact-route-failure pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) alias_result=$var(sipcore_alias_result) ruri_host=$rd ruri_port=$rp\n"
            );
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
          $var(sipcore_alias_result) = $rc;
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=asterisk-contact-route-failure pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) alias_result=$var(sipcore_alias_result) ruri_host=$rd ruri_port=$rp\n"
          );
          {{- end }}
          sl_send_reply("404", "WebSocket Contact Not Found");
          exit;
        }
        if (is_method("INVITE") && !has_totag()) {
          {{- if .Values.kamailio.websocketHA.enabled }}
          record_route_preset("SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
          {{- else }}
          record_route_preset("{{ $sipCoreReturnHost }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
          {{- end }}
        }
      }
      route(SIPCORE_CONTENT_TYPE);
      if ($var(sipcore_content_type) == "application/trickle-ice-sdpfrag" && has_body()) {
        if (!is_method("INFO")) {
          xlog("L_ERR", "SIPCORE FLOW stage=reject-trickle-fragment pod=$env(POD_NAME) callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl\n");
          if (!is_method("ACK")) sl_send_reply("488", "Trickle ICE Requires INFO");
          exit;
        }
        if (!rtpengine_info()) {
          xlog("L_ERR", "RTPEngine SIP Core Asterisk trickle ICE update failed callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl cseq=$hdr(CSeq) branch=trickle-ice status=503\n");
          sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
        xlog("L_INFO", "SIPCORE INFO callid=$ci cseq=$hdr(CSeq) method=$rm content_type=$cT branch=trickle-ice relay_result=consumed status=200\n");
        sl_send_reply("200", "OK");
        exit;
      }
      if (has_body("application/sdp")) {
        if (!($rb =~ "m=")) {
          xlog("L_ERR", "SIPCORE FLOW stage=reject-incomplete-sdp pod=$env(POD_NAME) callid=$ci method=$rm content_type=$hdr(Content-Type) body_bytes=$cl\n");
          if (!is_method("ACK")) sl_send_reply("488", "Incomplete SDP Offer");
          exit;
        }
        if (!rtpengine_manage("WebRTC replace-origin internal external address-family=IP4")) {
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
      xlog(
        "L_WARN",
        "SIPCORE FLOW stage=forward-to-websocket pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination_host=$dd destination_port=$dp destination_transport=$dP flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) cseq=$hdr(CSeq)\n"
      );
      {{- end }}
      route(PRIVATE_RELAY);
    }

    # has_body(type) compares MIME enum values in Kamailio 6.1.4: unknown
    # application subtypes (including DTMF and trickle ICE) compare equal.
    # Read the parsed header through $cT, strip MIME parameters and normalize
    # the media type as a string. Never use the MIME enum to identify ICE.
    # Call only after the listener and dialog/owner route checks above.
    route[SIPCORE_CONTENT_TYPE] {
      $var(sipcore_content_type) = "";
      if ($cT != $null) {
        $var(sipcore_content_type) = $(cT{s.select,0,;}{s.trim}{s.tolower});
      }
      $var(sipcore_info_branch) = "dialog";
      if (is_method("INFO")) {
        if ($var(sipcore_content_type) == "application/trickle-ice-sdpfrag" && has_body()) {
          $var(sipcore_info_branch) = "trickle-ice";
        } else if ($var(sipcore_content_type) == "application/dtmf-relay") {
          $var(sipcore_info_branch) = "dtmf-dialog";
        }
        xlog("L_INFO", "SIPCORE INFO callid=$ci cseq=$hdr(CSeq) method=$rm content_type=$cT branch=$var(sipcore_info_branch) from_tag=$ft to_tag=$tt\n");
      }
    }

    route[TO_SIPCORE_ASTERISK] {
      $du = "sip:{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}:5061;transport=tls";
      $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}";
      set_send_socket_name("private_tls");
    }

    # TM's transaction reply route is not invoked for retransmitted 2xx.
    # TOPOS still stores their Contact, so alias every browser response here
    # before TM can take that path. Otherwise a later unaliased 200 overwrites
    # the saved Contact and subsequent ACK/BYE requests cannot find the flow.
    # Keep this restricted to the established SIP Core WebSocket listener.
    reply_route {
      if ($proto == "ws" && $Rp == {{ $.Values.asterisk.sipCore.httpPort }} &&
          !is_method("REGISTER") && is_present_hf("Contact")) {
        if (add_contact_alias()) {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_INFO",
            "SIPCORE FLOW stage=asterisk-websocket-contact-aliased pod=$env(POD_NAME) callid=$ci method=$rm status=$rs cseq=$hdr(CSeq)\n"
          );
          {{- end }}
        } else {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=asterisk-websocket-contact-alias-failure pod=$env(POD_NAME) callid=$ci method=$rm status=$rs cseq=$hdr(CSeq)\n"
          );
          {{- end }}
        }
      }
      return;
    }

    onreply_route[SIPCORE_ASTERISK_REPLY] {
      {{- if .Values.kamailio.sipLogging.sipCore }}
      xlog(
        "L_WARN",
        "SIPCORE FLOW stage=asterisk-response pod=$env(POD_NAME) callid=$ci method=$rm status=$rs source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq) content_type=$cT branch=dialog-response\n"
      );
      {{- end }}
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      if ($rm == "INVITE" && $rs >= 200) {
        hlog("$ci", "kamailio_event=outbound_result component=private_sipcore stage=upstream_response call_id=$ci status=$rs method=$rm site={{ .Values.region }}");
      }
      {{- end }}
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin external internal address-family=IP4")) {
          xlog("L_ERR", "RTPEngine SIP Core outbound answer handling failed callid=$ci status=$rs\n");
          drop;
        }
      }
    }

    onreply_route[SIPCORE_WS_REPLY] {
      # Echo the trusted correlation alias in responses so Homer can assign
      # the same HEP CID to the internal dialog's reply records as to its
      # forwarded INVITE. SIP dialog identifiers and routing headers are not
      # modified.
      if (is_method("INVITE|ACK|BYE|CANCEL|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        remove_hf("X-Call-ID");
        append_hf("X-Call-ID: $ci\r\n");
      }
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      if ($rm == "REGISTER" && $rs >= 200) {
        $var(registration_decision) = "rejected";
        if ($rs == 401 || $rs == 407) $var(registration_decision) = "challenge";
        else if ($rs < 300) $var(registration_decision) = "accepted";
        hlog("$ci", "kamailio_event=registration_result component=kamailio stage=asterisk_response decision=$var(registration_decision) status=$rs extension=$fU site={{ .Values.region }} call_id=$ci");
      }
      {{- end }}
      {{- if .Values.kamailio.sipLogging.sipCore }}
      xlog(
        "L_WARN",
        "SIPCORE FLOW stage=websocket-response pod=$env(POD_NAME) callid=$ci method=$rm status=$rs source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt content_type=$cT branch=dialog-response\n"
      );
      {{- end }}
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin internal external address-family=IP4")) {
          xlog("L_ERR", "RTPEngine SIP Core WebSocket answer handling failed callid=$ci status=$rs\n");
          drop;
        }
      }
      # Only modify Contact on the REGISTER request sent to Asterisk. Its 2xx
      # response lists every binding for the AOR, not just this transaction;
      # rewriting those Contacts here loses each client's dynamic .invalid
      # host (and can produce the invalid URI sip:user@.invalid). Keep the
      # registrar's owner Contact URIs intact so each binding retains its own
      # routable owner and alias.
    }
    {{- end }}

    route[PRIVATE_RELAY] {
      if (is_method("BYE")) {
        # $var() values are request-local and may be empty once TM enters a
        # failure/reply route. Preserve the selected dialog path in XAVPs,
        # which are attached to the transaction, so teardown diagnostics can
        # identify the actual peer and next hop.
        $xavp(private_bye=>side) = $var(side);
        $xavp(private_bye=>peer) = $var(peer_name);
        $xavp(private_bye=>destination) = $du;
        $xavp(private_bye=>transport) = $dP;
        $xavp(private_bye=>socket) = $fsn;
        t_on_failure("PRIVATE_BYE_FAILURE");
        t_on_reply("PRIVATE_BYE_REPLY");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=call_teardown component=kamailio stage=private_bye_relay_attempt call_id=$ci method=BYE side=$var(side) peer=$var(peer_name) cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt site={{ .Values.region }}");
        {{- end }}
      }
      $var(private_relay_result) = t_relay();
      if ($var(side) == "sipcore" && is_method("INFO")) {
        xlog("L_INFO", "SIPCORE INFO relay callid=$ci cseq=$hdr(CSeq) method=$rm content_type=$cT branch=$var(sipcore_info_branch) relay_result=$var(private_relay_result)\n");
      }
      if ($var(private_relay_result) <= 0) {
        xlog(
          "L_ERR",
          "SIP relay result=failed tier=private pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=$var(peer_name) route=$route_uri next_hop=$du destination_host=$dd destination_port=$dp transport=$dP socket=$fsn t_relay_result=$var(private_relay_result)\n"
        );
        if ($var(side) == "sipcore" && $dP == "ws") {
        {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_WARN",
            "SIPCORE FLOW stage=websocket-flow-unavailable pod=$env(POD_NAME) callid=$ci method=$rm route=$route_uri next_hop=$du destination_host=$dd destination_port=$dp transport=$dP socket=$fsn cseq=$hdr(CSeq) response=430\n"
          );
        {{- end }}
          if (!is_method("ACK")) sl_send_reply("430", "WebSocket Flow Failed");
          exit;
        }
        {{- if .Values.kamailio.sipLogging.sipCore }}
        if ($var(side) == "sipcore") {
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=relay-failure pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination_host=$dd destination_port=$dp destination_transport=$dP socket=$fsn cseq=$hdr(CSeq)\n"
          );
        }
        {{- end }}
        if (!is_method("ACK")) sl_reply_error();
      } else {
        xlog(
          "L_INFO",
          "SIP relay result=queued tier=private pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=$var(peer_name) destination=$du transport=$dP socket=$fsn t_relay_result=$var(private_relay_result)\n"
        );
        if (is_method("BYE")) {
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=call_teardown component=kamailio stage=private_bye_relay_queued call_id=$ci method=BYE side=$var(side) peer=$var(peer_name) cseq=$hdr(CSeq) relay_result=$var(private_relay_result) site={{ .Values.region }}");
          {{- end }}
        }
      }
      exit;
    }

    {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
    onsend_route {
      if ($var(side) == "sipcore" && is_method("ACK|INFO")) {
        xlog("L_INFO", "SIPCORE wire callid=$ci cseq=$hdr(CSeq) method=$rm from_tag=$ft to_tag=$tt content_type=$cT destination=$snd(ip):$snd(port) transport=$snd(proto)\n");
      }
      if ($snd(buf) =~ "^BYE ") {
        xlog(
          "L_INFO",
          "SIP BYE wire attempt tier=private pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=BYE from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) connection_id=$conid transport=$snd(proto) local_socket=$sndfrom(proto):$sndfrom(ip):$sndfrom(port) socket_name=$fsn destination=$snd(ip):$snd(port)\n"
        );
      }
    }
    {{- end }}

    # Keep this failure route to pseudo-variables exported by the loaded core
    # and tm modules. TMX-specific $T_* fields require loading tmx.so.
    failure_route[PRIVATE_BYE_FAILURE] {
      $var(private_bye_timeout) = 0;
      $var(private_bye_received_reply) = 0;
      $var(private_bye_reply_code) = t_get_status_code();
      if (t_branch_timeout()) $var(private_bye_timeout) = 1;
      if (t_branch_replied()) $var(private_bye_received_reply) = 1;
      xlog(
        "L_ERR",
        "SIP relay failure stage=private-bye-transaction pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) side=$xavp(private_bye=>side) peer=$xavp(private_bye=>peer) destination=$xavp(private_bye=>destination) transport=$xavp(private_bye=>transport) socket=$xavp(private_bye=>socket) reply_code=$var(private_bye_reply_code) timed_out=$var(private_bye_timeout) received_reply=$var(private_bye_received_reply)\n"
      );
      {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
      hlog("$ci", "kamailio_event=call_teardown component=kamailio stage=private_bye_transaction_failure call_id=$ci method=BYE side=$xavp(private_bye=>side) peer=$xavp(private_bye=>peer) destination=$xavp(private_bye=>destination) transport=$xavp(private_bye=>transport) socket=$xavp(private_bye=>socket) reply_code=$var(private_bye_reply_code) timed_out=$var(private_bye_timeout) received_reply=$var(private_bye_received_reply) cseq=$hdr(CSeq) site={{ .Values.region }}");
      {{- end }}
    }

    onreply_route[PRIVATE_BYE_REPLY] {
      if ($rm == "BYE" && $rs >= 200) {
        xlog("L_INFO", "SIP dialog teardown stage=private-bye-response pod=$env(POD_NAME) callid=$ci status=$rs from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) side=$xavp(private_bye=>side) peer=$xavp(private_bye=>peer) destination=$xavp(private_bye=>destination) transport=$xavp(private_bye=>transport) socket=$xavp(private_bye=>socket)\n");
        {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
        hlog("$ci", "kamailio_event=call_teardown component=kamailio stage=private_bye_response call_id=$ci method=BYE status=$rs side=$xavp(private_bye=>side) peer=$xavp(private_bye=>peer) destination=$xavp(private_bye=>destination) transport=$xavp(private_bye=>transport) socket=$xavp(private_bye=>socket) cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt site={{ .Values.region }}");
        {{- end }}
      }
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
      $xavp(tls=>server_name) = "{{ include "avoip.sip.siteHost" . }}";
      set_send_socket_name("private_tls");
    }
    {{- end }}
{{- end -}}
