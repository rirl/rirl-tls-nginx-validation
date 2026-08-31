#!/usr/bin/env bash

set -Eeuo pipefail

RUNTIME_CONFIG="${RUNTIME_CONFIG:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/generated/runtime.env}"

if [[ ! -r "${RUNTIME_CONFIG}" ]]; then
    printf 'ERROR: runtime configuration not found: %s\n' "${RUNTIME_CONFIG}" >&2
    printf 'ERROR: run terraform apply before using this script.\n' >&2
    exit 1
fi

CONTAINER_NAME_OVERRIDE="${CONTAINER_NAME-}"

# shellcheck source=/dev/null
source "${RUNTIME_CONFIG}"

[[ -n "${CONTAINER_NAME_OVERRIDE}" ]] && CONTAINER_NAME="${CONTAINER_NAME_OVERRIDE}"

: "${CONTAINER_NAME:?CONTAINER_NAME is not set}"

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
