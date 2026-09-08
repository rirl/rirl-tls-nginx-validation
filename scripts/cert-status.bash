#!/usr/bin/env bash

set -Eeuo pipefail

TLS_HOSTNAME="${TLS_HOSTNAME:-atreides.lan.rirl.dev}"
CERT_FILE="${CERT_FILE:-/etc/letsencrypt/live/${TLS_HOSTNAME}/fullchain.pem}"
CERT_WARNING_DAYS="${CERT_WARNING_DAYS:-14}"
STATUS_DIR="${STATUS_DIR:-/run/cert-status}"

STATUS_FILE="${STATUS_DIR}/status.json"
HEALTH_FILE="${STATUS_DIR}/healthz"

if ! mkdir -p "${STATUS_DIR}" 2>/dev/null; then
    printf 'ERROR: unable to create status directory: %s\n' \
        "${STATUS_DIR}" >&2
    exit 2
fi

if [[ ! -w "${STATUS_DIR}" ]]; then
    printf 'ERROR: status directory is not writable: %s\n' \
        "${STATUS_DIR}" >&2
    exit 2
fi

checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_status() {
    local status="$1"
    local certificate_valid="$2"
    local not_before="$3"
    local not_after="$4"
    local days_remaining="$5"
    local issuer="$6"
    local serial="$7"

    STATUS="${status}" \
    CERTIFICATE_VALID="${certificate_valid}" \
    NOT_BEFORE="${not_before}" \
    NOT_AFTER="${not_after}" \
    DAYS_REMAINING="${days_remaining}" \
    ISSUER="${issuer}" \
    SERIAL="${serial}" \
    CHECKED_AT="${checked_at}" \
    TLS_HOSTNAME="${TLS_HOSTNAME}" \
    CERT_WARNING_DAYS="${CERT_WARNING_DAYS}" \
    python3 - <<'PY' > "${STATUS_FILE}.tmp"
import json
import os

data = {
    "status": os.environ["STATUS"],
    "hostname": os.environ["TLS_HOSTNAME"],
    "certificate_valid": os.environ["CERTIFICATE_VALID"].lower() == "true",
    "not_before": os.environ["NOT_BEFORE"],
    "not_after": os.environ["NOT_AFTER"],
    "days_remaining": int(os.environ["DAYS_REMAINING"]),
    "warning_days": int(os.environ["CERT_WARNING_DAYS"]),
    "issuer": os.environ["ISSUER"],
    "serial": os.environ["SERIAL"],
    "checked_at": os.environ["CHECKED_AT"],
}

print(json.dumps(data, indent=2))
PY

    mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

write_invalid_status() {
    write_status \
        "invalid" \
        "false" \
        "" \
        "" \
        "-1" \
        "" \
        ""

    rm -f "${HEALTH_FILE}"
}

if [[ ! -r "${CERT_FILE}" ]]; then
    write_invalid_status
    exit 1
fi

if ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
    write_invalid_status
    exit 1
fi

not_before_raw="$(
    openssl x509 \
        -in "${CERT_FILE}" \
        -noout \
        -startdate |
        cut -d= -f2-
)"

not_after_raw="$(
    openssl x509 \
        -in "${CERT_FILE}" \
        -noout \
        -enddate |
        cut -d= -f2-
)"

issuer="$(
    openssl x509 \
        -in "${CERT_FILE}" \
        -noout \
        -issuer |
        sed 's/^issuer=//'
)"

serial="$(
    openssl x509 \
        -in "${CERT_FILE}" \
        -noout \
        -serial |
        cut -d= -f2-
)"

not_before_epoch="$(date -u -d "${not_before_raw}" +%s)"
not_after_epoch="$(date -u -d "${not_after_raw}" +%s)"
now_epoch="$(date -u +%s)"

not_before="$(
    date -u \
        -d "@${not_before_epoch}" \
        +%Y-%m-%dT%H:%M:%SZ
)"

not_after="$(
    date -u \
        -d "@${not_after_epoch}" \
        +%Y-%m-%dT%H:%M:%SZ
)"

seconds_remaining=$((not_after_epoch - now_epoch))
days_remaining=$((seconds_remaining / 86400))

status="healthy"
certificate_valid="true"

if ((now_epoch < not_before_epoch)); then
    status="invalid"
    certificate_valid="false"
elif ((now_epoch >= not_after_epoch)); then
    status="expired"
    certificate_valid="false"
elif ((days_remaining <= CERT_WARNING_DAYS)); then
    status="warning"
fi

write_status \
    "${status}" \
    "${certificate_valid}" \
    "${not_before}" \
    "${not_after}" \
    "${days_remaining}" \
    "${issuer}" \
    "${serial}"

if [[ "${status}" == "healthy" ]]; then
    printf 'ok\n' > "${HEALTH_FILE}.tmp"
    mv "${HEALTH_FILE}.tmp" "${HEALTH_FILE}"
    exit 0
fi

rm -f "${HEALTH_FILE}"
exit 1