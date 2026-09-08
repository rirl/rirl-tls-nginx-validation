#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_CONFIG="${RUNTIME_CONFIG:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/generated/runtime.env}"

if [[ ! -r "${RUNTIME_CONFIG}" ]]; then
    printf 'ERROR: runtime configuration not found: %s\n' "${RUNTIME_CONFIG}" >&2
    printf 'ERROR: run terraform apply before using this script.\n' >&2
    exit 1
fi

TLS_HOSTNAME_OVERRIDE="${TLS_HOSTNAME-}"
HTTPS_HOST_IP_OVERRIDE="${HTTPS_HOST_IP-}"
HTTPS_HOST_PORT_OVERRIDE="${HTTPS_HOST_PORT-}"
CONTAINER_NAME_OVERRIDE="${CONTAINER_NAME-}"

# shellcheck source=/dev/null
source "${RUNTIME_CONFIG}"

[[ -n "${TLS_HOSTNAME_OVERRIDE}" ]] && TLS_HOSTNAME="${TLS_HOSTNAME_OVERRIDE}"
[[ -n "${HTTPS_HOST_IP_OVERRIDE}" ]] && HTTPS_HOST_IP="${HTTPS_HOST_IP_OVERRIDE}"
[[ -n "${HTTPS_HOST_PORT_OVERRIDE}" ]] && HTTPS_HOST_PORT="${HTTPS_HOST_PORT_OVERRIDE}"
[[ -n "${CONTAINER_NAME_OVERRIDE}" ]] && CONTAINER_NAME="${CONTAINER_NAME_OVERRIDE}"

: "${TLS_HOSTNAME:?TLS_HOSTNAME is not set}"
: "${HTTPS_HOST_IP:?HTTPS_HOST_IP is not set}"
: "${HTTPS_HOST_PORT:?HTTPS_HOST_PORT is not set}"
: "${CONTAINER_NAME:?CONTAINER_NAME is not set}"

printf 'Docker health: '
docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}"

printf '\n/status\n'
curl --fail --show-error --silent   --resolve "${TLS_HOSTNAME}:${HTTPS_HOST_PORT}:${HTTPS_HOST_IP}"   "https://${TLS_HOSTNAME}:${HTTPS_HOST_PORT}/status"

printf '\n\n/healthz\n'
curl --fail --show-error --silent   --resolve "${TLS_HOSTNAME}:${HTTPS_HOST_PORT}:${HTTPS_HOST_IP}"   "https://${TLS_HOSTNAME}:${HTTPS_HOST_PORT}/healthz"

printf '\n\nPresented certificate\n'
openssl s_client   -connect "${HTTPS_HOST_IP}:${HTTPS_HOST_PORT}"   -servername "${TLS_HOSTNAME}"   -verify_return_error   </dev/null 2>/dev/null   | openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName
