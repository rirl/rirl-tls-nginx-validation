#!/usr/bin/env bats

readonly FINGERPRINT_A='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
readonly FINGERPRINT_B='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'

setup() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
    export RECONCILE="${PROJECT_ROOT}/scripts/reconcile.bash"

    export MOCK_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${MOCK_STATE_DIR}"

    export MOCK_DOCKER_LOG="${MOCK_STATE_DIR}/docker.log"
    export MOCK_OPENSSL_LOG="${MOCK_STATE_DIR}/openssl.log"
    export MOCK_ACTION_LOG="${MOCK_STATE_DIR}/actions.log"
    : >"${MOCK_DOCKER_LOG}"
    : >"${MOCK_OPENSSL_LOG}"
    : >"${MOCK_ACTION_LOG}"

    export PATH="${BATS_TEST_DIRNAME}/fixtures/bin:${PATH}"
    export RUNTIME_CONFIG="${MOCK_STATE_DIR}/runtime.env"
    export RECONCILE_LOCK_FILE="${MOCK_STATE_DIR}/reconcile.lock"
    export RECONCILE_POST_RELOAD_RETRIES=2
    export RECONCILE_POST_RELOAD_RETRY_DELAY_SECONDS=0
    export RECONCILE_PROBE_TIMEOUT_SECONDS=1

    export MOCK_INSPECT_STATUS=0
    export MOCK_STATE_INSPECT_STATUS=0
    export MOCK_CONTAINER_RUNNING=true
    export MOCK_DESIRED_STATUS=0
    export MOCK_S_CLIENT_STATUS=0
    export MOCK_SERVED_X509_STATUS=0
    export MOCK_NGINX_TEST_STATUS=0
    export MOCK_NGINX_RELOAD_STATUS=0
    export MOCK_RELOAD_CONVERGES=1
    export MOCK_FLOCK_STATUS=0

    write_runtime_config
    set_desired_fingerprint "${FINGERPRINT_A}"
    set_served_fingerprint "${FINGERPRINT_A}"
}

write_runtime_config() {
    cat >"${RUNTIME_CONFIG}" <<'CONFIG'
TLS_HOSTNAME=atreides.lan.rirl.dev
HTTPS_HOST_IP=127.0.0.1
HTTPS_HOST_PORT=18443
CONTAINER_NAME=rirl-tls-validation-nginx
CONFIG
}

set_desired_fingerprint() {
    printf 'SHA256 Fingerprint=%s\n' "$1" >"${MOCK_STATE_DIR}/desired-fingerprint"
}

set_served_fingerprint() {
    printf 'SHA256 Fingerprint=%s\n' "$1" >"${MOCK_STATE_DIR}/served-fingerprint"
}

action_count() {
    local action="$1"
    awk -v action="${action}" '$0 == action { count++ } END { print count + 0 }' \
        "${MOCK_ACTION_LOG}"
}

@test "help succeeds without attempting reconciliation" {
    run "${RECONCILE}" --help

    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Usage: reconcile.bash'* ]]
    [[ ! -s "${MOCK_DOCKER_LOG}" ]]
}

@test "unsupported arguments return 2" {
    run "${RECONCILE}" --unexpected

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'unsupported argument'* ]]
}

@test "missing runtime configuration returns 2" {
    export RUNTIME_CONFIG="${MOCK_STATE_DIR}/missing.env"

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'runtime configuration not found'* ]]
}

@test "malformed runtime configuration returns 2" {
    printf 'TLS_HOSTNAME=(\n' >"${RUNTIME_CONFIG}"

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'could not load runtime configuration'* ]]
}

@test "missing required runtime value returns 2" {
    : >"${RUNTIME_CONFIG}"

    run env \
        -u TLS_HOSTNAME \
        -u HTTPS_HOST_IP \
        -u HTTPS_HOST_PORT \
        -u CONTAINER_NAME \
        "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'required runtime configuration is not set: TLS_HOSTNAME'* ]]
}

@test "missing container returns 2" {
    export MOCK_INSPECT_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'container not found'* ]]
}

@test "failed container-state inspection returns 2" {
    export MOCK_STATE_INSPECT_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'could not inspect container state'* ]]
}

@test "stopped container returns 2" {
    export MOCK_CONTAINER_RUNNING=false

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'container is not running'* ]]
}

@test "lock open failure returns 2" {
    export RECONCILE_LOCK_FILE='/proc/rirl-reconcile-test/lock'

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'could not open reconcile lock file'* ]]
}

@test "lock acquisition failure returns 2" {
    export MOCK_FLOCK_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *'could not acquire reconcile lock'* ]]
}

@test "failed desired measurement returns 1 even with parseable output" {
    export MOCK_DESIRED_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'could not read desired certificate'* ]]
    [[ "$(action_count nginx-reload)" -eq 0 ]]
}

@test "malformed desired fingerprint returns 1" {
    set_desired_fingerprint 'not-a-sha256-fingerprint'

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'could not read desired certificate'* ]]
}

@test "TLS probe failure returns 1 even with a parseable certificate" {
    export MOCK_S_CLIENT_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'could not obtain served certificate via TLS probe'* ]]
    [[ "$(action_count nginx-reload)" -eq 0 ]]
}

@test "malformed served fingerprint returns 1" {
    set_served_fingerprint 'not-a-sha256-fingerprint'

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'could not obtain served certificate via TLS probe'* ]]
}

@test "converged state returns 0 without reload" {
    run "${RECONCILE}"

    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Already converged'* ]]
    [[ "${output}" == *'No reload performed'* ]]
    [[ "$(action_count nginx-test)" -eq 0 ]]
    [[ "$(action_count nginx-reload)" -eq 0 ]]
}

@test "mismatch validates reloads and proves convergence" {
    set_served_fingerprint "${FINGERPRINT_B}"

    run "${RECONCILE}"

    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Mismatch detected'* ]]
    [[ "${output}" == *'Reload verified'* ]]
    [[ "$(action_count nginx-test)" -eq 1 ]]
    [[ "$(action_count nginx-reload)" -eq 1 ]]
    [[ "$(action_count cert-status)" -eq 1 ]]
}

@test "invalid nginx configuration returns 1 without reload" {
    set_served_fingerprint "${FINGERPRINT_B}"
    export MOCK_NGINX_TEST_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'nginx configuration invalid; refusing to reload'* ]]
    [[ "$(action_count nginx-test)" -eq 1 ]]
    [[ "$(action_count nginx-reload)" -eq 0 ]]
}

@test "reload command failure returns 1" {
    set_served_fingerprint "${FINGERPRINT_B}"
    export MOCK_NGINX_RELOAD_STATUS=1

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'nginx reload command failed'* ]]
    [[ "$(action_count nginx-test)" -eq 1 ]]
    [[ "$(action_count nginx-reload)" -eq 1 ]]
}

@test "post-reload nonconvergence returns 1 after bounded retries" {
    set_served_fingerprint "${FINGERPRINT_B}"
    export MOCK_RELOAD_CONVERGES=0

    run "${RECONCILE}"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'served certificate still does not match desired'* ]]
    [[ "${output}" == *'after 2 attempts'* ]]
    [[ "$(action_count nginx-reload)" -eq 1 ]]
}

@test "a second invocation after convergence performs no second reload" {
    set_served_fingerprint "${FINGERPRINT_B}"

    run "${RECONCILE}"
    [[ "${status}" -eq 0 ]]

    run "${RECONCILE}"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Already converged'* ]]
    [[ "$(action_count nginx-reload)" -eq 1 ]]
}

@test "live probe requests explicit hostname verification" {
    run "${RECONCILE}"

    [[ "${status}" -eq 0 ]]
    grep -q -- '-verify_hostname atreides.lan.rirl.dev' "${MOCK_OPENSSL_LOG}"
}
