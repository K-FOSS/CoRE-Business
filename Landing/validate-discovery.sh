#!/usr/bin/env bash
set -euo pipefail

base_url="${BASE_URL:-https://mylogin.space}"
mastodon_url="${MASTODON_URL:-https://mastodon.mylogin.space}"
matrix_url="${MATRIX_URL:-https://matrix.mylogin.space}"
webfinger_resource="${WEBFINGER_RESOURCE:-acct:kjones@mastodon.mylogin.space}"
release_name="${RELEASE_NAME:-core-home1-talos-prod-business-landing-prod}"
namespace="${NAMESPACE:-core-prod}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

request() {
  local name="$1"
  local url="$2"
  curl --silent --show-error --max-redirs 0 \
    --dump-header "${tmp_dir}/${name}.headers" \
    --output "${tmp_dir}/${name}.body" \
    --write-out '%{http_code}' "${url}" || true
}

header() {
  awk -F': ' -v key="$1" 'tolower($1) == tolower(key) { sub(/\r$/, "", $2); print $2; exit }' "$2"
}

assert_status() {
  test "$2" = "$1" || { echo "${3}: expected HTTP ${1}, got ${2}" >&2; exit 1; }
}

assert_no_redirect() {
  case "$1" in
    3*) echo "${2}: unexpected redirect" >&2; exit 1 ;;
  esac
}

check_static() {
  local name="$1" url="$2" content_type="$3"
  local status
  status="$(request "$name" "$url")"
  assert_status 200 "$status" "$url"
  assert_no_redirect "$status" "$url"
  case "$(header Content-Type "${tmp_dir}/${name}.headers")" in
    "${content_type}"*) ;;
    *)
    echo "${url}: unexpected Content-Type" >&2; exit 1;
    ;;
  esac
}

check_static security "${base_url}/.well-known/security.txt" 'text/plain'
grep -Fq 'Canonical: https://mylogin.space/.well-known/security.txt' "${tmp_dir}/security.body"

check_static matrix_client "${base_url}/.well-known/matrix/client" 'application/json'
check_static matrix_server "${base_url}/.well-known/matrix/server" 'application/json'
grep -Eqi '^access-control-allow-origin: \*' "${tmp_dir}/matrix_client.headers"
grep -Eqi '^access-control-allow-origin: \*' "${tmp_dir}/matrix_server.headers"
jq -e '.m.homeserver.base_url == "https://matrix.mylogin.space"' "${tmp_dir}/matrix_client.body" >/dev/null
jq -e '.m.server == "matrix.mylogin.space:443"' "${tmp_dir}/matrix_server.body" >/dev/null

status="$(request webfinger "${mastodon_url}/.well-known/webfinger?resource=$(printf '%s' "$webfinger_resource" | sed 's/@/%40/g')")"
assert_status 200 "$status" 'Mastodon WebFinger'
assert_no_redirect "$status" 'Mastodon WebFinger'
jq -e 'type == "object" and (.links | type == "array")' "${tmp_dir}/webfinger.body" >/dev/null

status="$(request nodeinfo "${mastodon_url}/.well-known/nodeinfo")"
assert_status 200 "$status" 'Mastodon NodeInfo discovery'
assert_no_redirect "$status" 'Mastodon NodeInfo discovery'
jq -e 'type == "object" and (.links | type == "array")' "${tmp_dir}/nodeinfo.body" >/dev/null

status="$(request forecastle "${base_url}/")"
assert_status 200 "$status" 'Forecastle'
assert_no_redirect "$status" 'Forecastle'

status="$(request matrix_login "${matrix_url}/_matrix/client/versions")"
assert_status 200 "$status" 'Matrix login API'
assert_no_redirect "$status" 'Matrix login API'
jq -e '(.versions | type) == "array"' "${tmp_dir}/matrix_login.body" >/dev/null

if command -v kubectl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  for route_name in "${release_name}-discovery" "${release_name}-mastodon-discovery" landing; do
    route_json="$(kubectl -n "${namespace}" get httproute "${route_name}" -o json)"
    jq -e '.status.parents | any(.[]; .conditions | any(.[]; .type == "Accepted" and .status == "True"))' \
      <<<"${route_json}" >/dev/null
    jq -e '.status.parents | any(.[]; .conditions | any(.[]; .type == "ResolvedRefs" and .status == "True"))' \
      <<<"${route_json}" >/dev/null
  done
fi

echo 'Discovery endpoint validation passed.'
