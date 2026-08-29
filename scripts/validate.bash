#!/usr/bin/env bash
set -Eeuo pipefail

TLS_HOSTNAME="${TLS_HOSTNAME:-atreides.lan.rirl.dev}"
HTTPS_HOST_IP="${HTTPS_HOST_IP:-127.0.0.1}"
HTTPS_HOST_PORT="${HTTPS_HOST_PORT:-18443}"
CONTAINER_NAME="${CONTAINER_NAME:-rirl-tls-validation-nginx}"

printf 'Docker health: '
docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}"

printf '\n/status\n'
curl --fail --show-error --silent   --resolve "${TLS_HOSTNAME}:${HTTPS_HOST_PORT}:${HTTPS_HOST_IP}"   "https://${TLS_HOSTNAME}:${HTTPS_HOST_PORT}/status"

printf '\n\n/healthz\n'
curl --fail --show-error --silent   --resolve "${TLS_HOSTNAME}:${HTTPS_HOST_PORT}:${HTTPS_HOST_IP}"   "https://${TLS_HOSTNAME}:${HTTPS_HOST_PORT}/healthz"

printf '\n\nPresented certificate\n'
openssl s_client   -connect "${HTTPS_HOST_IP}:${HTTPS_HOST_PORT}"   -servername "${TLS_HOSTNAME}"   -verify_return_error   </dev/null 2>/dev/null   | openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName
