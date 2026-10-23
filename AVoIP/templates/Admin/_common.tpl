{{- define "avoip.admin.hostname" -}}
{{- default (printf "avoip-admin.%s.%s.%s.resolvemy.host" .Values.cluster.name .Values.datacenter .Values.region) .Values.avoipAdmin.hostname -}}
{{- end -}}
{{- define "avoip.admin.sites" -}}
{{- $sites := dict .Values.region (dict "host" (include "avoip.sip.serviceHost" (dict "root" . "component" "freeswitch")) "port" 5072) -}}
{{- range (include "avoip.kamailio.instances" . | fromYamlArray) -}}
  {{- if eq .role "carrier-sbc" -}}
    {{- range .interSite.peers -}}
      {{- $_ := set $sites .name (dict "host" .serviceHost "port" 5061) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- mergeOverwrite $sites (deepCopy .Values.avoipAdmin.sites) | toJson -}}
{{- end -}}
{{- define "avoip.admin.kamailioControls" -}}
{{- $controls := list -}}
{{- range $instance := (include "avoip.kamailio.instances" . | fromYamlArray) -}}
  {{- if $instance.enabled -}}
    {{- $service := include "avoip.kamailio.controlResourceName" (dict "root" $ "instance" $instance) -}}
    {{- $host := printf "%s.%s.svc.%s:%d" $service $.Release.Namespace $.Values.cluster.domain (int $.Values.kamailio.controlPort) -}}
    {{- $controls = append $controls $host -}}
  {{- end -}}
{{- end -}}
{{- $controls | toJson -}}
{{- end -}}
{{- define "avoip.admin.commonValues" -}}
{{- if and .Values.avoipAdmin.enabled .Values.freeswitch.enabled -}}
{{- $settings := .Values.avoipAdmin -}}
{{- if and $settings.bridgedCalls.enabled (or (not $settings.telephony.enabled) (not $settings.routing.enabled)) }}
{{- fail "avoipAdmin.bridgedCalls requires telephony integrations and managed routing" }}
{{- end }}
{{- if and $settings.bridgedCalls.enabled $settings.bridgedCalls.tts.enabled (or (not $.Values.homer.soundLibrary.enabled) (not $.Values.homer.storage.persistence.enabled)) }}
{{- fail "avoipAdmin.bridgedCalls.tts requires the shared Homer audio library and persistence" }}
{{- end }}
{{- if and $settings.bridgedCalls.enabled (or (lt (int $settings.bridgedCalls.callbackRingTimeoutSeconds) 1) (gt (int $settings.bridgedCalls.callbackRingTimeoutSeconds) 300) (lt (int $settings.bridgedCalls.confirmationTimeoutSeconds) 1) (gt (int $settings.bridgedCalls.confirmationTimeoutSeconds) 30) (lt (int $settings.bridgedCalls.extensionRingTimeoutSeconds) 1) (gt (int $settings.bridgedCalls.extensionRingTimeoutSeconds) 300) (lt (int $settings.bridgedCalls.maximumDurationSeconds) 60) (gt (int $settings.bridgedCalls.maximumDurationSeconds) 86400) (lt (int $settings.bridgedCalls.schedulingHorizonDays) 1) (gt (int $settings.bridgedCalls.schedulingHorizonDays) 90) (lt (int $settings.bridgedCalls.perUserConcurrency) 1) (gt (int $settings.bridgedCalls.perUserConcurrency) 20)) }}
{{- fail "avoipAdmin.bridgedCalls timeout, duration, horizon, or concurrency setting is outside its allowed range" }}
{{- end }}
{{- $dbName := printf "%s-admin-connection" (include "avoip.fullname" .) -}}
{{- $sipCoreRegistrarGateway := ternary "sipcore-registrar" "" (eq .Values.asterisk.sipCore.registrarBackend "kamailio") -}}
controllers:
  avoip-admin:
    forceRename: '{{ include "avoip.fullname" . }}-admin'
    replicas: {{ max 2 (int $settings.replicas) }}
    strategy: RollingUpdate
    rollingUpdate:
      unavailable: '0'
      surge: 1
    podDisruptionBudget:
      minAvailable: 1
    pod:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
    containers:
      admin:
        image:
          repository: '{{ $settings.image.repository }}'
          tag: '{{ $settings.image.tag }}'
          digest: '{{ required "avoipAdmin.image.digest must pin a built admin image" $settings.image.digest }}'
        env:
          - name: 'SMS_SERVICE_MODE'
            value: 'admin'
          - name: 'SMS_ADMIN_GROUP'
            value: '{{ .Values.flowrouteSMS.inbox.adminGroup }}'
          - name: 'ADMIN_SMS_ENABLED'
            value: 'true'
          - name: 'FLOWROUTE_ENABLED'
            value: '{{ .Values.flowrouteSMS.legacyFlowroute.enabled }}'
          - name: 'SMS_PROVIDERS_JSON'
            value: '{{ toJson .Values.flowrouteSMS.providers | replace "'" "''" }}'
          {{ range $name, $secret := .Values.flowrouteSMS.providerCredentials }}
          - name: '{{ $name }}'
            valueFrom:
              secretKeyRef:
                name: '{{ $secret.name }}'
                key: '{{ $secret.key }}'
          {{ end }}
          - name: 'AVOIP_ROUTING_ENABLED'
            value: '{{ $settings.routing.enabled }}'
          {{- if $sipCoreRegistrarGateway }}
          - name: 'AVOIP_SIPCORE_REGISTRAR_GATEWAY'
            value: '{{ $sipCoreRegistrarGateway }}'
          {{- end }}
          {{ if and .Values.flowrouteSMS.enabled .Values.flowrouteSMS.legacyFlowroute.enabled }}
          - name: 'FLOWROUTE_SMS_ACCESS_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ include "avoip.fullname" . }}-flowroute-sms-send'
                key: 'AccessKey'
          - name: 'FLOWROUTE_SMS_SECRET_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ include "avoip.fullname" . }}-flowroute-sms-send'
                key: 'SecretKey'
          {{ end }}
          - name: 'AVOIP_SITE'
            value: '{{ .Values.region }}'
          {{ if and $.Values.homer.soundLibrary.enabled $.Values.homer.storage.persistence.enabled }}
          - name: 'AVOIP_AUDIO_LIBRARY_URL'
            value: 'http://{{ include "avoip.fullname" $ }}-audio-library.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:{{ $.Values.homer.soundLibrary.port }}{{ $.Values.homer.soundLibrary.path }}/files'
          {{ end }}
          - name: 'AVOIP_BRIDGED_CALLS_ENABLED'
            value: '{{ $settings.bridgedCalls.enabled }}'
          - name: 'AVOIP_BRIDGED_CONFIRMATION_REQUIRED'
            value: '{{ $settings.bridgedCalls.confirmationRequired }}'
          - name: 'AVOIP_BRIDGED_INTERNAL_CONFIRMATION_REQUIRED'
            value: '{{ $settings.bridgedCalls.internalConfirmationRequired }}'
          - name: 'AVOIP_BRIDGED_CALLBACK_RING_TIMEOUT_SECONDS'
            value: '{{ $settings.bridgedCalls.callbackRingTimeoutSeconds }}'
          - name: 'AVOIP_BRIDGED_CONFIRMATION_TIMEOUT_SECONDS'
            value: '{{ $settings.bridgedCalls.confirmationTimeoutSeconds }}'
          - name: 'AVOIP_BRIDGED_EXTENSION_RING_TIMEOUT_SECONDS'
            value: '{{ $settings.bridgedCalls.extensionRingTimeoutSeconds }}'
          - name: 'AVOIP_BRIDGED_MAX_DURATION_SECONDS'
            value: '{{ $settings.bridgedCalls.maximumDurationSeconds }}'
          - name: 'AVOIP_BRIDGED_SCHEDULING_HORIZON_DAYS'
            value: '{{ $settings.bridgedCalls.schedulingHorizonDays }}'
          - name: 'AVOIP_BRIDGED_LATENESS_GRACE_SECONDS'
            value: '{{ $settings.bridgedCalls.latenessGraceSeconds }}'
          - name: 'AVOIP_BRIDGED_PER_USER_CONCURRENCY'
            value: '{{ $settings.bridgedCalls.perUserConcurrency }}'
          - name: 'AVOIP_BRIDGED_TTS_CACHE_URL'
            value: 'http://{{ include "avoip.resourceNameWithSuffix" (dict "root" . "suffix" "flowroute-sms-tts-cache") }}.{{ $.Release.Namespace }}.svc.{{ $.Values.cluster.domain }}:8080'
          - name: 'AVOIP_BRIDGED_TTS_INTERNAL_TOKEN'
            valueFrom:
              secretKeyRef:
                name: '{{ include "avoip.fullname" . }}-admin-routing-token'
                key: 'token'
          - name: 'MEDIA_S3_ENDPOINT'
            value: '{{ default (printf "https://s3.%s.%s.%s.mylogin.space" $.Values.cluster.name $.Values.datacenter $.Values.region) $.Values.flowrouteSMS.media.endpoint }}'
          - name: 'MEDIA_S3_BUCKET'
            value: '{{ $.Values.flowrouteSMS.media.bucket }}'
          - name: 'MEDIA_S3_REGION'
            value: '{{ $.Values.flowrouteSMS.media.region }}'
          - name: 'MEDIA_PROXY_BASE_URL'
            value: 'https://{{ $.Values.flowrouteSMS.media.hostname }}'
          - name: 'MEDIA_S3_ACCESS_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $.Values.flowrouteSMS.media.credentialsSecretName }}'
                key: '{{ $.Values.flowrouteSMS.media.accessKeyKey }}'
          - name: 'MEDIA_S3_SECRET_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $.Values.flowrouteSMS.media.credentialsSecretName }}'
                key: '{{ $.Values.flowrouteSMS.media.secretKeyKey }}'
          - name: 'MEDIA_PROXY_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ $.Values.flowrouteSMS.media.proxySecretName }}'
                key: 'secret'
          - name: 'AVOIP_DEFAULT_LIMITS_JSON'
            value: '{{ dict "calls_per_minute" .Values.kamailio.defaults.carrierOutbound.limits.callsPerMinute "concurrent_calls" .Values.kamailio.defaults.carrierOutbound.limits.concurrentCalls "max_duration_seconds" .Values.kamailio.defaults.carrierOutbound.limits.maxDurationSeconds | toJson | replace "'" "''" }}'
          - name: 'AVOIP_SITES_JSON'
            value: '{{ include "avoip.admin.sites" . | replace "'" "''" }}'
          {{ if ne (kindOf $settings.catalog) "invalid" }}
          - name: 'AVOIP_SIP_JSON'
            value: '{{ toJson $settings.catalog | replace "'" "''" }}'
          {{ end }}
          - name: 'DATABASE_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ $dbName }}'
                key: 'psqlURI'
          - name: 'AVOIP_ROUTING_TOKEN'
            valueFrom:
              secretKeyRef:
                name: '{{ include "avoip.fullname" . }}-admin-routing-token'
                key: 'token'
          {{ if $settings.telephony.enabled }}
          - name: 'AVOIP_AMI_ADDRESS'
            value: '{{ default (printf "%s.%s.svc.%s:%d" (include "avoip.resourceNameWithSuffix" (dict "root" $ "suffix" "asterisk-control")) $.Release.Namespace $.Values.cluster.domain (int $settings.telephony.asteriskManager.port)) $settings.telephony.asterisk.amiAddress }}'
          - name: 'AVOIP_AMI_USERNAME'
            value: '{{ default (printf "avoip-admin-%s" .Values.region) $settings.telephony.asteriskManager.username }}'
          - name: 'AVOIP_AMI_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-telephony-management" (include "avoip.fullname" .)) $settings.telephony.managementSecret.name }}'
                key: '{{ $settings.telephony.managementSecret.key }}'
          {{ if $settings.telephony.asterisk.cdrConnectionSecret.name }}
          - name: 'AVOIP_ASTERISK_CDR_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ $settings.telephony.asterisk.cdrConnectionSecret.name }}'
                key: '{{ $settings.telephony.asterisk.cdrConnectionSecret.key }}'
          - name: 'AVOIP_ASTERISK_CDR_TABLE'
            value: '{{ $settings.telephony.asterisk.cdrTable }}'
          {{ end }}
          - name: 'AVOIP_ESL_ADDRESS'
            value: '{{ default (printf "%s.%s.svc.%s:%d" (include "avoip.resourceNameWithSuffix" (dict "root" $ "suffix" "freeswitch-control")) $.Release.Namespace $.Values.cluster.domain (int $settings.telephony.freeswitchEventSocket.port)) $settings.telephony.freeswitch.eventSocketAddress }}'
          - name: 'AVOIP_ESL_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-telephony-management" (include "avoip.fullname" .)) $settings.telephony.managementSecret.name }}'
                key: '{{ $settings.telephony.managementSecret.key }}'
          - name: 'AVOIP_KAMAILIO_CONTROL_ADDRESSES'
            value: '{{ include "avoip.admin.kamailioControls" $ | replace "'" "''" }}'
          {{ if $settings.telephony.freeswitch.cdrConnectionSecret.name }}
          - name: 'AVOIP_FREESWITCH_CDR_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ $settings.telephony.freeswitch.cdrConnectionSecret.name }}'
                key: '{{ $settings.telephony.freeswitch.cdrConnectionSecret.key }}'
          - name: 'AVOIP_FREESWITCH_CDR_TABLE'
            value: '{{ $settings.telephony.freeswitch.cdrTable }}'
          {{ end }}
          {{ end }}
        ports:
          - name: 'http'
            containerPort: 8080
          - name: 'routing'
            containerPort: 8081
        probes:
          startup:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: '/healthz'
                port: 'http'
              failureThreshold: 30
              periodSeconds: 5
          liveness:
            enabled: true
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                {{ if $settings.routing.enabled }}
                path: '/routing/readyz'
                port: 'routing'
                {{ else }}
                path: '/readyz'
                port: 'http'
                {{ end }}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ['ALL']
service:
  avoip-admin:
    forceRename: '{{ include "avoip.fullname" . }}-admin'
    controller: 'avoip-admin'
    ports:
      http:
        port: 8080
        targetPort: 'http'
      routing:
        port: 8081
        targetPort: 'routing'
networkpolicies:
  avoip-admin:
    controller: 'avoip-admin'
    policyTypes: ['Ingress'{{ if or $settings.telephony.enabled (and $.Values.homer.soundLibrary.enabled $.Values.homer.storage.persistence.enabled) }}, 'Egress'{{ end }}]
    rules:
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: '{{ .Values.flowrouteSMS.gatewayPods.namespace }}'
              podSelector:
                matchLabels:
                  app.kubernetes.io/name: 'envoy'
                  gateway.envoyproxy.io/owning-gateway-name: '{{ .Values.gateway.name }}'
                  gateway.envoyproxy.io/owning-gateway-namespace: '{{ .Values.gateway.namespace }}'
          ports:
            - port: 8080
              protocol: 'TCP'
        - from:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                matchExpressions:
                  - key: 'avoip.mylogin.space/kamailio-instance'
                    operator: 'Exists'
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                  app.kubernetes.io/controller: 'freeswitch'
          ports:
            - port: 8081
              protocol: 'TCP'
      {{- if or $settings.telephony.enabled (and $.Values.homer.soundLibrary.enabled $.Values.homer.storage.persistence.enabled) }}
      egress:
        {{- if $settings.telephony.enabled }}
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                  app.kubernetes.io/controller: 'asterisk'
          ports:
            - port: {{ $settings.telephony.asteriskManager.port }}
              protocol: 'TCP'
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                  app.kubernetes.io/controller: 'freeswitch'
          ports:
            - port: {{ $settings.telephony.freeswitchEventSocket.port }}
              protocol: 'TCP'
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                matchExpressions:
                  - key: 'avoip.mylogin.space/kamailio-instance'
                    operator: 'Exists'
          ports:
            - port: {{ $.Values.kamailio.controlPort }}
              protocol: 'TCP'
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                  app.kubernetes.io/controller: 'flowroute-sms-tts-cache'
          ports:
            - port: 8080
              protocol: 'TCP'
        {{- end }}
        {{- if and $.Values.homer.soundLibrary.enabled $.Values.homer.storage.persistence.enabled }}
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                  app.kubernetes.io/controller: 'audio-library'
          ports:
            - port: {{ $.Values.homer.soundLibrary.port }}
              protocol: 'TCP'
        {{- end }}
      {{- end }}
{{- if $settings.routing.enabled }}
  managed-sip:
    controller: 'freeswitch'
    policyTypes: ['Ingress']
    rules:
      ingress:
        - ports:
            - protocol: 'TCP'
              port: 1
              endPort: 5071
            - protocol: 'TCP'
              port: 5073
              endPort: 65535
            - protocol: 'UDP'
              port: 1
              endPort: 65535
        - from:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: '{{ .Release.Name }}'
                matchExpressions:
                  - key: 'avoip.mylogin.space/kamailio-instance'
                    operator: 'Exists'
          ports:
            - protocol: 'TCP'
              port: 5072
{{- end }}
{{- end -}}
{{- end -}}
