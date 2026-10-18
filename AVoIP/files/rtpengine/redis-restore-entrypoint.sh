#!/bin/sh
set -eu

restore_marker="${RTPENGINE_RESTORE_MARKER:-/tmp/rtpengine-redis-restored}"
output_pipe="${RTPENGINE_RESTORE_OUTPUT_PIPE:-/tmp/rtpengine-redis-restore-output}"
rm -f "$restore_marker" "$output_pipe"

if [ "${RTPENGINE_REDIS_RESTORE_REQUIRED:-false}" != true ]; then
  exec "$@"
fi

mkfifo "$output_pipe"
"$@" >"$output_pipe" 2>&1 &
engine_pid=$!
trap 'kill -TERM "$engine_pid" 2>/dev/null || true' TERM INT

while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line"
  case "$line" in
    *'Redis restore time ='*' ms'*)
      : > "$restore_marker"
      ;;
  esac
done < "$output_pipe"

set +e
wait "$engine_pid"
engine_status=$?
set -e
rm -f "$output_pipe"
exit "$engine_status"
