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
  {{- if or (lt (int $effective.shmSizeMb) 16) (gt (int $effective.shmSizeMb) 4096) -}}
    {{- fail (printf "Kamailio %s shmSizeMb must be between 16 and 4096" $name) -}}
  {{- end -}}
  {{- if not $effective.serviceAccountName -}}{{- fail (printf "Kamailio %s requires serviceAccountName" $name) -}}{{- end -}}
  {{- if and $effective.enabled (lt (int $effective.replicas) 1) -}}{{- fail (printf "Kamailio %s requires at least one replica" $name) -}}{{- end -}}
  {{- range $reserved := list "app" "avoip.mylogin.space/kamailio-instance" "app.kubernetes.io/controller" -}}
    {{- if hasKey ($effective.podLabels | default dict) $reserved -}}{{- fail (printf "Kamailio %s podLabels may not override %s" $name $reserved) -}}{{- end -}}
  {{- end -}}
  {{- $envNames := dict "POD_NAME" true "TOPOS_REDIS_SERVER" true "REGISTRAR_DB_URL" true -}}
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
  {{- if $effective.carrierOutbound.enabled -}}
    {{- $outbound := $effective.carrierOutbound -}}
    {{- if or (not $effective.topology.enabled) (and (eq $role "carrier-sbc") (not $functions.media)) (and (eq $role "private-sbc") $functions.media) (not $.Values.freeswitch.enabled) -}}
      {{- fail (printf "Kamailio %s carrierOutbound requires TOPOS, carrier-only media anchoring and FreeSWITCH" $name) -}}
    {{- end -}}
    {{- if or (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $outbound.gatewayServiceHost))) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $outbound.sniHost))) (not (regexMatch "^[0-9a-fA-F:.]+/[0-9]{1,3}$" (toString $outbound.peer.cidr))) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $outbound.peer.sanHostname))) -}}
      {{- fail (printf "Kamailio %s carrierOutbound requires a Gateway service host, SNI host, peer CIDR and peer certificate SAN" $name) -}}
    {{- end -}}
    {{- if or (not (regexMatch "^[0-9]{2,8}$" (toString $outbound.testRoute.extension))) (not (regexMatch "^\\+1[2-9][0-9]{2}[2-9][0-9]{6}$" (toString $outbound.testRoute.destination))) (not (regexMatch "^\\+1[2-9][0-9]{2}[2-9][0-9]{6}$" (toString $outbound.testRoute.callerId))) (hasPrefix "+1900" (toString $outbound.testRoute.destination)) (regexMatch "^\\+1[2-9][0-9]{2}976[0-9]{4}$" (toString $outbound.testRoute.destination)) -}}
      {{- fail (printf "Kamailio %s carrierOutbound test route requires an extension, non-premium NANP destination and NANP caller ID" $name) -}}
    {{- end -}}
    {{- if or (lt (int $outbound.limits.callsPerMinute) 1) (lt (int $outbound.limits.concurrentCalls) 1) (lt (int $outbound.limits.maxDurationSeconds) 60) -}}
      {{- fail (printf "Kamailio %s carrierOutbound requires positive rate/concurrency limits and at least 60 seconds max duration" $name) -}}
    {{- end -}}
    {{- if eq $role "carrier-sbc" -}}
      {{- if or (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $outbound.peer.serviceHost))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $outbound.peer.controller))) -}}
        {{- fail (printf "Kamailio %s carrierOutbound requires a private peer service host and controller" $name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and (eq $role "private-sbc") $effective.publicExposure.enabled -}}
    {{- fail (printf "Kamailio %s private-sbc must not expose public SIP" $name) -}}
  {{- end -}}
  {{- $sipCoreIngressInstance := default $.Values.asterisk.sipCore.kamailioInstance $.Values.asterisk.sipCore.ingressKamailioInstance -}}
  {{- if or (lt (int $effective.websocket.keepaliveTimeoutSeconds) 5) (gt (int $effective.websocket.keepaliveTimeoutSeconds) 600) -}}
    {{- fail (printf "Kamailio %s websocket.keepaliveTimeoutSeconds must be between 5 and 600" $name) -}}
  {{- end -}}
  {{- if not (has (int $effective.websocket.keepaliveMechanism) (list 0 1 2)) -}}
    {{- fail (printf "Kamailio %s websocket.keepaliveMechanism must be 0, 1 or 2" $name) -}}
  {{- end -}}
  {{- $effectiveWebsocketHA := $effective.websocketHA | default dict -}}
  {{- if and $effectiveWebsocketHA.enabled (ne (int $effectiveWebsocketHA.keepaliveMechanism) 2) -}}
    {{- fail (printf "Kamailio %s websocketHA requires websocketHA.keepaliveMechanism=2 to avoid closing flows when Ping/Pong frames are not returned" $name) -}}
  {{- end -}}
  {{- if $effective.registrar.enabled -}}
    {{- if or $effective.sipLogging.rawInbound $effective.sipLogging.postToposResponses $effective.sipLogging.carrierTraffic $effective.sipLogging.diagnostics.enabled $effective.sipLogging.diagnostics.sdp -}}
      {{- fail (printf "Kamailio %s registrar forbids raw SIP and diagnostic logging of Digest credentials" $name) -}}
    {{- end -}}
    {{- if or (ne $role "private-sbc") (not $effective.enabled) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $effective.registrar.realm))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $effective.registrar.database.username))) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $effective.registrar.database.host))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $effective.registrar.database.secretName))) -}}
      {{- fail (printf "Kamailio %s registrar requires an enabled private-sbc, realm and dedicated PostgreSQL host, username and Secret" $name) -}}
    {{- end -}}
    {{- if or (lt (int $effective.registrar.maxContacts) 1) (lt (int $effective.registrar.minExpires) 60) (lt (int $effective.registrar.maxExpires) (int $effective.registrar.minExpires)) -}}
      {{- fail (printf "Kamailio %s registrar requires positive contact and registration expiry limits" $name) -}}
    {{- end -}}
    {{- if eq $effective.registrar.database.secretName $effective.topology.redis.secretName -}}
      {{- fail (printf "Kamailio %s registrar database Secret must differ from TOPOS Secret" $name) -}}
    {{- end -}}
    {{- if not (regexMatch "^[a-z][a-z0-9-]*$" (toString $effective.registrar.accessPeerName)) -}}
      {{- fail (printf "Kamailio %s registrar requires a dedicated access peer" $name) -}}
    {{- end -}}
    {{- if not $effective.registrar.allowedUsers -}}
      {{- fail (printf "Kamailio %s registrar requires at least one authorized pilot AoR" $name) -}}
    {{- end -}}
    {{- range $user := $effective.registrar.allowedUsers -}}
      {{- if not (regexMatch "^[0-9]{2,8}$" (toString $user)) -}}
        {{- fail (printf "Kamailio %s registrar allowedUsers must contain numeric extensions" $name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $role "private-sbc" -}}
    {{- $wssHA := $effective.websocketHA | default dict -}}
    {{- if and $wssHA.legacyOwner (or $wssHA.enabled (gt (int $effective.replicas) 1) (not $.Values.asterisk.sipCore.enabled)) -}}
      {{- fail (printf "Kamailio %s websocketHA.legacyOwner requires a single-replica legacy private-sbc and enabled Asterisk SIP Core" $name) -}}
    {{- end -}}
    {{- if and (or $wssHA.enabled $wssHA.legacyOwner) $effective.securityContext.pod (or (not (hasKey $effective.securityContext.pod "fsGroup")) (ne (int $effective.securityContext.pod.fsGroup) 1000)) -}}
      {{- fail (printf "Kamailio %s websocketHA draining requires securityContext.pod.fsGroup=1000 so the non-root process can write the local drain marker and RPC socket" $name) -}}
    {{- end -}}
    {{- if and (gt (int $effective.replicas) 1) (not $wssHA.enabled) -}}
      {{- fail (printf "Kamailio %s private-sbc cannot use multiple replicas unless websocketHA.enabled is true; each WSS socket remains process-local" $name) -}}
    {{- end -}}
    {{- if $wssHA.enabled -}}
      {{- if or (lt (int $effective.replicas) 1) (gt (int $effective.replicas) 10) -}}
        {{- fail (printf "Kamailio %s websocketHA requires 1-10 replicas" $name) -}}
      {{- end -}}
      {{- if and (eq (int $effective.replicas) 1) (not $wssHA.pilot) -}}
        {{- fail (printf "Kamailio %s websocketHA with one replica is permitted only while websocketHA.pilot is true" $name) -}}
      {{- end -}}
      {{- if or (not $.Values.asterisk.enabled) (not $.Values.asterisk.sipCore.enabled) (and (ne $name $.Values.asterisk.sipCore.kamailioInstance) (ne $name $sipCoreIngressInstance) (not $wssHA.pilot)) -}}
        {{- fail (printf "Kamailio %s websocketHA requires Asterisk SIP Core enabled and selection as the return instance or WSS ingress, unless websocketHA.pilot is enabled" $name) -}}
      {{- end -}}
      {{- if or $effective.registrar.enabled (not $effective.enabled) -}}
        {{- fail (printf "Kamailio %s websocketHA requires an enabled private-sbc with the Kamailio registrar pilot disabled" $name) -}}
      {{- end -}}
      {{- $ownerServiceName := include "avoip.kamailio.resourceName" (dict "root" $ "instance" $effective "suffix" "owner") -}}
      {{- $ingressServiceName := include "avoip.kamailio.resourceName" (dict "root" $ "instance" $effective) -}}
      {{- if eq $ownerServiceName $ingressServiceName -}}
        {{- fail (printf "Kamailio %s websocketHA.ownerServiceName must differ from the Envoy-facing Service name %s" $name $ingressServiceName) -}}
      {{- end -}}
      {{- if ne (int $.Values.asterisk.sipCore.httpPort) 8088 -}}
        {{- fail (printf "Kamailio %s websocketHA requires asterisk.sipCore.httpPort=8088 to preserve the current Envoy backend contract" $name) -}}
      {{- end -}}
      {{- if and $wssHA.legacyReturnServiceName (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" $wssHA.legacyReturnServiceName)) -}}
        {{- fail (printf "Kamailio %s websocketHA.legacyReturnServiceName must be a DNS name" $name) -}}
      {{- end -}}
      {{- if or (lt (int $wssHA.drainSeconds) 10) (gt (int $wssHA.drainSeconds) 3600) -}}
        {{- fail (printf "Kamailio %s websocketHA.drainSeconds must be between 10 and 3600" $name) -}}
      {{- end -}}
      {{- if or (lt (int $wssHA.endpointRemovalDelaySeconds) 5) (gt (int $wssHA.endpointRemovalDelaySeconds) 60) -}}
        {{- fail (printf "Kamailio %s websocketHA.endpointRemovalDelaySeconds must be between 5 and 60" $name) -}}
      {{- end -}}
      {{- if lt (int $wssHA.terminationGracePeriodSeconds) (add (int $wssHA.drainSeconds) (add (int $wssHA.endpointRemovalDelaySeconds) 5)) -}}
        {{- fail (printf "Kamailio %s websocketHA.terminationGracePeriodSeconds must exceed drainSeconds plus endpointRemovalDelaySeconds by at least 5 seconds" $name) -}}
      {{- end -}}
      {{- if lt (int $wssHA.podDisruptionBudget.minAvailable) 1 -}}
        {{- fail (printf "Kamailio %s websocketHA.podDisruptionBudget.minAvailable must be at least 1" $name) -}}
      {{- end -}}
      {{- if gt (int $wssHA.podDisruptionBudget.minAvailable) (int $effective.replicas) -}}
        {{- fail (printf "Kamailio %s websocketHA.podDisruptionBudget.minAvailable cannot exceed replicas" $name) -}}
      {{- end -}}
      {{- if or (lt (int $wssHA.rolloutPartition) 0) (gt (int $wssHA.rolloutPartition) (int $effective.replicas)) -}}
        {{- fail (printf "Kamailio %s websocketHA.rolloutPartition must be between zero and replicas" $name) -}}
      {{- end -}}
    {{- end -}}
    {{- $sets := dict -}}
    {{- $routes := dict -}}
    {{- $peers := dict -}}
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
      {{- if hasKey $routes (toString $route.user) -}}
        {{- fail (printf "Kamailio %s privateRouting has duplicate route user %s" $name $route.user) -}}
      {{- end -}}
      {{- $_ := set $routes (toString $route.user) true -}}
    {{- end -}}
    {{- range $peer := $effective.privateRouting.peers -}}
      {{- if or (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $peer.name))) (not (regexMatch "^[a-z][a-z0-9-]*$" (toString $peer.controller))) (not (regexMatch "^[0-9a-fA-F:.]+/[0-9]{1,3}$" (toString $peer.cidr))) (not (regexMatch "^[a-zA-Z0-9.-]+$" (toString $peer.sanHostname))) -}}
        {{- fail (printf "Kamailio %s privateRouting peer requires name, controller, literal CIDR and certificate sanHostname" $name) -}}
      {{- end -}}
      {{- if hasKey $peers $peer.name -}}
        {{- fail (printf "Kamailio %s privateRouting has duplicate peer %s" $name $peer.name) -}}
      {{- end -}}
      {{- $_ := set $peers $peer.name true -}}
      {{- range $user := $peer.allowedUsers -}}
        {{- if not (regexMatch "^[0-9]{2,8}$" (toString $user)) -}}
          {{- fail (printf "Kamailio %s privateRouting peer %s allowedUsers must contain only numeric extensions" $name $peer.name) -}}
        {{- end -}}
        {{- if not (hasKey $routes (toString $user)) -}}
          {{- fail (printf "Kamailio %s privateRouting peer %s allowedUsers contains unconfigured extension %s" $name $peer.name $user) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- if $effective.registrar.enabled -}}
      {{- if not (hasKey $peers $effective.registrar.accessPeerName) -}}
        {{- fail (printf "Kamailio %s registrar access peer must be a configured mTLS privateRouting peer" $name) -}}
      {{- end -}}
    {{- end -}}
    {{- if $effective.carrierOutbound.enabled -}}
      {{- if or (not (hasKey $peers $effective.carrierOutbound.testRoute.peerName)) (not (hasKey $peers "carrier")) (eq $effective.carrierOutbound.testRoute.peerName "carrier") -}}
        {{- fail (printf "Kamailio %s carrierOutbound requires distinct test-origin and carrier mTLS peers" $name) -}}
      {{- end -}}
      {{- range $peer := $effective.privateRouting.peers -}}
        {{- if and (eq $peer.name "carrier") $peer.allowedUsers -}}
          {{- fail (printf "Kamailio %s carrier peer may not originate new extension calls" $name) -}}
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
    {{- $redisSecretName := $effective.topology.redis.secretName -}}
    {{- if hasKey $redisSecrets $redisSecretName -}}
      {{- $suggestedSecretName := printf "avoip-kamailio-%s-topos" $name -}}
      {{- if hasKey $redisSecrets $suggestedSecretName -}}
        {{- fail (printf "Kamailio %s TOPOS Secret %s is already used by %s and its instance-specific Secret %s is already used by %s" $name $redisSecretName (index $redisSecrets $redisSecretName) $suggestedSecretName (index $redisSecrets $suggestedSecretName)) -}}
      {{- end -}}
      {{- $redisSecretName = $suggestedSecretName -}}
      {{- $_ := set $effective.topology.redis "secretName" $redisSecretName -}}
    {{- end -}}
    {{- $_ := set $redisSecrets $redisSecretName $name -}}
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
{{- if and $.Values.asterisk.enabled $.Values.asterisk.sipCore.enabled $.Values.asterisk.sipCore.ingressKamailioInstance -}}
  {{- $ingressName := $.Values.asterisk.sipCore.ingressKamailioInstance -}}
  {{- $ingressInstanceFound := false -}}
  {{- range $instance := $out -}}
    {{- if and $instance.enabled (eq $instance.name $ingressName) (eq $instance.role "private-sbc") -}}
      {{- $ingressInstanceFound = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $ingressInstanceFound -}}
    {{- fail (printf "asterisk.sipCore.ingressKamailioInstance %s must name an enabled private-sbc instance" $ingressName) -}}
  {{- end -}}
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
