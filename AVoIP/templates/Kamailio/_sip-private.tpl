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
      {{- if .Values.asterisk.sipCore.tls.enabled }}
      # Public TLSRoute passthrough arrives with PROXY protocol v2; TLS and
      # SIP Digest remain end-to-end between the client and this Kamailio edge.
      if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.tls.port }}) {
        $var(side) = "sipcore";
        route(FROM_SIPCORE);
        exit;
      }
      {{- end }}
      # SIP Core WebSocket signaling has its own listener and handshake policy.
      if ($proto == "ws" && $Rp == {{ $.Values.asterisk.sipCore.httpPort }}) {
        $var(side) = "sipcore";
        {{- if .Values.kamailio.sipLogging.sipCore }}
        xlog(
          "L_WARN",
          "SIPCORE FLOW stage=frontend-wss-ingress pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt\n"
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
        xlog(
          "L_WARN",
          "Private SIP peer rejected pod=$env(POD_NAME) source=$si:$sp transport=$proto receive_port=$Rp tls_verified=$tls_peer_verified tls_peer_san=$tls_peer_san_hostname method=$rm callid=$ci\n"
        );
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
      {{- if .Values.kamailio.registrar.inboundPeerName }}
      # This mTLS peer is FreeSWITCH call control. It chooses which DID maps
      # to an extension; Kamailio only resolves that extension's live contact.
      if ($var(peer_name) == "{{ .Values.kamailio.registrar.inboundPeerName }}") {
        $var(registered_destination) = 0;
        {{- range .Values.kamailio.registrar.allowedUsers }}
        if ($rU == "{{ . }}") $var(registered_destination) = 1;
        {{- end }}
        if ($var(registered_destination) != 1 ||
            ($(ru{uri.host}) != "{{ .Values.kamailio.registrar.realm }}" &&
             $(ru{uri.host}) != "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" (include "avoip.kamailio.component" .Values.kamailio)) }}")) {
          sl_send_reply("403", "Destination Not Authorized");
          exit;
        }
        # Sofia's non-registering gateway may place the proxy service host
        # in the Request-URI. Normalize to the registrar's AoR domain before
        # the domain-aware subscriber and location lookups.
        $ru = "sip:" + $rU + "@{{ .Values.kamailio.registrar.realm }}";
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
      {{- end }}
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
        # Preserve the extension stamped on the authenticated FreeSWITCH
        # carrier leg. The carrier tier rechecks it against the Admin snapshot
        # before loading quota and strips it before the provider hop.
        remove_hf("Route"); remove_hf("P-Asserted-Identity"); remove_hf("X-Core-Original-DID");
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
      # This marker is only meaningful on the Cilium-restricted owner port.
      # A public client must never be able to select the owner-forward path.
      remove_hf("X-Core-Frontend-Owner-Forward");
      # Every front-end registration and initial client dialog must retain the
      # client flow through this Kamailio owner. TLS behind Envoy uses its actual
      # accepted peer tuple; other transports use the received source tuple.
      if (is_method("REGISTER") && is_present_hf("Contact") && $hdr(Contact) != "*") {
        {{- if .Values.asterisk.sipCore.tls.enabled }}
        if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.tls.port }}) {
          # PROXY v2 changes $si/$sp to the phone tuple. Store the actual
          # Envoy-to-Kamailio peer tuple so in-dialog TLS requests reuse the
          # accepted upstream connection instead of dialing the phone tuple.
          if (!add_contact_alias("$tcp(c_si)", "$tcp(c_sp)", "tls")) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog("L_INFO", "SIPCORE FLOW stage=frontend-contact-flow-aliased pod=$env(POD_NAME) callid=$ci method=$rm client=$si:$sp flow_peer=$tcp(c_si):$tcp(c_sp) transport=$proto cseq=$hdr(CSeq)\n");
          {{- end }}
        } else {
          if (!set_contact_alias("1")) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
        {{- else }}
        if (!set_contact_alias("1")) {
          sl_send_reply("400", "Bad Contact");
          exit;
        }
        {{- end }}
        {{- if .Values.asterisk.sipCore.tls.enabled }}
        }
        {{- end }}
        {{- if .Values.kamailio.sipLogging.sipCore }}
        xlog(
          "L_INFO",
          "SIPCORE FLOW stage=frontend-contact-aliased pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp transport=$proto cseq=$hdr(CSeq)\n"
        );
        {{- end }}
      } else if (!has_totag() && is_method("INVITE") && is_present_hf("Contact")) {
        {{- if .Values.asterisk.sipCore.tls.enabled }}
        if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.tls.port }}) {
          if (!add_contact_alias("$tcp(c_si)", "$tcp(c_sp)", "tls")) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
          # Keep the actual accepted socket ID on this owner, separate from
          # the redis-backed TOPOS dialog. It cannot move to another pod.
          $sht(sipcore_tls_dialog=>$ci) = $conid;
        } else {
          if (!set_contact_alias("1")) {
            sl_send_reply("400", "Bad Contact");
            exit;
          }
        }
        {{- else }}
        if (!set_contact_alias("1")) {
          sl_send_reply("400", "Bad Contact");
          exit;
        }
        {{- end }}
      }

      {{- if .Values.kamailio.registrar.enabled }}
      # The frontend terminates registration on its flow-owning pod. Never
      # forward credentials or Contact state to the legacy Asterisk registrar.
      if (is_method("REGISTER")) {
        route(PRIVATE_REGISTER);
        exit;
      }
      if (!has_totag() && !is_method("INVITE|OPTIONS|ACK|CANCEL")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }
      if (!has_totag() && is_method("INVITE")) {
        route(PRIVATE_AUTH_DEVICE);
        if ($var(auth_device) != 1) exit;
        # The identity passed to FreeSWITCH is the Digest username, never a
        # device-provided policy header or a caller-ID field. Media security
        # terminates on RTPEngine, so a client cannot select an internal media
        # profile either.
        remove_hf("X-Core-Extension");
        remove_hf("X-Core-Media-Profile");
        append_hf("X-Core-Extension: $au\r\n");
      }
      {{- end }}

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
      # A FreeSWITCH response Contact receives a nathelper alias for the exact
      # backend TLS peer. TOPOS restores that Contact on endpoint-originated
      # sequential requests. Consume the alias before any initial-request
      # backend selection so ACK, BYE, UPDATE, INFO, REFER and re-INVITE return
      # to the process/profile that owns the dialog.
      $var(sipcore_backend_alias_result) = 0;
      if (has_totag() && $du == $null) {
        handle_ruri_alias();
        $var(sipcore_backend_alias_result) = $rc;
        if ($var(sipcore_backend_alias_result) == 1) {
          set_send_socket_name("private_tls");
          xlog("L_INFO", "SIPCORE FLOW stage=frontend-dialog-backend-alias pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq) destination=$du socket=$fsn\n");
        }
      }
      # RFC 4028 does not permit a UAS minimum below 90 seconds.  The deployed
      # FreeSWITCH build retains its effective 120-second floor even when a
      # lower profile value is rendered. Some browser clients offer a
      # 60-second Session-Expires and do not retry a 422 response. Normalize
      # only that too-short initial offer on the trusted internal call-control
      # hop; retain any refresher parameter and leave valid offers unchanged.
      # This is policy negotiation, not a synthetic INVITE or a dialog-specific
      # exception.
      if (!has_totag() && is_method("INVITE") &&
          is_present_hf("Session-Expires") &&
          $hdr(Session-Expires) =~ "^(1[01][0-9]|[1-9][0-9]|[0-9])([;[:space:]]|$)") {
        $var(sipcore_original_session_expires) = $hdr(Session-Expires);
        if (!subst_hf("Session-Expires", "/^[0-9][0-9]*/120/", "a")) {
          xlog("L_ERR", "SIPCORE FLOW stage=session-timer-normalization-failed pod=$env(POD_NAME) callid=$ci method=$rm original=$var(sipcore_original_session_expires)\\n");
          sl_send_reply("500", "Session Timer Policy Failure");
          exit;
        }
        xlog("L_INFO", "SIPCORE FLOW stage=session-timer-normalized pod=$env(POD_NAME) callid=$ci method=$rm original=$var(sipcore_original_session_expires) normalized=$hdr(Session-Expires)\\n");
      }
      {{- if .Values.kamailio.websocketHA.enabled }}
      if (has_totag() && $du != $null &&
          $(du{uri.host}) =~ "^{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}-[0-9]+\\." &&
          $(du{uri.host}) != "SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}") {
        # TOPOS restored the owner RR on a different frontend replica. The
        # receiving owner resumes normal client-side routing on port 5063.
        append_hf("X-Core-Frontend-Owner-Forward: 1\r\n");
        set_send_socket_name("sipcore_owner_tls");
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-owner-hop pod=$env(POD_NAME) callid=$ci method=$rm owner=$dd cseq=$hdr(CSeq)\n");
        route(PRIVATE_RELAY);
      }
      {{- end }}
      # An inbound FreeSWITCH-to-registrar dialog restores the endpoint
      # leg's Contact, including the owning pod and Sofia profile port. Keep
      # the established dialog on that pod: the FreeSWITCH Service may select
      # a different replica whose local Sofia state does not contain the call.
      if (has_totag() && $du == $null &&
          ($hdr(Route) =~ "{{ $.Values.asterisk.sipCore.hostname }}:{{ $.Values.asterisk.sipCore.tls.gatewayPort }}" ||
           $(ru{uri.host}) == "{{ $.Values.asterisk.sipCore.hostname }}") &&
          $rd =~ "^[0-9.]+$" &&
          ($rp == {{ $.Values.freeswitch.publicExposure.kamailio.backendPort }} || $rp == 5072)) {
        $du = "sips:" + $rd + ":" + $rp + ";transport=tls";
        $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}";
        set_send_socket_name("private_tls");
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-dialog-backend-owner-route pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq) backend_ip=$rd backend_port=$rp destination=$du socket=$fsn\n");
      } else if (has_totag() && $du == $null &&
                 ($hdr(Route) =~ "{{ $.Values.asterisk.sipCore.hostname }}:{{ $.Values.asterisk.sipCore.tls.gatewayPort }}" ||
                  $(ru{uri.host}) == "{{ $.Values.asterisk.sipCore.hostname }}") &&
                 $rp == {{ $.Values.freeswitch.publicExposure.kamailio.backendPort }}) {
        $du = "sips:{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}:5072;transport=tls";
        $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}";
        set_send_socket_name("private_tls");
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-dialog-backend-service-fallback pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq) destination=$du socket=$fsn ruri=$ru route=$hdr(Route)\n");
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
        # RTPEngine is the public media-security boundary. It terminates the
        # endpoint's ICE, DTLS-SRTP or SDES leg and presents one independent,
        # hidden RTP/AVP leg to FreeSWITCH. Never propagate endpoint candidates
        # or cryptographic attributes through the internal Kamailio hop.
        $var(sipcore_media_flags) = "RTP/AVP ICE=remove DTLS=off SDES=off rtcp-mux-demux replace-origin external internal address-family=IP4";
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
        {{- if .Values.kamailio.sipLogging.sipCore }}
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-offer-media-applied pod=$env(POD_NAME) callid=$ci method=$rm transport=$proto flags=$var(sipcore_media_flags) cseq=$hdr(CSeq)\n");
        {{- end }}
        if ($var(sipcore_managed_codec_flags) != $null && $var(sipcore_managed_codec_flags) != "") {
          {{- if and .Values.kamailio.functions.sipTrace (include "avoip.homer.enabled" . | trim) }}
          hlog("$ci", "kamailio_event=rtpengine_codec_policy decision=applied direction=outbound extension=$hdr(X-Core-Extension) stage=asterisk_sdp_offer flags=$var(sipcore_managed_codec_flags) call_id=$ci");
          {{- end }}
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }
      {{- if and .Values.kamailio.websocketHA.enabled (not .Values.kamailio.registrar.enabled) }}
      route(TO_SIPCORE_ASTERISK);
      if (is_method("REGISTER")) {
        # PJSIP_DIAL_CONTACTS() sends the stored Contact URI directly, so a
        # browser's randomized .invalid host cannot be resolved by Asterisk.
        # Give each registration the receiving StatefulSet pod's stable owner
        # hostname; keep the Contact alias so the owner can find its live WS
        # flow when the INVITE returns. The matching Path remains owner-pod
        # addressed for path-aware AOR requests.
        if ($proto == "ws") {
          if (is_present_hf("Contact") && $hdr(Contact) != "*" &&
              !subst_hf("Contact", "/@[^;>; ]+;transport=ws/@SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls/ig", "a")) {
            sl_send_reply("400", "Unsupported WebSocket Contact");
            exit;
          }
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
        {{- if .Values.asterisk.sipCore.tls.enabled }}
        if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.tls.port }}) {
          # The first RR is the internal outbound/owner leg; the second is
          # the client-facing TLS leg. TOPOS uses the latter for its masked
          # response Contact and retains the former for dialog restoration.
          record_route_preset(
            "SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr;r2=on",
            "{{ $.Values.asterisk.sipCore.hostname }}:{{ $.Values.asterisk.sipCore.tls.gatewayPort }};transport=tls;lr;r2=on"
          );
        } else {
        {{- end }}
        record_route_preset("SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
        {{- if .Values.asterisk.sipCore.tls.enabled }}
        }
        {{- end }}
        {{- else }}
        record_route_preset("{{ $sipCoreReturnHost }}:{{ $.Values.asterisk.sipCore.privateEgressPort }};transport=tls;lr");
        {{- end }}
      }
      {{- if .Values.kamailio.registrar.enabled }}
      if (!has_totag() && is_method("INVITE")) {
        $du = "sips:{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}:5072;transport=tls";
        $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "freeswitch") }}";
        set_send_socket_name("private_tls");
      } else if (!has_totag() && is_method("OPTIONS")) {
        sl_send_reply("200", "Keepalive");
        exit;
      }
      {{- else }}
      route(TO_SIPCORE_ASTERISK);
      {{- end }}
      {{- if .Values.kamailio.sipLogging.sipCore }}
      xlog(
        "L_WARN",
        "SIPCORE FLOW stage={{ if .Values.kamailio.registrar.enabled }}forward-to-call-control{{ else }}forward-to-asterisk{{ end }} pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt content_type=$cT\n"
      );
      {{- end }}
      route(PRIVATE_RELAY);
    }

    route[FROM_SIPCORE_ASTERISK] {
      {{- if .Values.kamailio.websocketHA.enabled }}
      if ($hdr(X-Core-Frontend-Owner-Forward) eq "1") {
        remove_hf("X-Core-Frontend-Owner-Forward");
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-owner-received pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq)\n");
        route(FROM_SIPCORE);
        exit;
      }
      {{- end }}
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
              sl_send_reply("404", "Frontend Contact Not Found");
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
          $var(sipcore_alias_result) = $rc;
          if ($rc != 1) {
            xlog(
              "L_ERR",
              "SIPCORE FLOW stage=asterisk-contact-route-failure pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) alias_result=$var(sipcore_alias_result) ruri_host=$rd ruri_port=$rp\n"
            );
            sl_send_reply("404", "Frontend Contact Not Found");
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
        $var(sipcore_alias_result) = $rc;
        if ($rc != 1) {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=asterisk-contact-route-failure pod=$env(POD_NAME) callid=$ci method=$rm flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) alias_result=$var(sipcore_alias_result) ruri_host=$rd ruri_port=$rp\n"
          );
          {{- end }}
          sl_send_reply("404", "Frontend Contact Not Found");
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
      {{- if .Values.asterisk.sipCore.tls.enabled }}
      # PROXY v2 reports the phone in $si/$sp, while the accepted TLS socket
      # belongs to Envoy's real peer. handle_ruri_alias() only sets $du;
      # without otcpid Kamailio may dial Envoy's ephemeral source port.
      if ($var(sipcore_alias_result) == 1 && $dP == "tls" && $du != $null) {
        # Build the peer from runtime pseudo-variables. Quoting "$dd:$dp"
        # leaves those tokens literal for tcp_get_conid() to resolve.
        $var(sipcore_flow_peer) = $dd + ":" + $dp;
        $var(sipcore_flow_conid) = 0;
        if (!tcp_get_conid("$var(sipcore_flow_peer)", "$var(sipcore_flow_conid)") ||
            !tcp_conid_alive("$var(sipcore_flow_conid)")) {
          xlog("L_WARN", "SIPCORE FLOW stage=tls-owner-flow-gone pod=$env(POD_NAME) callid=$ci method=$rm peer=$var(sipcore_flow_peer) cseq=$hdr(CSeq) response=430\n");
          if (!is_method("ACK")) sl_send_reply("430", "TLS Flow Failed");
          exit;
        }
        if (has_totag()) {
          if ($sht(sipcore_tls_dialog=>$ci) == $null ||
              $sht(sipcore_tls_dialog=>$ci) ine $var(sipcore_flow_conid)) {
            xlog("L_WARN", "SIPCORE FLOW stage=tls-dialog-flow-mismatch pod=$env(POD_NAME) callid=$ci method=$rm candidate_connection_id=$var(sipcore_flow_conid) cseq=$hdr(CSeq) response=430\n");
            if (!is_method("ACK")) sl_send_reply("430", "TLS Dialog Flow Gone");
            exit;
          }
        } else if (is_method("INVITE")) {
          $sht(sipcore_tls_dialog=>$ci) = $var(sipcore_flow_conid);
        }
        if (!tcp_set_otcpid("$var(sipcore_flow_conid)")) {
          xlog("L_ERR", "SIPCORE FLOW stage=tls-owner-flow-select-failed pod=$env(POD_NAME) callid=$ci method=$rm connection_id=$var(sipcore_flow_conid) cseq=$hdr(CSeq)\n");
          if (!is_method("ACK")) sl_send_reply("430", "TLS Flow Failed");
          exit;
        }
        tcp_set_otcpid_flag(1);
        xlog("L_INFO", "SIPCORE FLOW stage=tls-owner-flow-selected pod=$env(POD_NAME) callid=$ci method=$rm connection_id=$var(sipcore_flow_conid) peer=$var(sipcore_flow_peer) cseq=$hdr(CSeq)\n");
      }
      {{- end }}
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
        $var(sipcore_backend_offer_flags) = "replace-origin internal external address-family=IP4";
        # The resolved Contact alias identifies the endpoint transport. Only
        # the browser-facing copy receives ICE and DTLS-SRTP; native SIP/TLS
        # remains a separate RTPEngine-anchored media association.
        if ($dP == "ws") {
          $var(sipcore_backend_offer_flags) = "WebRTC " + $var(sipcore_backend_offer_flags);
        }
        if (!rtpengine_manage("$var(sipcore_backend_offer_flags)")) {
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
        "SIPCORE FLOW stage=forward-to-frontend pod=$env(POD_NAME) callid=$ci method=$rm source=$si:$sp destination_host=$dd destination_port=$dp destination_transport=$dP flow_token_result=$var(sipcore_flow_token_result) loose_route_result=$var(sipcore_loose_route_result) local_route_hops=$var(sipcore_local_route_hops) cseq=$hdr(CSeq)\n"
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
    # Responses to client-originated calls arrive on the internal signaling
    # socket, not the client listener. Classify that listener directly and use
    # the final Via for the endpoint transport after TOPOS hides Record-Route.
    reply_route {
      $var(sipcore_client_reply) = 0;
      if (($proto == "tls" && $Rp == 5062) ||
          $(hfl(Via)[-1]) =~ "^SIP/2.0/WSS") {
        $var(sipcore_client_reply) = 1;
      }
      if ($var(sipcore_client_reply) == 1 &&
          !is_method("REGISTER") && is_present_hf("Contact")) {
        if (set_contact_alias("1")) {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_INFO",
            "SIPCORE FLOW stage=backend-contact-aliased pod=$env(POD_NAME) callid=$ci method=$rm status=$rs cseq=$hdr(CSeq)\n"
          );
          {{- end }}
        } else {
          {{- if .Values.kamailio.sipLogging.sipCore }}
          xlog(
            "L_ERR",
            "SIPCORE FLOW stage=backend-contact-alias-failure pod=$env(POD_NAME) callid=$ci method=$rm status=$rs cseq=$hdr(CSeq)\n"
          );
          {{- end }}
        }
      }
      # Process each *wire copy* of an answer once, including late 2xx that
      # bypass TM onreply_route. RTPEngine reuses the existing Call-ID/tag
      # session; no extra offer is created for retransmissions.
      if ($var(sipcore_client_reply) == 1 && has_body("application/sdp")) {
        $var(sipcore_answer_flags) = "replace-origin internal external address-family=IP4";
        # The final Via is the endpoint-facing transport even after TOPOS has
        # hidden Record-Route. This keeps first and retransmitted answers on
        # the same media policy without relying on transaction-local state.
        if ($(hfl(Via)[-1]) =~ "^SIP/2.0/WSS") {
          $var(sipcore_answer_flags) = "WebRTC " + $var(sipcore_answer_flags);
        }
        if (!rtpengine_manage("$var(sipcore_answer_flags)")) {
          xlog("L_ERR", "SIPCORE FLOW stage=frontend-answer-media-failed pod=$env(POD_NAME) callid=$ci status=$rs cseq=$hdr(CSeq)\n");
          drop;
        }
        $var(sipcore_answer_processed) = 1;
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-answer-media-applied pod=$env(POD_NAME) callid=$ci status=$rs cseq=$hdr(CSeq) transport=$proto\n");
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
        if (!rtpengine_manage("RTP/AVP ICE=remove DTLS=off SDES=off rtcp-mux-demux replace-origin external internal address-family=IP4")) {
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
        "SIPCORE FLOW stage=frontend-response pod=$env(POD_NAME) callid=$ci method=$rm status=$rs source=$si:$sp recv=$Ri:$Rp/$proto cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt content_type=$cT branch=dialog-response\n"
      );
      {{- end }}
      # The configured internal Service can return the first transaction
      # response through the frontend TLS listener. Process that response in
      # TM's callback when the core reply route could not classify it. The
      # core route remains authoritative for retransmitted 2xx responses,
      # which can bypass this callback.
      if (has_body("application/sdp") &&
          $Rp != 5062 &&
          !($(hfl(Via)[-1]) =~ "^SIP/2.0/WSS")) {
        $var(sipcore_answer_flags) = "replace-origin internal external address-family=IP4";
        if ($(hfl(Via)[-1]) =~ "^SIP/2.0/WSS") {
          $var(sipcore_answer_flags) = "WebRTC " + $var(sipcore_answer_flags);
        }
        if (!rtpengine_manage("$var(sipcore_answer_flags)")) {
          xlog("L_ERR", "SIPCORE FLOW stage=frontend-answer-media-failed pod=$env(POD_NAME) callid=$ci status=$rs cseq=$hdr(CSeq) callback=tm\n");
          drop;
        }
        xlog("L_INFO", "SIPCORE FLOW stage=frontend-answer-media-applied pod=$env(POD_NAME) callid=$ci status=$rs cseq=$hdr(CSeq) transport=$proto callback=tm\n");
      }
      # Media is rewritten in reply_route for initial and retransmitted 2xx.
      # Only modify Contact on the REGISTER request sent to Asterisk. Its 2xx
      # response lists every binding for the AOR, not just this transaction;
      # rewriting those Contacts here loses each client's dynamic .invalid
      # host (and can produce the invalid URI sip:user@.invalid). Keep the
      # registrar's owner Contact URIs intact so each binding retains its own
      # routable owner and alias.
    }
    {{- end }}

    route[PRIVATE_RELAY] {
      # Shared usrloc can contain legacy WebSocket Contacts whose browser
      # hostname is intentionally non-resolvable (*.invalid). Resolve the
      # nathelper alias on the final relay boundary so an inbound branch uses
      # the live flow even before that client refreshes its registration with
      # the owner Contact form. This is only accepted for the trusted SIP Core
      # side and only for the synthetic .invalid host; ordinary SIP targets
      # retain their normal DNS/transport behavior.
      if (($var(side) eq "sipcore" || $var(peer_name) eq "freeswitch-registrar") &&
          $du == $null && $(ru{uri.host}) =~ "\\.invalid$") {
        handle_ruri_alias();
        if ($rc == 1) {
          xlog("L_INFO", "SIPCORE FLOW stage=websocket-alias-resolved pod=$env(POD_NAME) callid=$ci method=$rm ruri=$ru destination=$du transport=$dP socket=$fsn cseq=$hdr(CSeq)\n");
        } else {
          xlog("L_WARN", "SIPCORE FLOW stage=websocket-alias-unavailable pod=$env(POD_NAME) callid=$ci method=$rm ruri=$ru destination=$du transport=$dP socket=$fsn cseq=$hdr(CSeq)\n");
        }
      }
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
      if ($var(side) eq "sipcore" && is_method("INFO")) {
        xlog("L_INFO", "SIPCORE INFO relay callid=$ci cseq=$hdr(CSeq) method=$rm content_type=$cT branch=$var(sipcore_info_branch) relay_result=$var(private_relay_result)\n");
      }
      if ($var(private_relay_result) <= 0) {
        xlog(
          "L_ERR",
          "SIP relay result=failed tier=private pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=$rm from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) direction=$var(peer_name) route=$route_uri next_hop=$du destination_host=$dd destination_port=$dp transport=$dP socket=$fsn t_relay_result=$var(private_relay_result)\n"
        );
        if ($var(side) eq "sipcore" && $dP eq "ws") {
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
        if ($var(side) eq "sipcore") {
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
      if ($var(side) eq "sipcore" && is_method("ACK|INFO")) {
        xlog("L_INFO", "SIPCORE wire callid=$ci cseq=$hdr(CSeq) method=$rm from_tag=$ft to_tag=$tt content_type=$cT destination=$snd(ip):$snd(port) transport=$snd(proto)\n");
      }
      if ($snd(buf) =~ "^BYE ") {
        xlog(
          "L_INFO",
          "SIP BYE wire attempt tier=private pod=$env(POD_NAME) callid=$ci linkedid=$hdr(X-Core-Call-Linkedid) origin_uniqueid=$hdr(X-Core-Origin-Uniqueid) method=BYE from_tag=$ft to_tag=$tt cseq=$hdr(CSeq) incoming_connection_id=$conid active_connection_id=$tcp(aconid) transport=$snd(proto) local_socket=$sndfrom(proto):$sndfrom(ip):$sndfrom(port) socket_name=$fsn destination=$snd(ip):$snd(port)\n"
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
      if (($var(side) eq "sipcore" &&
           !(($proto == "tls" && $Rp == {{ .Values.asterisk.sipCore.tls.port }}) ||
             ($proto == "ws" && $Rp == {{ .Values.asterisk.sipCore.httpPort }}))) ||
          ($var(side) ne "sipcore" && $var(peer_name) ne "{{ .Values.kamailio.registrar.accessPeerName }}") ||
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
      # Never trust a device-supplied Path. DB-only usrloc is shared among HA
      # pods, but the live TLS/WS connection belongs to this StatefulSet pod.
      remove_hf("Path");
      {{- if .Values.kamailio.websocketHA.enabled }}
      if ($var(side) eq "sipcore") {
        # Some SIP/WebSocket clients do not advertise RFC 3327 Path support.
        # Keep their opaque Contact alias, but replace the non-routable browser
        # host with this registration pod's owner listener. The owner listener
        # consumes the alias and writes the request to the existing local WS
        # flow; it is not a new client connection or a fixed pod affinity rule.
        if ($proto == "ws" && is_present_hf("Contact") && $hdr(Contact) != "*") {
          if (!subst_hf("Contact", "/@[^;>; ]+/@SIPCORE_OWNER_POD.{{ include "avoip.kamailio.resourceName" (dict "root" $ "instance" .Values.kamailio "suffix" "owner") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.asterisk.sipCore.privateEgressPort }}/ig", "a") ||
              !subst_hf("Contact", "/;transport=ws/;transport=tls/ig", "a")) {
            sl_send_reply("400", "Unsupported WebSocket Contact");
            exit;
          }
          xlog("L_INFO", "SIPCORE FLOW stage=registrar-owner-contact pod=$env(POD_NAME) callid=$ci method=REGISTER contact=$hdr(Contact) transport=$proto cseq=$hdr(CSeq)\n");
        }
        # Build the owner route through path.so instead of appending a raw
        # header. The registrar stores Path only when the path module has
        # created the header on the selected advertised socket. Without that
        # metadata lookup("location") falls back to a browser's randomized
        # .invalid Contact host and never reaches the live WebSocket flow.
        # Advertise Path support on behalf of the proxy-generated owner route;
        # some registrar builds otherwise discard the Path lump during save()
        # even when registrar.path_mode is configured for lazy storage.
        append_hf("Supported: path\r\n");
        set_send_socket_name("sipcore_owner_tls");
        if (!add_path()) {
          sl_send_reply("503", "SIP Owner Path Unavailable");
          exit;
        }
      }
      {{- end }}
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
      # The frontend has consumed this Digest challenge. Never pass the
      # device's Proxy-Authorization to FreeSWITCH's trusted ingress profile;
      # it is a separate authentication realm and security boundary.
      consume_credentials();
      # A phone can include credentials for other realms on the same INVITE.
      # None of them belong on the trusted FreeSWITCH leg either.
      remove_hf("Authorization");
      remove_hf("Proxy-Authorization");
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
