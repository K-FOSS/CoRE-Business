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

{{/* Disable Homer on named clusters without the required Longhorn storage. */}}
{{- define "avoip.homer.enabled" -}}
{{- if and .Values.homer.enabled (not (has .Values.cluster.name .Values.homer.disabledClusters)) -}}true{{- end -}}
{{- end -}}

{{/* Keep the primary-aware Valkey proxy's generated resources within DNS limits. */}}
{{- define "avoip.rtpengine.valkeyProxyName" -}}
{{- printf "%s-rtp-valkey" (include "avoip.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "avoip.sip.siteHost" -}}
{{- $derived := printf "sip.%s.%s.%s.resolvemy.host" .Values.cluster.name .Values.datacenter .Values.region -}}
{{- $kamailio := .Values.kamailio -}}
{{- if hasKey $kamailio "instances" -}}
  {{- range (include "avoip.kamailio.instances" . | fromYamlArray) -}}
    {{- if eq .name "carrier" -}}{{- $kamailio = . -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- default (default $derived $kamailio.advertisedHost) .Values.sip.siteHost -}}
{{- end -}}

{{- define "avoip.sip.publicHost" -}}
{{- if .Values.sip.globalRouting.enabled -}}
{{- .Values.sip.globalHost -}}
{{- else -}}
{{- include "avoip.sip.siteHost" . -}}
{{- end -}}
{{- end -}}

{{- define "avoip.sip.serviceHost" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $override := .override | default "" -}}
{{- $serviceName := printf "%s-%s" (include "avoip.fullname" $root) $component -}}
{{- if hasPrefix "kamailio" $component -}}
  {{- $instance := $root.Values.kamailio -}}
  {{- if hasKey $instance "instances" -}}
    {{- range (include "avoip.kamailio.instances" $root | fromYamlArray) -}}
      {{- if eq (include "avoip.kamailio.component" .) $component -}}{{- $instance = . -}}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $serviceName = include "avoip.kamailio.resourceName" (dict "root" $root "instance" $instance) -}}
{{- end -}}
{{- if and (not $override) (not (hasPrefix "kamailio" $component)) -}}
  {{- $override = index (index $root.Values $component) "sip" "serviceHost" -}}
{{- else if and (not $override) (eq $component "kamailio") (hasKey $root.Values.kamailio "instances") -}}
  {{- range (include "avoip.kamailio.instances" $root | fromYamlArray) -}}
    {{- if eq .name "carrier" -}}{{- $override = .sip.serviceHost -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- default (printf "%s.%s.svc.%s" $serviceName $root.Release.Namespace (required "cluster.domain is required for SIP service identities" $root.Values.cluster.domain)) $override -}}
{{- end -}}

{{- define "avoip.sip.kamailioPubHost" -}}
{{- $root := . -}}
{{- $kamailio := $root.Values.kamailio -}}
{{- if hasKey $kamailio "instances" -}}
  {{- range (include "avoip.kamailio.instances" $root | fromYamlArray) -}}
    {{- if eq .name "carrier" -}}{{- $kamailio = . -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- $component := include "avoip.kamailio.component" $kamailio -}}
{{- default (printf "%s-pub.%s.%s.%s.resolvemy.host" $component $root.Values.cluster.name $root.Values.datacenter $root.Values.region) $kamailio.publicExposure.sip.directService.hostname -}}
{{- end -}}

{{/* Merge shared and per-Service metadata while retaining chart-required defaults. */}}
{{- define "avoip.service.type" -}}
{{- $root := .root -}}
{{- $serviceOptions := index ($root.Values.serviceOptions | default dict) .name | default dict -}}
{{- $defaultOptions := index ($root.Values.serviceOptions | default dict) "defaults" | default dict -}}
{{- default (default $defaultOptions.type $serviceOptions.type) (.type | default "") -}}
{{- end -}}

{{- define "avoip.service.options" -}}
{{- $root := .root -}}
{{- $serviceOptions := index ($root.Values.serviceOptions | default dict) .name | default dict -}}
{{- $defaultOptions := index ($root.Values.serviceOptions | default dict) "defaults" | default dict -}}
{{- $annotations := mergeOverwrite (deepCopy (.annotations | default dict)) (deepCopy ($defaultOptions.annotations | default dict)) (deepCopy ($serviceOptions.annotations | default dict)) -}}
{{- if .preferInstance -}}
  {{- $annotations = mergeOverwrite (deepCopy ($defaultOptions.annotations | default dict)) (deepCopy ($serviceOptions.annotations | default dict)) (deepCopy (.annotations | default dict)) -}}
{{- end -}}
{{- $labels := mergeOverwrite (deepCopy ($defaultOptions.labels | default dict)) (deepCopy ($serviceOptions.labels | default dict)) (deepCopy (.labels | default dict)) -}}
{{- $type := include "avoip.service.type" . | trim -}}
{{- if $annotations }}
annotations:
{{- toYaml $annotations | nindent 2 }}
{{- end }}
{{- if $labels }}
labels:
{{- toYaml $labels | nindent 2 }}
{{- end }}
{{- with $type }}
type: '{{ . }}'
{{- end }}
{{- if eq $type "LoadBalancer" }}
{{- $loadBalancerClass := default (default $defaultOptions.loadBalancerClass $serviceOptions.loadBalancerClass) (.loadBalancerClass | default "") -}}
{{- with $loadBalancerClass }}
loadBalancerClass: '{{ . }}'
{{- end }}
{{- end }}
{{- end -}}

{{- define "avoip.homer.hostname" -}}
{{- $override := .Values.homer.hostname -}}
{{- default (printf "homer.%s.%s.%s.resolvemy.host" .Values.cluster.name .Values.datacenter .Values.region) $override -}}
{{- end -}}

{{- define "avoip.talkHpb.enabled" -}}
{{- if and .Values.talkHpb.enabled (eq .Values.cluster.name .Values.talkHpb.clusterName) -}}true{{- end -}}
{{- end -}}
