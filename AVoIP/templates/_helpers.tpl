{{/* vim: set filetype=gohtmltmpl: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "avoip.name" -}}
{{- default "avoip" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "avoip.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "avoip" .Values.nameOverride -}}
{{- if or (eq $name .Release.Name) (eq (.Release.Name | upper) "RELEASE-NAME") -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* RTPEngine owns public media on the active hub only. */}}
{{- define "avoip.rtpengine.enabled" -}}
{{- if and .Values.rtpengine.enabled (eq .Values.cluster.type "hub") -}}true{{- end -}}
{{- end -}}

{{/* Keep the primary-aware Valkey proxy's generated resources within DNS limits. */}}
{{- define "avoip.rtpengine.valkeyProxyName" -}}
{{- printf "%s-rtp-valkey" (include "avoip.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
