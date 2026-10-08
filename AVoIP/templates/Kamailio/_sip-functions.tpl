{{- define "avoip.kamailio.sip.media" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
    {{- if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) .Values.freeswitch.enabled }}
    modparam(
      "rtpengine",
      "rtpengine_sock",
      "udp:{{ $fullName }}-rtpengine.{{ $.Release.Namespace }}.svc.{{ default "cluster.local" $.Values.cluster.domain }}:{{ $.Values.rtpengine.controlPort }}"
    )
    modparam(
      "rtpengine",
      "rtpengine_disable_tout",
      {{ .Values.rtpengine.recovery.disableTimeoutSeconds }}
    )
    modparam(
      "rtpengine",
      "aggressive_redetection",
      {{ if .Values.rtpengine.recovery.aggressiveRedetection }}1{{ else }}0{{ end }}
    )
    modparam(
      "rtpengine",
      "ping_interval",
      {{ .Values.rtpengine.recovery.pingIntervalSeconds }}
    )

    route[MEDIA_INITIAL] {
      if (!has_body("application/sdp")) {
        return;
      }

      if (!rtpengine_manage("replace-origin external internal")) {
        xlog(
          "L_ERR",
          "RTPEngine initial SDP handling failed callid=$ci method=$rm source=$si:$sp\n"
        );
        sl_send_reply("503", "Media Relay Unavailable");
        exit;
      }
    }

    route[MEDIA_DIALOG] {
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("replace-origin")) {
          xlog(
            "L_ERR",
            "RTPEngine dialog SDP handling failed callid=$ci method=$rm source=$si:$sp\n"
          );

          if (!is_method("ACK")) {
            sl_send_reply("488", "Media Relay Unavailable");
          }

          exit;
        }
      } else if (is_method("BYE|CANCEL")) {
        rtpengine_manage();
      }
    }
    {{- end }}

{{ end }}

{{- define "avoip.kamailio.sip.sanityAndClassification" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
{{- $sipCoreEnabled := and (eq .Values.kamailio.role "carrier-sbc") $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled -}}
    request_route {
      if (is_method("ACK")) {
        xlog(
          "L_INFO",
          "SIP ACK INGRESS pod=$env(POD_NAME) source=$si:$sp recv_socket=$Rn/$Ri:$Rp proto=$proto ruri=$ru route=$hdr(Route) call_id=$ci cseq=$hdr(CSeq) from_tag=$ft to_tag=$tt\n"
        );
      }

      if (!sanity_check("1511", "7")) {
        xlog(
          "L_WARN",
          "SIP reject reason=malformed pod=$env(POD_NAME) method=$rm source=$si:$sp callid=$ci\n"
        );
        exit;
      }

      if (!mf_process_maxfwd_header("10")) {
        if (!is_method("ACK")) {
          sl_send_reply("483", "Too Many Hops");
        }
        exit;
      }

      {{- if $sipCoreEnabled }}
      # SIP Core arrives only on the dedicated WebSocket listener. The HTTP
      # handshake has already enforced the configured origin list. PJSIP's
      # endpoint Digest object remains the authentication authority.
      if ($proto == "ws" && $Rp == {{ $.Values.asterisk.sipCore.httpPort }}) {
        $var(side) = "sipcore";
        route(FROM_SIPCORE);
        exit;
      }
      # The dedicated private listener is exposed only to Asterisk pods by
      # the SIP Core NetworkPolicy rule below. It routes responses to the
      # live WebSocket contacts without treating either pod IP as identity.
      if ($proto == "tls" && $Rp == {{ $.Values.asterisk.sipCore.privateEgressPort }}) {
        route(FROM_SIPCORE_ASTERISK);
        exit;
      }
      {{- end }}

      {{- if .Values.kamailio.carrierOutbound.enabled }}
      # Internal outbound uses the existing Envoy SIPS entry, which supplies
      # PROXY v2. The dedicated SNI profile requires a client certificate.
      if ($proto == "tls" && $Rp == 5061 &&
          src_ip == {{ .Values.kamailio.carrierOutbound.peer.cidr }} &&
          $tls_peer_verified == 1 &&
          $tls_peer_san_hostname == "{{ .Values.kamailio.carrierOutbound.peer.sanHostname }}") {
        $var(side) = "internal-outbound";
        route(FROM_OUTBOUND_PEER);
        exit;
      }
      {{- end }}

      #
      # Carrier-facing trust boundary.
      #
      if (
        ($proto == "tls" && $Rp == 5061) ||
        ($proto == "udp" && $Rp == 5060) ||
        ($proto == "tcp" && $Rp == 5060)
      ) {
        {{- range .Values.flowroute.signalingCIDRs }}
        if (src_ip == {{ . }}) {
          $var(side) = "carrier";
          {{- if $carrierTrafficLogging }}
          xlog(
            "L_INFO",
            "SIP FLOWROUTE RX pod=$env(POD_NAME) source=$si:$sp recv=$Ri:$Rp proto=$proto callid=$ci method=$rm cseq=$hdr(CSeq)\n--- SIP FLOWROUTE RX BEGIN ---\n$mb\n--- SIP FLOWROUTE RX END ---\n"
          );
          {{- end }}
          # CANCEL belongs to the INVITE transaction in TM's local process.
          # TOPOS Redis does not replicate TM state: the same TLS connection
          # must remain pinned by the L4 gateway to the pod holding that
          # transaction. A CANCEL arriving on another pod correctly misses.
          if (is_method("CANCEL")) {
            {{- if $.Values.kamailio.carrierOutbound.enabled }}
            route(OUTBOUND_RELEASE);
            {{- end }}
            {{- if and $.Values.kamailio.functions.media (include "avoip.rtpengine.enabled" $ | trim) $.Values.freeswitch.enabled }}
            rtpengine_manage();
            {{- end }}
            $var(cancel_result) = t_relay_cancel();
            if ($var(cancel_result) > 0) {
              sl_send_reply("481", "Call Does Not Exist");
            } else if ($var(cancel_result) < 0) {
              sl_reply_error();
            }
            exit;
          }
          route(FROM_CARRIER);
          exit;
        }
        {{- end }}
      }

      #
      # Internal application-facing trust boundary.
      #
      if (
        $proto == "tls" &&
        $Rp == 5062 &&
        src_ip == {{ .Values.kamailio.backend.podCIDR }}
      ) {
        $var(side) = "backend";
        if (is_method("CANCEL")) {
          {{- if .Values.kamailio.carrierOutbound.enabled }}
          route(OUTBOUND_RELEASE);
          {{- end }}
          {{- if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) $.Values.freeswitch.enabled }}
          rtpengine_manage();
          {{- end }}
          $var(cancel_result) = t_relay_cancel();
          if ($var(cancel_result) > 0) {
            sl_send_reply("481", "Call Does Not Exist");
          } else if ($var(cancel_result) < 0) {
            sl_reply_error();
          }
          exit;
        }
        route(FROM_BACKEND);
        exit;
      }

      xlog(
        "L_WARN",
        "SIP reject reason=source-or-socket pod=$env(POD_NAME) method=$rm source=$si:$sp recv=$Ri:$Rp proto=$proto callid=$ci\n"
      );

      if (!is_method("ACK")) {
        sl_send_reply("403", "Source Not Authorized");
      }

      exit;
    }

    {{- if $sipCoreEnabled }}
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
        if ($var(cancel_result) > 0) {
          sl_send_reply("481", "Call Does Not Exist");
        } else if ($var(cancel_result) < 0) {
          sl_reply_error();
        }
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
        if (!msg_apply_changes()) {
          xlog("L_ERR", "RTPEngine SIP Core SDP update failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("488", "Media Relay Unavailable");
          exit;
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }

      if (is_method("INVITE") && !has_totag()) {
        record_route_preset("sip:{{ $.Values.asterisk.sipCore.hostname }}:443;transport=wss");
      }

      route(TO_SIPCORE_ASTERISK);
      route(RELAY);
      exit;
    }

    route[FROM_SIPCORE_ASTERISK] {
      if (!is_method("INVITE|ACK|BYE|CANCEL|OPTIONS|UPDATE|INFO|PRACK|REFER|NOTIFY")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      if (is_method("CANCEL")) {
        $var(cancel_result) = t_relay_cancel();
        if ($var(cancel_result) > 0) {
          sl_send_reply("481", "Call Does Not Exist");
        } else if ($var(cancel_result) < 0) {
          sl_reply_error();
        }
        exit;
      }

      $var(sipcore_dialog_routed) = 0;
      if (has_totag() && loose_route()) {
        $var(sipcore_dialog_routed) = 1;
      }
      if ($var(sipcore_dialog_routed) != 1) {
        if (is_method("INVITE|OPTIONS")) {
          $var(sipcore_target_allowed) = 0;
          {{- range $.Values.asterisk.sipCore.extensions }}
          if ($tU == "{{ .number }}") $var(sipcore_target_allowed) = 1;
          {{- end }}
          if ($var(sipcore_target_allowed) != 1) {
            sl_send_reply("403", "SIP Core Target Not Allowed");
            exit;
          }
        }

        handle_ruri_alias();
        if ($rc != 1) {
          sl_send_reply("404", "WebSocket Contact Not Found");
          exit;
        }

        if (is_method("INVITE") && !has_totag()) {
          record_route_preset("sip:{{ $.Values.asterisk.sipCore.hostname }}:443;transport=wss");
        }
      }

      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin internal external")) {
          xlog("L_ERR", "RTPEngine SIP Core outbound SDP handling failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("503", "Media Relay Unavailable");
          exit;
        }
        if (!msg_apply_changes()) {
          xlog("L_ERR", "RTPEngine SIP Core outbound SDP update failed callid=$ci method=$rm\n");
          if (!is_method("ACK")) sl_send_reply("488", "Media Relay Unavailable");
          exit;
        }
      } else if (is_method("BYE")) {
        rtpengine_manage();
      }

      t_on_reply("SIPCORE_ASTERISK_REPLY");
      route(RELAY);
      exit;
    }

    onreply_route[SIPCORE_ASTERISK_REPLY] {
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("WebRTC replace-origin external internal")) {
          xlog("L_ERR", "RTPEngine SIP Core outbound answer handling failed callid=$ci status=$rs\n");
          drop;
        }
        if (!msg_apply_changes()) {
          xlog("L_ERR", "RTPEngine SIP Core outbound answer update failed callid=$ci status=$rs\n");
          drop;
        }
      }
    }

    onreply_route[SIPCORE_WS_REPLY] {
      if (nat_uac_test(64) && is_present_hf("Contact")) {
        add_contact_alias();
      }
    }
    {{- end }}

{{ end }}

{{- define "avoip.kamailio.sip.authorizationAndTransactions" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
    route[FROM_CARRIER] {
      force_rport();

      {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
      if (is_method("INVITE|ACK|BYE|CANCEL|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        xlog(
          "L_INFO",
          "SIP request call_id=$ci method=$rm status=$rs direction=carrier recv_socket=$Ri:$Rp/$proto send_socket=$fsn source_ip=$si destination_ip=$du route_uri=$route_uri ruri=$ru topos_result=module-managed dialog_direction=carrier cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}

      if (is_method("REGISTER")) {
        sl_send_reply("403", "Registration Disabled");
        exit;
      }

      if (is_method("OPTIONS")) {
        sl_send_reply("200", "Keepalive");
        exit;
      }

      # A 2xx ACK is a separate transaction. Route-set/TOPOS processing must
      # happen before any transaction-only handling.
      if (has_totag()) {
        # A non-2xx ACK has a To-tag but no dialog Route/Contact token. Only
        # that shape may use INVITE transaction matching; a 2xx ACK continues
        # through ordinary TOPOS dialog routing below.
        if (is_method("ACK") && !is_present_hf("Route") && $(ru{uri.param,tps}) == "") {
          if (t_check_trans()) {
            route(RELAY);
            exit;
          }
        }
        route(IN_DIALOG);
        exit;
      }

      if (is_method("ACK")) {
        # Only a non-2xx ACK belongs to the INVITE transaction.
        if (t_check_trans()) {
          route(RELAY);
        }
        exit;
      }

      if (is_method("INVITE|MESSAGE|INFO|UPDATE|PRACK|REFER|NOTIFY")) {
        route(INITIAL_BACKEND);
        exit;
      }

      sl_send_reply("405", "Method Not Allowed");
      exit;
    }

    route[FROM_BACKEND] {
      {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
      if (is_method("INVITE|ACK|BYE|CANCEL|UPDATE|INFO|PRACK|REFER|NOTIFY|MESSAGE")) {
        xlog(
          "L_INFO",
          "SIP request call_id=$ci method=$rm status=$rs direction=backend recv_socket=$Ri:$Rp/$proto send_socket=$fsn source_ip=$si destination_ip=$du route_uri=$route_uri ruri=$ru topos_result=module-managed dialog_direction=backend cseq=$hdr(CSeq)\n"
        );
      }
      {{- end }}
      if (has_totag()) {
        if (is_method("ACK") && !is_present_hf("Route") && $(ru{uri.param,tps}) == "") {
          if (t_check_trans()) {
            route(RELAY);
            exit;
          }
        }
        route(IN_DIALOG);
        exit;
      }

      if (is_method("ACK")) {
        # Transaction ACKs for negative INVITE responses may be matched here;
        # a 2xx ACK is handled above as a dialog request.
        if (t_check_trans()) {
          route(RELAY);
        }
        exit;
      }

      if (!is_method("INVITE|MESSAGE|INFO|UPDATE|PRACK|REFER|NOTIFY")) {
        sl_send_reply("405", "Method Not Allowed");
        exit;
      }

      # The FreeSWITCH ingress remains inbound-dialog-only. New PSTN calls
      # must use the separately authenticated Gateway/mTLS outbound route.
      sl_send_reply("403", "Outbound Calling Disabled");
      exit;
    }

{{ end }}

{{- define "avoip.kamailio.sip.topologyAndBackend" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
{{- $sipCoreEnabled := and (eq .Values.kamailio.role "carrier-sbc") $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled -}}
    route[RR_CARRIER_TO_BACKEND] {
      # Preserve the transport the carrier used for the dialog. TOPOS derives
      # its public Contact route (including port and transport) from this RR.
      # Home1 and DC1 have a directly reachable UDP/5060 Service, while the
      # TLS listener remains available for SIPS-originated dialogs.
      if ($proto == "udp") {
        record_route_preset(
          "{{ $kamailioHost }}:5062;transport=tls;sn=private_tls;r2=on",
          "{{ $kamailioPubHost }}:5060;transport=udp;sn=public_udp;r2=on"
        );
      } else if ($proto == "tcp") {
        record_route_preset(
          "{{ $kamailioHost }}:5062;transport=tls;sn=private_tls;r2=on",
          "{{ $kamailioPubHost }}:5060;transport=tcp;sn=public_tcp;r2=on"
        );
      } else {
        record_route_preset(
          "{{ $kamailioHost }}:5062;transport=tls;sn=private_tls;r2=on",
          "{{ $publicSipHost }}:{{ .Values.kamailio.advertisedTLSPort }};transport=tls;sn=public_tls;r2=on"
        );
      }
    }

    route[RR_BACKEND_TO_CARRIER] {
      record_route_preset(
        "{{ $publicSipHost }}:{{ .Values.kamailio.advertisedTLSPort }};transport=tls;sn=public_tls;r2=on",
        "{{ $kamailioHost }}:5062;transport=tls;sn=private_tls;r2=on"
      );
    }

    route[INITIAL_BACKEND] {
      route(RR_CARRIER_TO_BACKEND);

      {{- if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) .Values.freeswitch.enabled }}
      route(MEDIA_INITIAL);
      {{- end }}

      route(TO_BACKEND);
      route(RELAY);
      exit;
    }

{{ end }}

{{- define "avoip.kamailio.sip.dialogRouting" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
{{- $sipCoreEnabled := and (eq .Values.kamailio.role "carrier-sbc") $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled -}}
    route[IN_DIALOG] {
      if (!is_method("ACK|BYE|UPDATE|INVITE|INFO|REFER|PRACK|NOTIFY")) {
        route(REJECT_DIALOG);
      }
      {{- if .Values.kamailio.carrierOutbound.enabled }}
      if (is_method("BYE")) route(OUTBOUND_RELEASE);
      {{- end }}

      #
      # TOPOS restores the hidden route/contact topology before normal script
      # processing. Do not validate public/private host strings here: doing so
      # couples routing to the topology representation we're intentionally
      # hiding.
      #
      # A carrier dialog request without a visible Route set must address the
      # TOPOS-managed Contact token; otherwise do not fall back to FreeSWITCH.
      if ($var(side) == "carrier" && $(ru{uri.param,tps}) == "") {
        if (!is_present_hf("Route")) {
          route(REJECT_DIALOG);
        }
      }

      # A single loose-route operation consumes an r2 paired set. Do not peel
      # another Route header or replace the target restored by TOPOS.
      if (!loose_route_mode("1") && is_present_hf("Route")) {
        route(REJECT_DIALOG);
      }

      if ($var(side) == "carrier") {
        #
        # No Flowroute topology is forwarded to FreeSWITCH.
        # FreeSWITCH's only next hop is this private Kamailio service.
        #
        {{- if .Values.kamailio.carrierOutbound.enabled }}
        if ($(ru{uri.host}) == "{{ .Values.kamailio.carrierOutbound.peer.serviceHost }}") {
          route(TO_OUTBOUND_PEER);
        } else {
          route(TO_BACKEND);
        }
        {{- else }}
        route(TO_BACKEND);
        {{- end }}
      } else {
        #
        # The carrier destination restored by TOPOS is retained in $du/$ru.
        # FreeSWITCH never has to know what that carrier destination was.
        #
        route(TO_CARRIER);
      }

      {{- if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) .Values.freeswitch.enabled }}
      route(MEDIA_DIALOG);
      {{- end }}

      if (is_method("ACK")) {
        xlog(
          "L_INFO",
          "SIP ack decision=relay pod=$env(POD_NAME) callid=$ci cseq=$hdr(CSeq) side=$var(side) recv=$Ri:$Rp source=$si:$sp ruri=$ru route=$route_uri next=$du socket=$fsn\n"
        );
      }

      {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
      if (!is_method("ACK")) {
        xlog(
          "L_INFO",
          "SIP dialog decision=relay pod=$env(POD_NAME) callid=$ci method=$rm side=$var(side) ruri=$ru route=$route_uri next=$du socket=$fsn\n"
        );
      }
      {{- end }}

      route(RELAY);
      exit;
    }

    route[REJECT_DIALOG] {
      xlog(
        "L_WARN",
        "SIP dialog reject pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq) side=$var(side) source=$si:$sp recv=$Ri:$Rp ruri=$ru route=$hdr(Route)\n"
      );

      if (!is_method("ACK")) {
        sl_send_reply("481", "Call Does Not Exist");
      }

      exit;
    }

    route[TO_BACKEND] {
      #
      # The only SIP peer FreeSWITCH has is Kamailio.
      #
      $du =
        "sip:{{ $freeswitchHost }}:{{ .Values.kamailio.backend.servicePort }};transport=tls";

      $xavp(tls=>server_name) = "{{ $freeswitchHost }}";
      set_send_socket_name("private_tls");
    }

    {{- if $sipCoreEnabled }}
    route[TO_SIPCORE_ASTERISK] {
      $du = "sip:{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}:5061;transport=tls";
      $xavp(tls=>server_name) = "{{ include "avoip.sip.serviceHost" (dict "root" $ "component" "asterisk") }}";
      set_send_socket_name("private_tls");
    }
    {{- end }}

    {{- if .Values.kamailio.carrierOutbound.enabled }}
    route[TO_OUTBOUND_PEER] {
      $du = "sips:{{ .Values.kamailio.carrierOutbound.peer.serviceHost }}:5062;transport=tls";
      $xavp(tls=>server_name) = "{{ .Values.kamailio.carrierOutbound.peer.serviceHost }}";
      set_send_socket_name("private_tls");
    }
    {{- end }}

    route[TO_CARRIER] {
      #
      # For in-dialog traffic TOPOS restores the real carrier remote target.
      # Preserve the resulting destination rather than constructing carrier
      # routing information inside FreeSWITCH.
      #
      if ($du == $null || $du == "") {
        $du = $ru;
      }
      # loose_route() selects the public socket from the restored RR's sn
      # parameter. Do not override it: UDP/TCP dialogs must keep their
      # established public transport, while TLS dialogs continue using TLS.
    }

{{ end }}

{{- define "avoip.kamailio.sip.relayAndObservability" -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $component := include "avoip.kamailio.component" .Values.kamailio -}}
{{- $backendService := default (printf "%s-freeswitch" $fullName) .Values.kamailio.backend.serviceName -}}
{{- $publicSipHost := include "avoip.sip.siteHost" . -}}
{{- $kamailioPubHost := include "avoip.sip.kamailioPubHost" . -}}
{{- $kamailioHost := include "avoip.sip.serviceHost" (dict "root" . "component" $component "override" .Values.kamailio.sip.serviceHost) -}}
{{- $freeswitchHost := default (printf "%s.%s.svc.%s" $backendService $.Release.Namespace (required "cluster.domain is required for SIP backend routing" $.Values.cluster.domain)) .Values.freeswitch.sip.serviceHost -}}
{{- $carrierTrafficLogging := and (not (and .Values.asterisk.enabled .Values.asterisk.sipCore.enabled)) (default false .Values.kamailio.sipLogging.carrierTraffic) }}
    route[RELAY] {
      if (!t_relay()) {
        xlog(
          "L_ERR",
          "SIP relay failure pod=$env(POD_NAME) callid=$ci method=$rm side=$var(side) recv=$Ri:$Rp next=$du socket=$fsn\n"
        );

        if (!is_method("ACK")) {
          sl_reply_error();
        }

        exit;
      }

      {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
      xlog(
        "L_INFO",
        "SIP relay queued pod=$env(POD_NAME) callid=$ci method=$rm side=$var(side) next=$du socket=$fsn\n"
      );
      {{- end }}

      exit;
    }

    {{- if or .Values.freeswitch.enabled .Values.kamailio.sipLogging.enabled }}
    reply_route {
      if (t_check_trans()) {
        $var(reply_transaction) = "matched";
      } else {
        $var(reply_transaction) = "unmatched";
      }

      #
      # Do NOT manually rewrite Contact or Record-Route here.
      #
      # TOPOS now owns topology hiding/restoration. Keeping the old
      # remove_hf_match()/subst_hf() logic would mean two independent systems
      # were modifying the same dialog topology.
      #

      {{- if and .Values.kamailio.functions.media (include "avoip.rtpengine.enabled" . | trim) .Values.freeswitch.enabled }}
      if (has_body("application/sdp")) {
        if (!rtpengine_manage("replace-origin")) {
          xlog(
            "L_ERR",
            "RTPEngine reply SDP handling failed callid=$ci status=$rs\n"
          );
          drop;
        }

        if (!msg_apply_changes()) {
          xlog(
            "L_ERR",
            "RTPEngine reply body apply failed callid=$ci status=$rs\n"
          );
          drop;
        }
      } else if (
        $var(reply_transaction) == "matched" &&
        $rs =~ "[3-6][0-9][0-9]"
      ) {
        rtpengine_manage();
      }
      {{- end }}

      {{- if .Values.kamailio.carrierOutbound.enabled }}
      if ($rs >= 300 && $rs <= 699 && $rm == "INVITE") {
        route(OUTBOUND_RELEASE);
      }
      {{- end }}

      {{- if .Values.kamailio.sipLogging.enabled }}
      xlog(
        "L_INFO",
        "SIP response call_id=$ci method=$rm status=$rs direction=$var(side) recv_socket=$Ri:$Rp/$proto send_socket=$fsn source_ip=$si destination_ip=$du route_uri=$route_uri ruri=$ru topos_result=processed dialog_direction=$var(side) cseq=$hdr(CSeq)\n"
      );
      {{- end }}

      return(1);
    }
    {{- end }}

    onsend_route {
      {{- if $carrierTrafficLogging }}
      if ($fsn == "public_tls" || $fsn == "public_udp" || $fsn == "public_tcp") {
        xlog(
          "L_INFO",
          "SIP FLOWROUTE TX pod=$env(POD_NAME) destination=$snd(ip):$snd(port) wire_proto=$snd(proto) socket_name=$fsn callid=$ci method=$rm cseq=$hdr(CSeq)\n--- SIP FLOWROUTE TX BEGIN ---\n$snd(buf)\n--- SIP FLOWROUTE TX END ---\n"
        );
      }
      {{- end }}

      if ($snd(buf) =~ "^ACK ") {
        xlog(
          "L_INFO",
          "SIP ack send pod=$env(POD_NAME) callid=$ci cseq=$hdr(CSeq) conn=$conid recv=$Ri:$Rp source=$si:$sp socket=$sndfrom(proto):$sndfrom(ip):$sndfrom(port) socket_name=$fsn destination=$snd(ip):$snd(port) ruri=$ru\n"
        );
      }

      {{- if .Values.kamailio.sipLogging.diagnostics.enabled }}
      if ($snd(buf) =~ "^(INVITE|BYE|CANCEL|UPDATE) ") {
        xlog(
          "L_INFO",
          "SIP wire request pod=$env(POD_NAME) callid=$ci method=$rm cseq=$hdr(CSeq) conn=$conid socket=$sndfrom(proto):$sndfrom(ip):$sndfrom(port) socket_name=$fsn destination=$snd(ip):$snd(port)\n"
        );
      }
      {{- end }}

      {{- if .Values.kamailio.sipLogging.diagnostics.sdp }}
      if (
        (
          $snd(buf) =~ "^INVITE " ||
          $snd(buf) =~ "^SIP/2.0 (180|183|200) "
        ) &&
        $snd(buf) =~ "\r\nc=IN IP" &&
        $snd(buf) =~ "\r\nm="
      ) {
        xlog(
          "L_INFO",
          "SIP wire SDP pod=$env(POD_NAME) callid=$ci method=$rm status=$rs destination=$snd(ip):$snd(port) connection=$(snd(buf){re.subst,/.*\r\n(c=[^\r\n]+)\r\n.*/\\1/s}) media=$(snd(buf){re.subst,/.*\r\n(m=[^\r\n]+)\r\n.*/\\1/s})\n"
        );
      }
      {{- end }}
    }

{{ end }}
