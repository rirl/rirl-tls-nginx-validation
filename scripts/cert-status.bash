#!/usr/bin/env bash
set -Eeuo pipefail

TLS_HOSTNAME="${TLS_HOSTNAME:-atreides.lan.rirl.dev}"
CERT_WARNING_DAYS="${CERT_WARNING_DAYS:-30}"

CERT_FILE="/etc/letsencrypt/live/${TLS_HOSTNAME}/fullchain.pem"
STATUS_DIR="/run/cert-status"
STATUS_FILE="${STATUS_DIR}/status.json"
HEALTH_FILE="${STATUS_DIR}/healthz"

mkdir -p "${STATUS_DIR}"
checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_invalid() {
  cat > "${STATUS_FILE}" <<EOF
{
  "status": "invalid",
  "hostname": "${TLS_HOSTNAME}",
  "certificate_valid": false,
  "days_remaining": -1,
  "warning_days": ${CERT_WARNING_DAYS},
  "checked_at": "${checked_at}"
}
EOF
  printf 'invalid\n' > "${HEALTH_FILE}"
}

if [[ ! -r "${CERT_FILE}" ]] || ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
  write_invalid
  exit 1
fi

not_before_raw="$(openssl x509 -in "${CERT_FILE}" -noout -startdate | cut -d= -f2-)"
not_after_raw="$(openssl x509 -in "${CERT_FILE}" -noout -enddate | cut -d= -f2-)"
issuer="$(openssl x509 -in "${CERT_FILE}" -noout -issuer | sed 's/^issuer=//')"
serial="$(openssl x509 -in "${CERT_FILE}" -noout -serial | cut -d= -f2-)"

not_before_epoch="$(date -u -d "${not_before_raw}" +%s)"
not_after_epoch="$(date -u -d "${not_after_raw}" +%s)"
now_epoch="$(date -u +%s)"

not_before="$(date -u -d "@${not_before_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
not_after="$(date -u -d "@${not_after_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
days_remaining=$(((not_after_epoch - now_epoch) / 86400))

status="healthy"
cert_valid=true
health="ok"

if (( now_epoch < not_before_epoch )); then
  status="invalid"; cert_valid=false; health="invalid"
elif (( now_epoch >= not_after_epoch )); then
  status="expired"; cert_valid=false; health="expired"
elif (( days_remaining <= CERT_WARNING_DAYS )); then
  status="warning"; health="warning"
fi

python3 - <<PY > "${STATUS_FILE}.tmp"
import json
print(json.dumps({
  "status": ${status@Q},
  "hostname": ${TLS_HOSTNAME@Q},
  "certificate_valid": ${cert_valid},
  "not_before": ${not_before@Q},
  "not_after": ${not_after@Q},
  "days_remaining": ${days_remaining},
  "warning_days": ${CERT_WARNING_DAYS},
  "issuer": ${issuer@Q},
  "serial": ${serial@Q},
  "checked_at": ${checked_at@Q},
}, indent=2))
PY

mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
printf '%s\n' "${health}" > "${HEALTH_FILE}"

[[ "${status}" == "healthy" ]]
