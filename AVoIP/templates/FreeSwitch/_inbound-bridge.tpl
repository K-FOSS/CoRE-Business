{{- define "avoip.freeswitch.inboundBridgePolicy" -}}
{{- if .Values.freeswitch.inboundBridgeFailure.enabled }}
<action application="set" data="continue_on_fail=true"/>
<action application="set" data="hangup_after_bridge=true"/>
<action application="set" data="ignore_early_media=true"/>
{{- end }}
{{- end -}}

{{- define "avoip.freeswitch.inboundBridgeFallback" -}}
{{- if .Values.freeswitch.inboundBridgeFailure.enabled }}
<action application="log" data="NOTICE AVoIP inbound bridge failed; answering with GG uuid=${uuid} cause=${originate_failed_cause} disposition=${originate_disposition} sip_cause=${last_bridge_proto_specific_hangup_cause}"/>
<action application="unset" data="execute_on_answer"/>
<action application="unset" data="proto_specific_hangup_cause"/>
<action application="set" data="sip_ignore_remote_cause=true"/>
<action application="answer"/>
<action application="playback" data="shout://{{ trimPrefix "http://" (trimPrefix "https://" (required "freeswitch.preBridgeAudio.url is required for inbound GG fallback" .Values.freeswitch.preBridgeAudio.url)) }}"/>
<action application="hangup" data="NORMAL_CLEARING"/>
{{- end }}
{{- end -}}
