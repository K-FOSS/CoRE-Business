{{- define "avoip.flowrouteSMS.commonValues" -}}
{{- if and .Values.flowrouteSMS.enabled -}}
{{- $settings := .Values.flowrouteSMS -}}
{{- if ne .Values.region $settings.primaryRegion -}}
  {{- fail (printf "flowrouteSMS may only run in primaryRegion %q to keep the public callback hostname uniquely owned" $settings.primaryRegion) -}}
{{- end -}}
{{- $_ := required "flowrouteSMS.hostname is required when enabled" $settings.hostname -}}
{{- $_ := required "flowrouteSMS.image.repository is required when enabled" $settings.image.repository -}}
{{- $_ := required "flowrouteSMS.image.digest is required when enabled" $settings.image.digest -}}
{{- $fullName := include "avoip.fullname" . -}}
{{- $name := include "avoip.resourceNameWithSuffix" (dict "root" . "suffix" "flowroute-sms") -}}
{{- $callbackSecretName := default (include "avoip.resourceNameWithSuffix" (dict "root" . "suffix" "sms-callback")) $settings.callbackSecret.name -}}
controllers:
  flowroute-sms:
    forceRename: '{{ $name }}'
    replicas: {{ max 2 (int $settings.replicas) }}
    strategy: RollingUpdate
    pod:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/controller: flowroute-sms
              app.kubernetes.io/instance: '{{ $.Release.Name }}'
    containers:
      flowroute-sms:
        image:
          repository: '{{ $settings.image.repository }}'
          tag: '{{ $settings.image.tag }}'
          digest: '{{ $settings.image.digest }}'
          pullPolicy: '{{ $settings.image.pullPolicy }}'
        env:
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-core-voice-sms" $fullName) $settings.databaseSecret.name }}'
                key: '{{ $settings.databaseSecret.key }}'
          - name: FLOWROUTE_CALLBACK_TOKEN
            valueFrom:
              secretKeyRef:
                name: '{{ $callbackSecretName }}'
                key: '{{ $settings.callbackSecret.key }}'
        ports:
          - name: http
            containerPort: 8080
            protocol: TCP
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /healthz
                port: http
              periodSeconds: 10
              timeoutSeconds: 2
              failureThreshold: 3
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /readyz
                port: http
              periodSeconds: 10
              timeoutSeconds: 2
              failureThreshold: 3
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ['ALL']
service:
  flowroute-sms:
    forceRename: '{{ $name }}'
    controller: flowroute-sms
    ports:
      http:
        port: 8080
        targetPort: http
        protocol: TCP
{{- end -}}
{{- end -}}
