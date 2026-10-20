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
{{- define "avoip.admin.commonValues" -}}
{{- if and .Values.avoipAdmin.enabled .Values.freeswitch.enabled -}}
{{- $settings := .Values.avoipAdmin -}}
{{- $dbName := printf "%s-admin-connection" (include "avoip.fullname" .) -}}
controllers:
  avoip-admin:
    forceRename: '{{ include "avoip.fullname" . }}-admin'
    replicas: {{ max 2 (int $settings.replicas) }}
    strategy: RollingUpdate
    rollingUpdate:
      unavailable: '0'
      surge: 1
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
            value: '{{ $settings.telephony.asterisk.amiAddress }}'
          - name: 'AVOIP_AMI_USERNAME'
            value: '{{ $settings.telephony.asterisk.amiUsername }}'
          - name: 'AVOIP_AMI_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ required "Asterisk AMI secret name is required when telephony integrations are enabled" $settings.telephony.asterisk.amiSecret.name }}'
                key: '{{ $settings.telephony.asterisk.amiSecret.key }}'
          - name: 'AVOIP_ASTERISK_CDR_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ required "Asterisk CDR connection secret name is required when telephony integrations are enabled" $settings.telephony.asterisk.cdrConnectionSecret.name }}'
                key: '{{ $settings.telephony.asterisk.cdrConnectionSecret.key }}'
          - name: 'AVOIP_ASTERISK_CDR_TABLE'
            value: '{{ $settings.telephony.asterisk.cdrTable }}'
          - name: 'AVOIP_ESL_ADDRESS'
            value: '{{ $settings.telephony.freeswitch.eventSocketAddress }}'
          - name: 'AVOIP_ESL_SECRET'
            valueFrom:
              secretKeyRef:
                name: '{{ required "FreeSWITCH Event Socket secret name is required when telephony integrations are enabled" $settings.telephony.freeswitch.eventSocketSecret.name }}'
                key: '{{ $settings.telephony.freeswitch.eventSocketSecret.key }}'
          - name: 'AVOIP_FREESWITCH_CDR_URL'
            valueFrom:
              secretKeyRef:
                name: '{{ required "FreeSWITCH CDR connection secret name is required when telephony integrations are enabled" $settings.telephony.freeswitch.cdrConnectionSecret.name }}'
                key: '{{ $settings.telephony.freeswitch.cdrConnectionSecret.key }}'
          - name: 'AVOIP_FREESWITCH_CDR_TABLE'
            value: '{{ $settings.telephony.freeswitch.cdrTable }}'
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
                path: '/readyz'
                port: 'http'
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
    policyTypes: ['Ingress'{{ if $settings.telephony.enabled }}, 'Egress'{{ end }}]
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
