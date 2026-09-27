{{/* Apply optional independent workloads and network overrides before BJW-S rendering. */}}
{{- define "avoip.networking.apply" -}}
{{- $root := . -}}
{{- if not .Values.rawResources -}}{{- $_ := set .Values "rawResources" dict -}}{{- end -}}
{{- if not .Values.configMaps -}}{{- $_ := set .Values "configMaps" dict -}}{{- end -}}
{{- $profiles := deepCopy .Values.workloadNetworking -}}
{{- range $function := .Values.functions -}}
{{- if (dig "enabled" true $function) -}}
{{- $name := required "functions[].name is required" $function.name -}}
{{- if not (regexMatch "^[a-z][a-z0-9-]*$" $name) -}}{{- fail "function names must be lowercase DNS labels" -}}{{- end -}}
{{- if hasKey $root.Values.controllers $name -}}{{- fail (printf "function %s conflicts with an existing controller" $name) -}}{{- end -}}
{{- $_ := set $root.Values.controllers $name (deepCopy (required "functions[].controller is required" $function.controller)) -}}
{{- range $id, $service := default dict $function.services -}}
{{- $key := printf "%s-%s" $name $id -}}
{{- $svc := deepCopy $service -}}{{- $_ := set $svc "controller" $name -}}
{{- $_ := set $root.Values.service $key $svc -}}
{{- end -}}
{{- range $id, $volume := default dict $function.persistence -}}
{{- $_ := set $root.Values.persistence (printf "%s-%s" $name $id) (deepCopy $volume) -}}
{{- end -}}
{{- range $id, $config := default dict $function.configMaps -}}
{{- $_ := set $root.Values.configMaps (printf "%s-%s" $name $id) (deepCopy $config) -}}
{{- end -}}
{{- with $function.networking -}}{{- $_ := set $profiles $name . -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- range $name, $profile := $profiles -}}
{{- if hasKey $root.Values.controllers $name -}}
{{- $controller := get $root.Values.controllers $name -}}
{{- $pod := default dict $controller.pod -}}
{{- range $key := list "nodeSelector" "affinity" "tolerations" "dnsPolicy" "dnsConfig" -}}
{{- if hasKey $profile $key -}}{{- $_ := set $pod $key (get $profile $key) -}}{{- end -}}
{{- end -}}
{{- $annotations := default dict $pod.annotations -}}
{{- $attachments := list -}}
{{- $resources := dict -}}
{{- range $index, $interface := default list $profile.interfaces -}}
{{- $nadName := printf "%s-%s-net-%d" (include "avoip.fullname" $root | trunc 40 | trimSuffix "-") $name $index -}}
{{- $device := default (printf "eth%d" (add $index 1)) $interface.name -}}
{{- $selection := dict "name" (default $nadName $interface.networkAttachment) "interface" $device -}}
{{- with $interface.namespace -}}{{- $_ := set $selection "namespace" . -}}{{- end -}}
{{- with $interface.macAddress -}}{{- $_ := set $selection "mac" . -}}{{- end -}}
{{- if and (eq $index 0) (dig "replaceDefaultNetwork" false $profile) -}}
{{- $_ := set $annotations "v1.multus-cni.io/default-network" (printf "%s/%s" (default $root.Release.Namespace $interface.namespace) (get $selection "name")) -}}
{{- else -}}{{- $attachments = append $attachments $selection -}}{{- end -}}
{{- if not $interface.networkAttachment -}}
{{- $config := deepCopy (required "interfaces[].cni is required unless networkAttachment is specified" $interface.cni) -}}
{{- $_ := set $config "name" $nadName -}}
{{- $_ := set $config "cniVersion" (default "1.0.0" $config.cniVersion) -}}
{{- $metadata := dict "name" $nadName -}}
{{- with $interface.resourceName -}}
{{- $_ := set $metadata "annotations" (dict "k8s.v1.cni.cncf.io/resourceName" .) -}}
{{- end -}}
{{- $raw := dict "apiVersion" "k8s.cni.cncf.io/v1" "kind" "NetworkAttachmentDefinition" "metadata" $metadata "spec" (dict "config" (toJson $config)) -}}
{{- $_ := set $root.Values.rawResources $nadName (dict "forceRename" $nadName "manifest" $raw) -}}
{{- end -}}
{{- with $interface.resourceName -}}{{- $_ := set $resources . (add 1 (default 0 (get $resources .))) -}}{{- end -}}
{{- end -}}
{{- if $attachments -}}{{- $_ := set $annotations "k8s.v1.cni.cncf.io/networks" (toJson $attachments) -}}{{- end -}}
{{- $_ := set $pod "annotations" $annotations -}}
{{- $_ := set $controller "pod" $pod -}}
{{- if $resources -}}
{{- $containerName := default $name $profile.resourceContainer -}}
{{- $container := required "resourceContainer must identify an existing container" (get $controller.containers $containerName) -}}
{{- $containerResources := default dict $container.resources -}}
{{- $_ := set $containerResources "limits" (mergeOverwrite (default dict $containerResources.limits) $resources) -}}
{{- $_ := set $containerResources "requests" (mergeOverwrite (default dict $containerResources.requests) $resources) -}}
{{- $_ := set $container "resources" $containerResources -}}
{{- end -}}
{{- with $profile.initContainers -}}
{{- $_ := set $controller "initContainers" (mergeOverwrite (default dict $controller.initContainers) (deepCopy .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
