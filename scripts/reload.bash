#!/usr/bin/env bash

set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rirl-tls-validation-nginx}"

if ! command -v docker >/dev/null 2>&1; then
    printf 'ERROR: required command not found: docker\n' >&2
    exit 1
fi

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    printf 'ERROR: container not found: %s\n' "${CONTAINER_NAME}" >&2
    exit 1
fi

if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" != 'true' ]]; then
    printf 'ERROR: container is not running: %s\n' "${CONTAINER_NAME}" >&2
    exit 1
fi

printf 'Validating nginx configuration...\n'

docker exec \
    "${CONTAINER_NAME}" \
    nginx -t

printf 'Reloading nginx...\n'

docker exec \
    "${CONTAINER_NAME}" \
    nginx -s reload

printf 'Refreshing certificate status...\n'

docker exec \
    "${CONTAINER_NAME}" \
    /usr/local/bin/cert-status

printf 'nginx reload and certificate-status refresh completed successfully.\n'
