#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart_dir="$repo_root/AVoIP"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

for site in dc1 home1; do
  case "$site" in
    dc1)
      release='core-dc1-talos-prod'
      fixture="$chart_dir/tests/fixtures/intersite-dc1.yaml"
      ;;
    home1)
      release='core-home1-talos-prod'
      fixture="$chart_dir/tests/fixtures/intersite-home1.yaml"
      ;;
  esac

  helm template "$release" "$chart_dir" --namespace core-prod -f "$fixture" > "$rendered"
  media_service="${release}-avoip-rtpengine-media"

  yq -e "select(.kind == \"Service\" and .metadata.name == \"$media_service\") | any(.spec.ports[]; .port == 11000 and .targetPort == 11000 and .protocol == \"UDP\") and any(.spec.ports[]; .port == 11000 and .targetPort == 11000 and .protocol == \"TCP\") and any(.spec.ports[]; .port == 13049 and .targetPort == 13049 and .protocol == \"UDP\") and any(.spec.ports[]; .port == 13049 and .targetPort == 13049 and .protocol == \"TCP\")" "$rendered" >/dev/null
  yq -e "select(.kind == \"CiliumNetworkPolicy\" and .metadata.name == \"${release}-avoip-rtpengine-ingress\") | any(.spec.ingress[]; any(.fromEntities[]?; . == \"world\") and any(.toPorts[]?; any(.ports[]?; .port == \"11000\" and .endPort == 13049 and .protocol == \"UDP\") and any(.ports[]?; .port == \"11000\" and .endPort == 13049 and .protocol == \"TCP\")))" "$rendered" >/dev/null
done

printf '%s\n' 'PASS: both site media Services publish the configured RTP range over UDP and TCP'
printf '%s\n' 'PASS: both site Cilium policies allow UDP and TCP media ingress over that range'
