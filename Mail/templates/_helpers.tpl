{{- define "mail.clusterName" -}}
{{- default (trimSuffix "-business-mail" .Release.Name) .Values.cluster.name -}}
{{- end -}}

{{- define "mail.isHub" -}}
{{- eq (include "mail.clusterName" .) .Values.credentialsSync.hubCluster -}}
{{- end -}}

{{- define "mail.managesCredentials" -}}
{{- or (not .Values.credentialsSync.enabled) (eq (include "mail.isHub" .) "true") -}}
{{- end -}}

{{- define "mail.credentialsRemoteKey" -}}
{{- printf "%s/%s/%s" .root.Values.credentialsSync.remotePathPrefix .root.Values.credentialsSync.hubCluster .name -}}
{{- end -}}
