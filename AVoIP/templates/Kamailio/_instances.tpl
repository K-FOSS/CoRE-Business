{{/* Resolve instance values without mutating shared Helm dictionaries. Lists replace. */}}
{{- define "avoip.kamailio.instances" -}}
{{- $seen := dict -}}
{{- $redisDatabases := dict -}}
{{- $redisSecrets := dict -}}
{{- $out := list -}}
{{- range $raw := .Values.kamailio.instances -}}
  {{- $name := required "kamailio.instances[].name is required" $raw.name -}}
  {{- if or (gt (len $name) 24) (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
    {{- fail (printf "invalid Kamailio instance name %q: use a DNS label of at most 24 characters" $name) -}}
  {{- end -}}
  {{- if hasKey $seen $name -}}{{- fail (printf "duplicate Kamailio instance name %q" $name) -}}{{- end -}}
  {{- $_ := set $seen $name true -}}
  {{- $role := required (printf "kamailio instance %s requires role" $name) $raw.role -}}
  {{- if not (has $role (list "carrier-sbc" "private-sbc")) -}}
    {{- fail (printf "unsupported Kamailio role %q for %s (endpoint registration is not implemented)" $role $name) -}}
  {{- end -}}
  {{- if and (eq $name "carrier") (ne $role "carrier-sbc") -}}
    {{- fail "Kamailio instance carrier must use role carrier-sbc to preserve the existing SBC identity" -}}
  {{- end -}}
  {{- if and (eq $role "carrier-sbc") (ne $name "carrier") -}}
    {{- fail "Only the carrier instance may use role carrier-sbc; public SIP identity is site-scoped" -}}
  {{- end -}}
  {{- $roleDefaults := index $.Values.kamailio.roleDefaults $role | default dict -}}
  {{- $effective := mergeOverwrite (deepCopy $.Values.kamailio.defaults) (deepCopy $roleDefaults) (deepCopy $raw) -}}
  {{- if not $effective.serviceAccountName -}}{{- fail (printf "Kamailio %s requires serviceAccountName" $name) -}}{{- end -}}
  {{- if and $effective.enabled (lt (int $effective.replicas) 1) -}}{{- fail (printf "Kamailio %s requires at least one replica" $name) -}}{{- end -}}
  {{- range $reserved := list "app" "avoip.mylogin.space/kamailio-instance" "app.kubernetes.io/controller" -}}
    {{- if hasKey ($effective.podLabels | default dict) $reserved -}}{{- fail (printf "Kamailio %s podLabels may not override %s" $name $reserved) -}}{{- end -}}
  {{- end -}}
  {{- $envNames := dict "POD_NAME" true "TOPOS_REDIS_SERVER" true -}}
  {{- range $entry := $effective.extraEnv -}}
    {{- $envName := required (printf "Kamailio %s extraEnv entry requires name" $name) $entry.name -}}
    {{- if hasKey $envNames $envName -}}{{- fail (printf "Kamailio %s has duplicate or reserved environment variable %s" $name $envName) -}}{{- end -}}
    {{- $_ := set $envNames $envName true -}}
  {{- end -}}
  {{- $functions := $effective.functions | default dict -}}
  {{- range $required := list "sanity" "classification" "transactions" "dialog" "authorization" "recordRoute" "backendSelection" "topology" -}}
    {{- if not (index $functions $required) -}}
      {{- fail (printf "Kamailio %s role %s requires function %s" $name $role $required) -}}
    {{- end -}}
  {{- end -}}
  {{- if and (eq $role "carrier-sbc") (or (not $functions.media) (not $effective.publicExposure.enabled)) -}}
    {{- fail (printf "Kamailio %s carrier-sbc requires media and public exposure" $name) -}}
  {{- end -}}
  {{- if and (eq $role "carrier-sbc") $effective.carrierOutbound.enabled -}}
    {{- fail "carrierOutbound cannot be enabled before authenticated peer ingress, destination authorization and quotas are implemented" -}}
  {{- end -}}
  {{- if and (eq $role "private-sbc") $effective.publicExposure.enabled -}}
    {{- fail (printf "Kamailio %s private-sbc must not expose public SIP" $name) -}}
  {{- end -}}
  {{- if eq $role "private-sbc" -}}
    {{- if gt (int $effective.replicas) 1 -}}
      {{- fail (printf "Kamailio %s private-sbc must start with one replica until dialog affinity is validated" $name) -}}
    {{- end -}}
    {{- $sets := dict -}}
    {{- range $destination := $effective.privateRouting.destinations -}}
      {{- if or (lt (int $destination.setId) 1) (not (regexMatch "^sips:[a-zA-Z0-9.-]+:[0-9]+$" (toString $destination.uri))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $destination.controller))) -}}
        {{- fail (printf "Kamailio %s privateRouting destination requires a positive setId, literal sips host:port and controller" $name) -}}
      {{- end -}}
      {{- $_ := set $sets (toString $destination.setId) true -}}
    {{- end -}}
    {{- range $route := $effective.privateRouting.routes -}}
      {{- if or (not (regexMatch "^[0-9]{2,8}$" (toString $route.user))) (not (hasKey $sets (toString $route.setId))) -}}
        {{- fail (printf "Kamailio %s privateRouting route requires a numeric user and configured destination set" $name) -}}
      {{- end -}}
    {{- end -}}
    {{- range $peer := $effective.privateRouting.peers -}}
      {{- if or (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $peer.name))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $peer.controller))) (not (regexMatch "^[0-9a-fA-F:.]+/[0-9]{1,3}$" (toString $peer.cidr))) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $peer.sanHostname))) -}}
        {{- fail (printf "Kamailio %s privateRouting peer requires name, controller, literal CIDR and certificate sanHostname" $name) -}}
      {{- end -}}
      {{- range $user := $peer.allowedUsers -}}
        {{- if not (regexMatch "^[0-9]{2,8}$" (toString $user)) -}}
          {{- fail (printf "Kamailio %s privateRouting peer %s allowedUsers must contain only numeric extensions" $name $peer.name) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if ne (toString $functions.topology) (toString $effective.topology.enabled) -}}
    {{- fail (printf "Kamailio %s functions.topology and topology.enabled must agree" $name) -}}
  {{- end -}}
  {{- if and $effective.enabled $effective.topology.enabled -}}
    {{- if and (eq $role "private-sbc") (or (eq (int $effective.topology.redis.database) 51) (eq $effective.topology.redis.secretName "avoip-kamailio-topos")) -}}
      {{- fail (printf "Kamailio %s private-sbc requires a dedicated TOPOS database and Secret" $name) -}}
    {{- end -}}
    {{- if not $effective.topology.redis.secretName -}}{{- fail (printf "Kamailio %s requires topology.redis.secretName" $name) -}}{{- end -}}
    {{- if hasKey $redisSecrets $effective.topology.redis.secretName -}}{{- fail (printf "Kamailio %s shares TOPOS Secret %s with %s" $name $effective.topology.redis.secretName (index $redisSecrets $effective.topology.redis.secretName)) -}}{{- end -}}
    {{- $_ := set $redisSecrets $effective.topology.redis.secretName $name -}}
    {{- if not $effective.topology.redis.serverKey -}}{{- fail (printf "Kamailio %s requires topology.redis.serverKey" $name) -}}{{- end -}}
    {{- if lt (int $effective.topology.redis.database) 1 -}}{{- fail (printf "Kamailio %s requires a non-zero TOPOS database" $name) -}}{{- end -}}
    {{- $db := toString $effective.topology.redis.database -}}
    {{- if hasKey $redisDatabases $db -}}
      {{- fail (printf "Kamailio %s shares TOPOS database %s with %s; assign a separate site-local database" $name $db (index $redisDatabases $db)) -}}
    {{- end -}}
    {{- $_ := set $redisDatabases $db $name -}}
  {{- end -}}
  {{- $out = append $out $effective -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- define "avoip.kamailio.carrier.enabled" -}}
{{- range (include "avoip.kamailio.instances" . | fromYamlArray) -}}
  {{- if and .enabled (eq .name "carrier") (eq .role "carrier-sbc") -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{- define "avoip.kamailio.enabled" -}}
{{- range (include "avoip.kamailio.instances" . | fromYamlArray) -}}
  {{- if .enabled -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{- define "avoip.kamailio.component" -}}
{{- if eq .name "carrier" -}}kamailio{{- else -}}kamailio-{{ .name }}{{- end -}}
{{- end -}}

{{- define "avoip.kamailio.resourceName" -}}
{{- $component := include "avoip.kamailio.component" .instance -}}
{{- $tail := $component -}}
{{- with .suffix -}}{{- $tail = printf "%s-%s" $tail . -}}{{- end -}}
{{- $base := include "avoip.fullname" .root -}}
{{- if eq .instance.name "carrier" -}}
  {{- printf "%s-%s" $base $tail -}}
{{- else -}}
{{- $available := sub 63 (add 1 (len $tail)) | int -}}
{{- if lt $available 1 -}}{{- fail (printf "Kamailio %s resource suffix is too long" .instance.name) -}}{{- end -}}
{{- printf "%s-%s" ($base | trunc $available | trimSuffix "-") $tail -}}
{{- end -}}
{{- end -}}
