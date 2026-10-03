{{- define "office.nextcloud.background.volumes" -}}
{{- $nextcloud := .Subcharts.nextcloud -}}
- name: nextcloud-main
  {{- if $nextcloud.Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ if $nextcloud.Values.persistence.existingClaim }}{{ $nextcloud.Values.persistence.existingClaim }}{{ else }}{{ template "nextcloud.fullname" $nextcloud }}-nextcloud{{ end }}
  {{- else }}
  emptyDir: {}
  {{- end }}
  {{- if and $nextcloud.Values.persistence.nextcloudData.enabled $nextcloud.Values.persistence.enabled }}
- name: nextcloud-data
  persistentVolumeClaim:
    claimName: {{ if $nextcloud.Values.persistence.nextcloudData.existingClaim }}{{ $nextcloud.Values.persistence.nextcloudData.existingClaim }}{{ else }}{{ template "nextcloud.fullname" $nextcloud }}-nextcloud-data{{ end }}
  {{- end }}
  {{- if $nextcloud.Values.nextcloud.configs }}
- name: nextcloud-config
  configMap:
    name: {{ template "nextcloud.fullname" $nextcloud }}-config
  {{- end }}
  {{- if $nextcloud.Values.nextcloud.phpConfigs }}
- name: nextcloud-phpconfig
  configMap:
    name: {{ template "nextcloud.fullname" $nextcloud }}-phpconfig
  {{- end }}
  {{- with $nextcloud.Values.nextcloud.extraVolumes }}
{{ toYaml . }}
  {{- end }}
{{- end -}}

{{- define "office.nextcloud.background.affinity" -}}
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/component: 'app'
          app.kubernetes.io/instance: {{ .Release.Name | quote }}
          app.kubernetes.io/name: 'nextcloud'
      topologyKey: 'kubernetes.io/hostname'
{{- end -}}

{{- define "office.nextcloud.background.commonPodSpec" -}}
{{- $nextcloud := .Subcharts.nextcloud -}}
dnsPolicy: 'None'
dnsConfig:
  nameservers:
    - '10.44.4.10'
    - '1.1.1.1'
  options:
    - name: 'edns0'
    - name: 'ndots'
      value: '0'
securityContext:
  fsGroup: 82
  seccompProfile:
    type: 'RuntimeDefault'
affinity:
  {{- include "office.nextcloud.background.affinity" . | nindent 2 }}
{{- with $nextcloud.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $nextcloud.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  {{- include "office.nextcloud.background.volumes" . | nindent 2 }}
{{- end -}}
