{{- define "avoip.routr.common.values" -}}
{{- if .Values.routr.enabled -}}
{{- $name := include "avoip.fullname" . -}}
configMaps:
  routr-dispatcher-config:
    forceRename: '{{ $name }}-routr-dispatcher-config'
    data:
      dispatcher.yaml: |
        kind: MessageDispatcher
        apiVersion: v2beta1
        ref: message-dispatcher
        spec:
          bindAddr: 0.0.0.0:51901
          processors:
            - ref: connect-processor
              addr: {{ $name }}-routr-connect:51904
              matchFunc: 'req => true'
              methods: [REGISTER, MESSAGE, INVITE, ACK, BYE, CANCEL]
          middlewares: []
{{- if or .Values.routr.edgeport.udp.enabled .Values.routr.edgeport.tcp.enabled .Values.routr.edgeport.tls.enabled .Values.routr.edgeport.ws.enabled .Values.routr.edgeport.wss.enabled }}
  routr-edgeport-config:
    forceRename: '{{ $name }}-routr-edgeport-config'
    data:
      edgeport.yaml: |
        kind: EdgePort
        apiVersion: v2beta1
        metadata:
          region: {{ .Values.region }}
        spec:
          unknownMethodAction: Discard
          processor:
            addr: {{ $name }}-routr-dispatcher:51901
          securityContext:
            client:
              protocols: [TLSv1.2]
              authType: DisabledAll
          methods: [REGISTER, MESSAGE, INVITE, ACK, BYE, CANCEL]
{{- if or .Values.routr.edgeport.udp.enabled .Values.routr.edgeport.tcp.enabled .Values.routr.edgeport.tls.enabled .Values.routr.edgeport.ws.enabled .Values.routr.edgeport.wss.enabled }}
          transport:
{{- if .Values.routr.edgeport.udp.enabled }}
            - protocol: udp
              port: {{ .Values.routr.edgeport.udp.port }}
{{- end }}
{{- if .Values.routr.edgeport.tcp.enabled }}
            - protocol: tcp
              port: {{ .Values.routr.edgeport.tcp.port }}
{{- end }}
{{- if .Values.routr.edgeport.tls.enabled }}
            - protocol: tls
              port: {{ .Values.routr.edgeport.tls.port }}
{{- end }}
{{- if .Values.routr.edgeport.ws.enabled }}
            - protocol: ws
              port: {{ .Values.routr.edgeport.ws.port }}
{{- end }}
{{- if .Values.routr.edgeport.wss.enabled }}
            - protocol: wss
              port: {{ .Values.routr.edgeport.wss.port }}
{{- end }}
{{- end }}
{{- end }}
controllers:
{{- $components := list "apiserver" "connect" "dispatcher" "location" "registry" "requester" -}}
{{- if or .Values.routr.edgeport.udp.enabled .Values.routr.edgeport.tcp.enabled .Values.routr.edgeport.tls.enabled .Values.routr.edgeport.ws.enabled .Values.routr.edgeport.wss.enabled -}}
  {{- $components = append $components "edgeport" -}}
{{- end -}}
{{- range $component := $components }}
  routr-{{ $component }}:
    forceRename: '{{ include "avoip.fullname" $ }}-routr-{{ $component }}'
    replicas: 1
    pod:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 3000
        seccompProfile:
          type: RuntimeDefault
    containers:
      {{ $component }}:
        image:
{{- if eq $component "apiserver" }}
          repository: 'fonoster/routr-pgdata'
{{- else }}
          repository: 'fonoster/routr-{{ $component }}'
{{- end }}
{{- if eq $component "location" }}
          tag: '{{ $.Values.routr.imageVersion }}'
          digest: '{{ $.Values.routr.imageDigests.location }}'
{{- else if eq $component "registry" }}
          tag: '{{ $.Values.routr.imageVersion }}'
          digest: '{{ $.Values.routr.imageDigests.registry }}'
{{- else }}
          tag: '{{ $.Values.routr.imageVersion }}'
{{- end }}
          pullPolicy: IfNotPresent
        env:
          - name: LOGS_LEVEL
            value: info
{{- if eq $component "apiserver" }}
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-routr" $name) $.Values.routr.database.connectionSecret }}'
                key: psqlURI
          - name: TLS_ON
            value: 'true'
{{- end }}
{{- if eq $component "location" }}
          - name: CONFIG_PATH
            value: /etc/routr/location.yaml
{{- else if eq $component "registry" }}
          - name: CONFIG_PATH
            value: /etc/routr/registry.yaml
{{- else if eq $component "dispatcher" }}
          - name: CONFIG_PATH
            value: /etc/routr/dispatcher.yaml
{{- else if eq $component "connect" }}
          - name: LOCATION_ADDR
            value: '{{ $name }}-routr-location:51902'
          - name: API_ADDR
            value: '{{ $name }}-routr-apiserver:51907'
{{- else if eq $component "requester" }}
          - name: ENABLE_HEALTHCHECKS
            value: 'true'
{{- else if eq $component "edgeport" }}
          - name: CONFIG_PATH
            value: /etc/routr/edgeport.yaml
{{- end }}
{{- if eq $component "location" }}
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              grpc:
                port: 51902
              periodSeconds: 5
{{- else if eq $component "apiserver" }}
        probes:
          liveness:
            enabled: true
            custom: true
            spec:
              grpc:
                port: 51907
              periodSeconds: 5
{{- end }}
        ports:
{{- if has $component (list "dispatcher" "registry") }}
          - name: grpc
            containerPort: 51901
            protocol: TCP
{{- end }}
{{- if eq $component "location" }}
          - name: grpc
            containerPort: 51902
            protocol: TCP
{{- end }}
{{- if eq $component "connect" }}
          - name: grpc
            containerPort: 51904
            protocol: TCP
{{- end }}
{{- if eq $component "requester" }}
          - name: grpc
            containerPort: 51909
            protocol: TCP
{{- end }}
{{- if eq $component "apiserver" }}
          - name: grpc
            containerPort: 51907
            protocol: TCP
{{- end }}
{{- if eq $component "registry" }}
          - name: health
            containerPort: 8080
            protocol: TCP
{{- end }}
{{- if eq $component "edgeport" }}
          - name: health
            containerPort: 8080
            protocol: TCP
{{- if $.Values.routr.edgeport.udp.enabled }}
          - name: sip-udp
            containerPort: {{ $.Values.routr.edgeport.udp.port }}
            protocol: UDP
{{- end }}
{{- range $transport := (list "tcp" "tls" "ws" "wss") }}
{{- if (index $.Values.routr.edgeport $transport).enabled }}
          - name: sip-{{ $transport }}
            containerPort: {{ (index $.Values.routr.edgeport $transport).port }}
            protocol: TCP
{{- end }}
{{- end }}
{{- end }}
{{- end }}
  routr-migrations:
    enabled: true
    type: job
    forceRename: '{{ $name }}-routr-migrations'
    annotations:
      argocd.argoproj.io/hook: 'Sync'
      argocd.argoproj.io/hook-delete-policy: 'BeforeHookCreation,HookSucceeded'
      argocd.argoproj.io/sync-wave: '0'
    pod:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 3000
        seccompProfile:
          type: RuntimeDefault
    containers:
      migrations:
        image:
          repository: 'fonoster/routr-pgdata-migrations'
          tag: '{{ .Values.routr.imageVersion }}'
          pullPolicy: IfNotPresent
        env:
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: '{{ default (printf "%s-routr" $name) .Values.routr.database.connectionSecret }}'
                key: psqlURI
services:
{{- range $component := (list "apiserver" "connect" "dispatcher" "location" "registry" "requester") }}
  routr-{{ $component }}:
    forceRename: '{{ include "avoip.fullname" $ }}-routr-{{ $component }}'
    controller: routr-{{ $component }}
    ports:
{{- if eq $component "apiserver" }}
      grpc:
        port: 51907
        targetPort: 51907
{{- else if eq $component "connect" }}
      grpc:
        port: 51904
        targetPort: 51904
{{- else if eq $component "dispatcher" }}
      grpc:
        port: 51901
        targetPort: 51901
{{- else if eq $component "location" }}
      grpc:
        port: 51902
        targetPort: 51902
{{- else if eq $component "registry" }}
      grpc:
        port: 51901
        targetPort: 51901
      health:
        port: 8080
        targetPort: 8080
{{- else }}
      grpc:
        port: 51909
        targetPort: 51909
{{- end }}
{{- end }}
{{- if .Values.routr.edgeport.udp.enabled }}
  routr-edgeport-udp:
    forceRename: '{{ include "avoip.fullname" . }}-routr-edgeport-udp'
    controller: routr-edgeport
    type: ClusterIP
    ports:
      sip:
        port: {{ .Values.routr.edgeport.udp.port }}
        targetPort: {{ .Values.routr.edgeport.udp.port }}
        protocol: UDP
{{- end }}
{{- end -}}
{{- end -}}

{{- define "avoip.routr.common.persistence" -}}
{{- if .Values.routr.enabled -}}
{{- $name := include "avoip.fullname" . }}
  routr-dispatcher-config:
    type: configMap
    name: '{{ $name }}-routr-dispatcher-config'
    advancedMounts:
      routr-dispatcher:
        dispatcher:
          - path: /etc/routr/dispatcher.yaml
            subPath: dispatcher.yaml
  routr-redis-config:
    type: secret
    name: '{{ $name }}-routr-redis-config'
    advancedMounts:
      routr-location:
        location:
          - path: /etc/routr/location.yaml
            subPath: location.yaml
      routr-registry:
        registry:
          - path: /etc/routr/registry.yaml
            subPath: registry.yaml
{{- if or .Values.routr.edgeport.udp.enabled .Values.routr.edgeport.tcp.enabled .Values.routr.edgeport.tls.enabled .Values.routr.edgeport.ws.enabled .Values.routr.edgeport.wss.enabled }}
  routr-edgeport-config:
    type: configMap
    name: '{{ $name }}-routr-edgeport-config'
    advancedMounts:
      routr-edgeport:
        edgeport:
          - path: /etc/routr/edgeport.yaml
            subPath: edgeport.yaml
{{- end }}
{{- end -}}
{{- end -}}
