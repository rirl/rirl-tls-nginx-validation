#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /run/cert-status
/usr/local/bin/cert-status --once || true

(
  while true; do
    sleep "${STATUS_REFRESH_SECONDS:-300}"
    /usr/local/bin/cert-status --once || true
  done
) &

exec nginx -g 'daemon off;'
