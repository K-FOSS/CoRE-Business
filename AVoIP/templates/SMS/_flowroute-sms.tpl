{{- define "avoip.flowrouteSMS.commonValues" -}}
{{- if .Values.flowrouteSMS.enabled -}}
{{- $settings := .Values.flowrouteSMS -}}
{{- if ne .Values.region $settings.primaryRegion -}}
  {{- fail (printf "flowrouteSMS may only run in primaryRegion %q" $settings.primaryRegion) -}}
{{- end -}}
{{- $_ := required "flowrouteSMS.hostname is required" $settings.hostname -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $callbackSecretName := default (include "avoip.resourceNameWithSuffix" (dict "root" . "suffix" "sms-callback")) $settings.callbackSecret.name -}}
controllers:
  {{- range $mode := list "web" "api" "webhook" "media" }}
  {{- if or (ne $mode "web") $settings.inbox.enabled }}
  {{- $suffix := printf "flowroute-sms-%s" $mode }}
  {{- $name := include "avoip.resourceNameWithSuffix" (dict "root" $ "suffix" $suffix) }}
  {{ $suffix }}:
    forceRename: '{{ $name }}'
    replicas: {{ max 2 (int $settings.replicas) }}
    strategy: RollingUpdate
    rollingUpdate:
      unavailable: '0'
      surge: 1
    pod:
      automountServiceAccountToken: false
      dnsConfig:
        options:
          - name: 'ndots'
            value: '0'
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: 'kubernetes.io/hostname'
          whenUnsatisfiable: 'ScheduleAnyway'
          labelSelector:
            matchLabels:
              app.kubernetes.io/controller: '{{ $suffix }}'
              app.kubernetes.io/instance: '{{ $.Release.Name }}'
    containers:
      {{ $suffix }}:
        image:
          repository: '{{ default (printf "%s-%s" $settings.image.repository $mode) (index $settings.images $mode).repository }}'
          tag: '{{ (index $settings.images $mode).tag }}'
          digest: '{{ (index $settings.images $mode).digest }}'
          pullPolicy: '{{ $settings.image.pullPolicy }}'
        env:
          - name: 'SMS_SERVICE_MODE'
            value: '{{ $mode }}'
          {{- if or (eq $mode "api") (eq $mode "media") }}
          - name: 'MEDIA_S3_ENDPOINT'
            value: 'https://s3.{{ $.Values.cluster.name }}.{{ $.Values.datacenter }}.{{ $.Values.region }}.mylogin.space'
          - name: 'MEDIA_S3_BUCKET'
            value: '{{ $settings.media.bucket }}'
          - name: 'MEDIA_S3_REGION'
            value: '{{ $settings.media.region }}'
          - name: 'MEDIA_PROXY_BASE_URL'
            value: 'https://{{ $settings.media.hostname }}'
          - name: 'MEDIA_S3_ACCESS_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $settings.media.credentialsSecretName }}'
                key: 'AccessKey'
          - name: 'MEDIA_S3_SECRET_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $settings.media.credentialsSecretName }}'
                key: 'SecretAccessKey'
          - name: 'MEDIA_PROXY_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ $settings.media.proxySecretName }}'
                key: 'secret'
          {{- end }}
          {{- if eq $mode "web" }}
          - name: 'SMS_FRAME_ANCESTOR'
            value: '{{ $settings.inbox.frameAncestor }}'
          {{- end }}
          {{- if ne $mode "web" }}
          {{ if and $.Values.avoipAdmin.enabled $.Values.freeswitch.enabled }}
          - name: 'AVOIP_ADMIN_URL'
            value: 'https://{{ include "avoip.admin.hostname" $ }}'
          {{ end }}
          - name: 'FLOWROUTE_ENABLED'
            value: '{{ $settings.legacyFlowroute.enabled }}'
          - name: 'SMS_ADMIN_GROUP'
            value: '{{ $settings.inbox.adminGroup }}'
          - name: 'SMS_LOCAL_NUMBERS'
            value: '{{ join "," $settings.localNumbers }}'
          - name: 'SMS_PROVIDERS_JSON'
            value: '{{ toJson $settings.providers | replace "'" "''" }}'
          {{- range $name, $secret := $settings.providerCredentials }}
          {{- if not (regexMatch "^SMS_PROVIDER_[A-Z0-9_]{1,100}$" $name) }}{{ fail "provider credential names must start with SMS_PROVIDER_" }}{{ end }}
          - name: '{{ $name }}'
            valueFrom:
              secretKeyRef:
                name: '{{ required "provider credential Secret name required" $secret.name }}'
                key: '{{ required "provider credential Secret key required" $secret.key }}'
          {{- end }}
          - name: 'DATABASE_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-core-voice-sms" $fullName) $settings.databaseSecret.name }}'
                key: '{{ $settings.databaseSecret.key }}'
          {{- end }}
          {{- if and (eq $mode "webhook") $settings.legacyFlowroute.enabled }}
          - name: 'FLOWROUTE_CALLBACK_TOKEN'
            valueFrom:
              secretKeyRef:
                name: '{{ $callbackSecretName }}'
                key: '{{ $settings.callbackSecret.key }}'
          - name: 'FLOWROUTE_SMS_DIAGNOSTICS'
            value: '{{ $settings.diagnostics.enabled }}'
          {{- end }}
          {{- if and (eq $mode "api") $settings.legacyFlowroute.enabled }}
          - name: 'FLOWROUTE_SMS_ACCESS_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $fullName }}-flowroute-sms-send'
                key: 'AccessKey'
          - name: 'FLOWROUTE_SMS_SECRET_KEY'
            valueFrom:
              secretKeyRef:
                name: '{{ $fullName }}-flowroute-sms-send'
                key: 'SecretKey'
          {{- end }}
        ports:
          - name: 'http'
            containerPort: 8080
            protocol: TCP
        probes:
          startup:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: '/healthz'
                port: 'http'
              periodSeconds: 5
              timeoutSeconds: 2
              failureThreshold: 30
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: '/healthz'
                port: 'http'
              periodSeconds: 10
              timeoutSeconds: 2
              failureThreshold: 3
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: {{ if eq $mode "web" }}'/healthz'{{ else }}'/readyz'{{ end }}
                port: 'http'
              periodSeconds: 5
              timeoutSeconds: 2
              failureThreshold: 3
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ['ALL']
  {{- end }}
  {{- end }}
service:
  {{- range $mode := list "web" "api" "webhook" "media" }}
  {{- if or (ne $mode "web") $settings.inbox.enabled }}
  {{- $suffix := printf "flowroute-sms-%s" $mode }}
  {{ $suffix }}:
    forceRename: '{{ include "avoip.resourceNameWithSuffix" (dict "root" $ "suffix" $suffix) }}'
    controller: '{{ $suffix }}'
    ports:
      http:
        port: 8080
        targetPort: 'http'
        protocol: TCP
  {{- end }}
  {{- end }}
networkpolicies:
  {{- range $mode := list "web" "api" "webhook" "media" }}
  {{- if or (ne $mode "web") $settings.inbox.enabled }}
  {{- $suffix := printf "flowroute-sms-%s" $mode }}
  {{ $suffix }}-ingress:
    controller: '{{ $suffix }}'
    policyTypes:
      - 'Ingress'
    rules:
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: '{{ $settings.gatewayPods.namespace }}'
              podSelector:
                matchLabels:
                  app.kubernetes.io/name: 'envoy'
                  gateway.envoyproxy.io/owning-gateway-name: '{{ $.Values.gateway.name }}'
                  gateway.envoyproxy.io/owning-gateway-namespace: '{{ $.Values.gateway.namespace }}'
          ports:
            - protocol: 'TCP'
              port: 8080
  {{- end }}
  {{- end }}
{{- end -}}
{{- end -}}
