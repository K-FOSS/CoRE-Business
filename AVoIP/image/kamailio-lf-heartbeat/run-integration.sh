#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: run-integration.sh IMAGE [docker|podman]}"
engine="${2:-docker}"
container_name="kamailio-lf-heartbeat-test"
trap '"$engine" rm -f "$container_name" >/dev/null 2>&1 || true' EXIT

start_server() {
  local config_name="$1"
  "$engine" rm -f "$container_name" >/dev/null 2>&1 || true
  "$engine" run -d --name "$container_name" -p 127.0.0.1:18088:8088 \
    --entrypoint kamailio "$image" -DD -E -f "/opt/kamailio-lf-heartbeat/$config_name" >/dev/null
  for _ in $(seq 1 50); do
    if ! "$engine" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; then
      "$engine" logs "$container_name" >&2
      return 1
    fi
    if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(.2); r=s.connect_ex(("127.0.0.1",18088)); s.close(); sys.exit(r)' 2>/dev/null; then
      sleep 0.2
      if "$engine" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true \
        && python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(.2); r=s.connect_ex(("127.0.0.1",18088)); s.close(); sys.exit(r)' 2>/dev/null; then
        return 0
      fi
    fi
    sleep 0.2
  done
  "$engine" logs "$container_name" >&2
  return 1
}

start_server test-kamailio.cfg
python3 "$(dirname "${BASH_SOURCE[0]}")/test_websocket.py" ws://127.0.0.1:18088/ws \
  --host 127.0.0.1:18088 --origin https://home.mylogin.space
"$engine" rm -f "$container_name" >/dev/null

start_server test-kamailio-disabled.cfg
python3 "$(dirname "${BASH_SOURCE[0]}")/test_websocket.py" ws://127.0.0.1:18088/ws \
  --host 127.0.0.1:18088 --origin https://home.mylogin.space --disabled
