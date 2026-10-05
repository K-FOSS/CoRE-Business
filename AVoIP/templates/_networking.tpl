{{/* Apply optional independent workloads and network overrides before BJW-S rendering. */}}
{{- define "avoip.networking.apply" -}}
{{- $root := . -}}
{{- if not .Values.rawResources -}}{{- $_ := set .Values "rawResources" dict -}}{{- end -}}
{{- if not .Values.configMaps -}}{{- $_ := set .Values "configMaps" dict -}}{{- end -}}
{{- $profiles := deepCopy .Values.workloadNetworking -}}
{{- $functions := deepCopy .Values.functions -}}
{{- if include "avoip.talkHpb.enabled" $root | trim -}}
{{- $talkHpb := $root.Values.talkHpb -}}
{{- $controller := dict
  "replicas" 1
  "strategy" "Recreate"
  "revisionHistoryLimit" 3
  "pod" (dict
    "securityContext" (dict "runAsNonRoot" true "runAsUser" 1000 "runAsGroup" 1000 "fsGroup" 1000 "seccompProfile" (dict "type" "RuntimeDefault"))
    "labels" (dict "app" (printf "%s-talk-hpb" (include "avoip.fullname" $root)))
    "annotations" (dict
      "kubectl.kubernetes.io/default-container" "talk-hpb"
      "secret.reloader.stakater.com/reload" (printf "%s,%s" $talkHpb.secrets.name $talkHpb.secrets.turnName)))
  "containers" (dict "talk-hpb" (dict
    "image" (dict "repository" $talkHpb.image.repository "tag" $talkHpb.image.tag "pullPolicy" $talkHpb.image.pullPolicy)
    "env" (dict
      "NC_DOMAIN" $talkHpb.nextcloudHostname
      "TALK_HOST" $talkHpb.mediaHostname
      "TALK_PORT" (toString $talkHpb.turn.port)
      "TURN_DOMAIN" $talkHpb.mediaHostname
      "AIO_LOG_LEVEL" "warn"
      "SIGNALING_SECRET" (dict "valueFrom" (dict "secretKeyRef" (dict "name" $talkHpb.secrets.name "key" "SIGNALING_SECRET")))
      "INTERNAL_SECRET" (dict "valueFrom" (dict "secretKeyRef" (dict "name" $talkHpb.secrets.name "key" "INTERNAL_SECRET")))
      "TURN_SECRET" (dict "valueFrom" (dict "secretKeyRef" (dict "name" $talkHpb.secrets.turnName "key" "TURN_SECRET"))))
    "ports" (list (dict "name" "signaling" "containerPort" 8081 "protocol" "TCP"))
    "securityContext" (dict "allowPrivilegeEscalation" false "capabilities" (dict "drop" (list "ALL"))))) -}}
{{- $_ := set (get (get $controller "containers") "talk-hpb") "probes" (dict
  "startup" (dict "enabled" true "custom" true "spec" (dict "exec" (dict "command" (list "/healthcheck.sh")) "periodSeconds" 5 "timeoutSeconds" 30 "failureThreshold" 36))
  "readiness" (dict "enabled" true "custom" true "spec" (dict "exec" (dict "command" (list "/healthcheck.sh")) "periodSeconds" 30 "timeoutSeconds" 30 "failureThreshold" 3))
  "liveness" (dict "enabled" true "custom" true "spec" (dict "exec" (dict "command" (list "/healthcheck.sh")) "periodSeconds" 30 "timeoutSeconds" 30 "failureThreshold" 3))) -}}
{{- $services := dict
  "signaling" (dict "ports" (dict "http" (dict "port" 8081 "targetPort" "signaling" "protocol" "TCP")))
  "media" (dict "ports" (dict
    "turn-tcp" (dict "port" $talkHpb.turn.port "targetPort" $talkHpb.turn.port "protocol" "TCP")
    "turn-udp" (dict "port" $talkHpb.turn.port "targetPort" $talkHpb.turn.port "protocol" "UDP"))) -}}
{{- $mediaOptions := index $root.Values.serviceOptions "talk-hpb-media" | default dict -}}
{{- $mediaService := get $services "media" -}}
{{- $_ := mergeOverwrite $mediaService (pick $mediaOptions "type" "annotations" "labels" "loadBalancerClass") -}}
{{- if eq $mediaOptions.type "LoadBalancer" -}}{{- $_ := set $mediaService "externalTrafficPolicy" "Local" -}}{{- end -}}
{{- $networking := dict "initContainers" (dict "wait-for-media-host" (dict
  "image" (dict "repository" $root.Values.diagnostics.netshoot.image.repository "tag" $root.Values.diagnostics.netshoot.image.tag "digest" $root.Values.diagnostics.netshoot.image.digest "pullPolicy" $root.Values.diagnostics.netshoot.image.pullPolicy)
  "command" (list "/bin/sh" "-c")
  "args" (list (printf "until getent ahostsv4 %s >/dev/null; do sleep 2; done" $talkHpb.mediaHostname)))) -}}
{{- $function := dict "name" "talk-hpb" "enabled" true "controller" $controller "services" $services "networking" $networking -}}
{{- $functions = append $functions $function -}}
{{- end -}}
{{- range $function := $functions -}}
{{- if (dig "enabled" true $function) -}}
{{- $name := required "functions[].name is required" $function.name -}}
{{- if not (regexMatch "^[a-z][a-z0-9-]*$" $name) -}}{{- fail "function names must be lowercase DNS labels" -}}{{- end -}}
{{- if hasKey $root.Values.controllers $name -}}{{- fail (printf "function %s conflicts with an existing controller" $name) -}}{{- end -}}
{{- $_ := set $root.Values.controllers $name (deepCopy (required "functions[].controller is required" $function.controller)) -}}
{{- range $id, $service := default dict $function.services -}}
{{- $key := printf "%s-%s" $name $id -}}
{{- $svc := deepCopy $service -}}{{- $_ := set $svc "controller" $name -}}
{{- if eq $name "talk-hpb" -}}{{- $_ := set $svc "forceRename" (printf "avoip-talk-hpb-%s" $id) -}}{{- end -}}
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
