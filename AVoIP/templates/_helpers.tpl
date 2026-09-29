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

{{/* Respect per-cluster RTPEngine enablement, including on spokes. */}}
{{- define "avoip.rtpengine.enabled" -}}
{{- if .Values.rtpengine.enabled -}}true{{- end -}}
{{- end -}}

{{/* Keep the primary-aware Valkey proxy's generated resources within DNS limits. */}}
{{- define "avoip.rtpengine.valkeyProxyName" -}}
{{- printf "%s-rtp-valkey" (include "avoip.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "avoip.sip.siteHost" -}}
{{- $derived := printf "sip.%s.%s.%s.resolvemy.host" .Values.cluster.name .Values.datacenter .Values.region -}}
{{- default (default $derived .Values.kamailio.advertisedHost) .Values.sip.siteHost -}}
{{- end -}}

{{- define "avoip.sip.serviceHost" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $override := index (index $root.Values $component) "sip" "serviceHost" -}}
{{- default (printf "%s-%s.%s.svc.%s" (include "avoip.fullname" $root) $component $root.Release.Namespace (required "cluster.domain is required for SIP service identities" $root.Values.cluster.domain)) $override -}}
{{- end -}}

{{- define "avoip.homer.hostname" -}}
{{- $override := .Values.homer.hostname -}}
{{- default (printf "homer.%s.%s.%s.resolvemy.host" .Values.cluster.name .Values.datacenter .Values.region) $override -}}
{{- end -}}
