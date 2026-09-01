#!/usr/bin/env bash
#
# reconcile.bash — RECONCILE for rirl-tls-nginx-validation
#
# Proves that nginx is currently serving the authoritative certificate,
# taking action only if it is not, and re-proving convergence afterward.
#
# This intentionally does NOT reuse cert-status.bash's /healthz output as
# its source of truth for "served certificate": cert-status.bash inspects
# the certificate FILE mounted into the container, not what nginx is
# actually presenting over a live TLS handshake. Those two facts can
# legitimately disagree — that divergence is exactly the condition this
# script exists to detect and fix. "Desired" and "served" must each be
# measured fresh, from their own independent source, every time this
# script runs.
#
# Exit codes:
#   0  converged — proven via a live TLS probe taken after any reload this
#      invocation performed (or immediately, if no reload was needed).
#   1  attempted, convergence could not be established (invalid config,
#      reload failed, still mismatched after reload, probe failed).
#   2  could not even attempt (usage error, runtime config missing,
#      container not found/not running).

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"

RUNTIME_CONFIG="${RUNTIME_CONFIG:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/generated/runtime.env}"

readonly LOCK_FILE="${RECONCILE_LOCK_FILE:-/tmp/rirl-tls-nginx-validation.reconcile.lock}"
readonly POST_RELOAD_RETRIES="${RECONCILE_POST_RELOAD_RETRIES:-5}"
readonly POST_RELOAD_RETRY_DELAY_SECONDS="${RECONCILE_POST_RELOAD_RETRY_DELAY_SECONDS:-1}"
readonly PROBE_TIMEOUT_SECONDS="${RECONCILE_PROBE_TIMEOUT_SECONDS:-5}"

usage() {
    cat <<USAGE
Usage: ${PROGRAM_NAME}

Compare the certificate nginx should be serving against the certificate it
is actually serving. Reload nginx only if they differ, then re-verify.

Configuration is read from:
  ${RUNTIME_CONFIG}

and may be overridden via environment variables:
  TLS_HOSTNAME, HTTPS_HOST_IP, HTTPS_HOST_PORT, CONTAINER_NAME

Exit codes:
  0  proven converged
  1  attempted, convergence not established
  2  could not attempt (environment/usage error)
USAGE
}

if (($# > 0)); then
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unsupported argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
fi

if [[ ! -r "${RUNTIME_CONFIG}" ]]; then
    printf 'ERROR: runtime configuration not found: %s\n' "${RUNTIME_CONFIG}" >&2
    printf 'ERROR: run terraform apply before using this script.\n' >&2
    exit 2
fi

TLS_HOSTNAME_OVERRIDE="${TLS_HOSTNAME-}"
HTTPS_HOST_IP_OVERRIDE="${HTTPS_HOST_IP-}"
HTTPS_HOST_PORT_OVERRIDE="${HTTPS_HOST_PORT-}"
CONTAINER_NAME_OVERRIDE="${CONTAINER_NAME-}"

# shellcheck source=/dev/null
if ! source "${RUNTIME_CONFIG}"; then
    printf 'ERROR: could not load runtime configuration: %s\n' "${RUNTIME_CONFIG}" >&2
    exit 2
fi

[[ -n "${TLS_HOSTNAME_OVERRIDE}" ]] && TLS_HOSTNAME="${TLS_HOSTNAME_OVERRIDE}"
[[ -n "${HTTPS_HOST_IP_OVERRIDE}" ]] && HTTPS_HOST_IP="${HTTPS_HOST_IP_OVERRIDE}"
[[ -n "${HTTPS_HOST_PORT_OVERRIDE}" ]] && HTTPS_HOST_PORT="${HTTPS_HOST_PORT_OVERRIDE}"
[[ -n "${CONTAINER_NAME_OVERRIDE}" ]] && CONTAINER_NAME="${CONTAINER_NAME_OVERRIDE}"

for variable in TLS_HOSTNAME HTTPS_HOST_IP HTTPS_HOST_PORT CONTAINER_NAME; do
    if [[ -z "${!variable-}" ]]; then
        printf 'ERROR: required runtime configuration is not set: %s\n' "${variable}" >&2
        exit 2
    fi
done

readonly TLS_HOSTNAME HTTPS_HOST_IP HTTPS_HOST_PORT CONTAINER_NAME
readonly DESIRED_CERT_PATH="/etc/letsencrypt/live/${TLS_HOSTNAME}/fullchain.pem"

for command in docker openssl flock timeout sed tr sleep; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "${command}" >&2
        exit 2
    fi
done

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    printf 'ERROR: container not found: %s\n' "${CONTAINER_NAME}" >&2
    exit 2
fi

if ! container_running="$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)"; then
    printf 'ERROR: could not inspect container state: %s\n' "${CONTAINER_NAME}" >&2
    exit 2
fi

if [[ "${container_running}" != 'true' ]]; then
    printf 'ERROR: container is not running: %s\n' "${CONTAINER_NAME}" >&2
    exit 2
fi

# --- fingerprint helpers -----------------------------------------------
#
# Both helpers print a bare lowercase sha256 fingerprint (no "sha256
# Fingerprint=" prefix, no colons) on success, so the two values are
# directly comparable regardless of which openssl formatted them.

normalize_fingerprint() {
    # Strips "SHA256 Fingerprint=" / "sha256 Fingerprint=" prefixes and
    # colons, lowercases the result, and accepts only a complete SHA-256
    # fingerprint.
    local fingerprint

    if ! fingerprint="$(
        LC_ALL=C sed -E 's/^.*[Ff]ingerprint=//' |
            LC_ALL=C tr -d ':' |
            LC_ALL=C tr '[:upper:]' '[:lower:]'
    )"; then
        return 1
    fi

    if [[ ! "${fingerprint}" =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi

    printf '%s\n' "${fingerprint}"
}

desired_fingerprint() {
    # Reads the certificate through the SAME container that serves it, so
    # "desired" reflects exactly what nginx's mount currently resolves to
    # — not a host-side path assumption about where Certbot state lives.
    docker exec --env LC_ALL=C "${CONTAINER_NAME}" \
        openssl x509 \
        -in "${DESIRED_CERT_PATH}" \
        -noout \
        -fingerprint \
        -sha256 \
        2>/dev/null |
        normalize_fingerprint
}

served_fingerprint() {
    # Live TLS probe against the actual listener — this is deliberately
    # the same technique validate.bash already uses (explicit -servername
    # for correct SNI, explicit target IP/port so ambient DNS resolution
    # can never substitute a different endpoint, -verify_return_error so
    # an untrusted/wrong chain fails loudly instead of being silently
    # accepted).
    LC_ALL=C timeout "${PROBE_TIMEOUT_SECONDS}" \
        openssl s_client \
        -connect "${HTTPS_HOST_IP}:${HTTPS_HOST_PORT}" \
        -servername "${TLS_HOSTNAME}" \
        -verify_hostname "${TLS_HOSTNAME}" \
        -verify_return_error \
        </dev/null 2>/dev/null |
        LC_ALL=C openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        normalize_fingerprint
}

# --- reconciliation body -------------------------------------------------

reconcile() {
    local desired served

    if ! desired="$(desired_fingerprint)"; then
        printf 'ERROR: could not read desired certificate from %s inside %s\n' \
            "${DESIRED_CERT_PATH}" "${CONTAINER_NAME}" >&2
        return 1
    fi

    if ! served="$(served_fingerprint)"; then
        printf 'ERROR: could not obtain served certificate via TLS probe to %s:%s (SNI %s)\n' \
            "${HTTPS_HOST_IP}" "${HTTPS_HOST_PORT}" "${TLS_HOSTNAME}" >&2
        return 1
    fi

    if [[ "${desired}" == "${served}" ]]; then
        printf 'Already converged: served certificate matches desired (sha256:%s). No reload performed.\n' \
            "${desired}"
        return 0
    fi

    printf 'Mismatch detected: desired=sha256:%s served=sha256:%s\n' "${desired}" "${served}"

    printf 'Validating nginx configuration...\n'
    if ! docker exec "${CONTAINER_NAME}" nginx -t 2>&1; then
        printf 'ERROR: nginx configuration invalid; refusing to reload.\n' >&2
        return 1
    fi

    printf 'Reloading nginx...\n'
    if ! docker exec "${CONTAINER_NAME}" nginx -s reload 2>&1; then
        printf 'ERROR: nginx reload command failed.\n' >&2
        return 1
    fi

    # Re-derive BOTH sides fresh, rather than trusting the pre-reload
    # "desired" value: the authoritative certificate can change again
    # while this reload is in flight, and a stale comparison would prove
    # nothing. Retry briefly — a reload is not necessarily instantaneous
    # from the perspective of a new TLS handshake against draining/
    # starting workers.
    local attempt
    for ((attempt = 1; attempt <= POST_RELOAD_RETRIES; attempt++)); do
        if ! desired="$(desired_fingerprint)"; then
            desired=''
        fi
        if ! served="$(served_fingerprint)"; then
            served=''
        fi

        if [[ -n "${desired}" && -n "${served}" && "${desired}" == "${served}" ]]; then
            printf 'Reload verified: served certificate now matches desired (sha256:%s).\n' \
                "${desired}"
            docker exec "${CONTAINER_NAME}" /usr/local/bin/cert-status --once >/dev/null 2>&1 || true
            return 0
        fi

        if ((attempt < POST_RELOAD_RETRIES)); then
            sleep "${POST_RELOAD_RETRY_DELAY_SECONDS}"
        fi
    done

    printf 'ERROR: reload completed but served certificate still does not match desired\n' >&2
    printf 'ERROR: desired=sha256:%s served=sha256:%s (after %d attempts)\n' \
        "${desired:-unknown}" "${served:-unknown}" "${POST_RELOAD_RETRIES}" >&2
    return 1
}

# --- concurrency guard ----------------------------------------------------
#
# Serializes overlapping invocations so two concurrent callers can't race
# each other's compare/act decision. A single nginx reload is itself safe
# to call repeatedly, but the compare-then-act sequence as a whole is not
# safe to interleave: one invocation could reload based on a "mismatch"
# that another invocation is simultaneously in the middle of fixing.

if ! exec 9>"${LOCK_FILE}"; then
    printf 'ERROR: could not open reconcile lock file: %s\n' "${LOCK_FILE}" >&2
    exit 2
fi
if ! flock -w 30 9; then
    printf 'ERROR: could not acquire reconcile lock within 30s (another invocation in progress?)\n' >&2
    exit 2
fi

if reconcile; then
    exit 0
else
    exit 1
fi
