#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template core-home1-talos-prod "$repo_root/AVoIP" \
  --namespace core-prod \
  -f "$repo_root/AVoIP/tests/fixtures/outbound-teardown.yaml" > "$rendered"

config="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-audio-library") | .data["default.conf"]' "$rendered")"
grep -Fqx '  location ~ "^/audio-library/files/(?<audio_file>[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.wav)$" {' <<< "$config"
grep -Fqx '  location = /audio-library/ {' <<< "$config"
grep -Fqx '    alias /usr/share/nginx/html/;' <<< "$config"
grep -Fqx '    index index.html;' <<< "$config"
grep -Fqx '    alias /var/lib/avoip/sounds/$audio_file;' <<< "$config"
grep -Fqx '    dav_methods PUT;' <<< "$config"
grep -Fqx '    limit_except GET HEAD PUT { deny all; }' <<< "$config"
grep -Fqx '  location = /audio-library/files/ {' <<< "$config"
grep -Fqx '    limit_except GET { deny all; }' <<< "$config"

app="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "core-home1-talos-prod-avoip-audio-library") | .data["app.js"]' "$rendered")"
grep -Fq '/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/' <<< "$app"

echo 'PASS: sound-library NGINX config renders a quoted 64-character WAV regex and preserves read/write access rules'
