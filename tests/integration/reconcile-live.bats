#!/usr/bin/env bats

set -o pipefail

readonly RECONCILE='/code/scripts/reconcile.bash'

setup_file() {
    local variable
    for variable in \
        INTEGRATION_CONTAINER_NAME \
        INTEGRATION_FIXTURE_ROOT \
        INTEGRATION_HOSTNAME \
        INTEGRATION_HTTPS_PORT; do
        if [[ -z "${!variable-}" ]]; then
            printf 'Missing integration variable: %s\n' "${variable}" >&2
            return 1
        fi
    done

}

setup() {
    export RECONCILE
    export RUNTIME_CONFIG="${INTEGRATION_FIXTURE_ROOT}/runtime.env"
    export RECONCILE_LOCK_FILE="${INTEGRATION_FIXTURE_ROOT}/reconcile.lock"
    export RECONCILE_POST_RELOAD_RETRIES=10
    export RECONCILE_POST_RELOAD_RETRY_DELAY_SECONDS=0.2
    export RECONCILE_PROBE_TIMEOUT_SECONDS=2

    restore_nginx_configuration
    set_desired_generation 2
    docker exec "${INTEGRATION_CONTAINER_NAME}" nginx -t >/dev/null 2>&1
    docker exec "${INTEGRATION_CONTAINER_NAME}" nginx -s reload >/dev/null 2>&1
    wait_for_generation 2
    wait_for_stable_workers
}

teardown() {
    restore_nginx_configuration
}

restore_nginx_configuration() {
    cp \
        "${INTEGRATION_FIXTURE_ROOT}/default.conf.good" \
        "${INTEGRATION_FIXTURE_ROOT}/default.conf"
}

set_desired_generation() {
    local generation="$1"
    local live_dir="${INTEGRATION_FIXTURE_ROOT}/letsencrypt/live/${INTEGRATION_HOSTNAME}"
    local filename

    for filename in cert chain fullchain privkey; do
        ln -sfn \
            "../../archive/${INTEGRATION_HOSTNAME}/${filename}${generation}.pem" \
            "${live_dir}/${filename}.pem"
    done
}

normalize_fingerprint() {
    sed -E 's/^.*[Ff]ingerprint=//' |
        tr -d ':' |
        tr '[:upper:]' '[:lower:]'
}

generation_fingerprint() {
    local generation="$1"

    openssl x509 \
        -in "${INTEGRATION_FIXTURE_ROOT}/letsencrypt/archive/${INTEGRATION_HOSTNAME}/cert${generation}.pem" \
        -noout \
        -fingerprint \
        -sha256 |
        normalize_fingerprint
}

served_fingerprint() {
    timeout 2 \
        openssl s_client \
        -connect "127.0.0.1:${INTEGRATION_HTTPS_PORT}" \
        -servername "${INTEGRATION_HOSTNAME}" \
        -verify_hostname "${INTEGRATION_HOSTNAME}" \
        -verify_return_error \
        </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        normalize_fingerprint
}

wait_for_generation() {
    local generation="$1"
    local expected actual
    local attempt

    expected="$(generation_fingerprint "${generation}")"
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if actual="$(served_fingerprint)" && [[ "${actual}" == "${expected}" ]]; then
            return 0
        fi
        sleep 0.2
    done

    printf 'Timed out waiting for served certificate generation %s\n' \
        "${generation}" >&2
    return 1
}

worker_pids() {
    docker top "${INTEGRATION_CONTAINER_NAME}" -eo pid,args |
        awk '/nginx: worker process/ { print $1 }' |
        sort |
        tr '\n' ' '
}

wait_for_stable_workers() {
    local previous current
    local stable_samples=0
    local attempt

    previous="$(worker_pids)"
    for ((attempt = 1; attempt <= 50; attempt++)); do
        sleep 0.1
        current="$(worker_pids)"

        if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            ((stable_samples += 1))
            if ((stable_samples >= 3)); then
                return 0
            fi
        else
            stable_samples=0
        fi

        previous="${current}"
    done

    printf 'Timed out waiting for a stable nginx worker set\n' >&2
    return 1
}

reload_count() {
    docker logs "${INTEGRATION_CONTAINER_NAME}" 2>&1 |
        awk '/signal 1 .*reconfiguring/ { count++ } END { print count + 0 }'
}

@test "live converged state returns 0 without replacing nginx workers" {
    local workers_before workers_after
    workers_before="$(worker_pids)"

    run "${RECONCILE}"

    workers_after="$(worker_pids)"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Already converged'* ]]
    [[ "${output}" == *'No reload performed'* ]]
    [[ "${workers_after}" == "${workers_before}" ]]
}

@test "live mismatch validates reloads and serves the desired certificate" {
    local workers_before workers_after
    local expected served
    set_desired_generation 1
    expected="$(generation_fingerprint 1)"
    workers_before="$(worker_pids)"

    run "${RECONCILE}"

    workers_after="$(worker_pids)"
    served="$(served_fingerprint)"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Mismatch detected'* ]]
    [[ "${output}" == *'Reload verified'* ]]
    [[ "${served}" == "${expected}" ]]
    [[ "${workers_after}" != "${workers_before}" ]]
}

@test "live second invocation is idempotent after convergence" {
    local workers_after_first workers_after_second
    set_desired_generation 1

    run "${RECONCILE}"
    [[ "${status}" -eq 0 ]]
    workers_after_first="$(worker_pids)"

    run "${RECONCILE}"
    workers_after_second="$(worker_pids)"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'Already converged'* ]]
    [[ "${workers_after_second}" == "${workers_after_first}" ]]
}

@test "live invalid nginx configuration prevents reload" {
    local workers_before workers_after
    local expected served
    set_desired_generation 1
    expected="$(generation_fingerprint 2)"
    printf '\nthis_is_not_a_valid_nginx_directive;\n' \
        >>"${INTEGRATION_FIXTURE_ROOT}/default.conf"
    workers_before="$(worker_pids)"

    run "${RECONCILE}"

    workers_after="$(worker_pids)"
    served="$(served_fingerprint)"
    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'nginx configuration invalid; refusing to reload'* ]]
    [[ "${served}" == "${expected}" ]]
    [[ "${workers_after}" == "${workers_before}" ]]
}

@test "live TLS verification failure with a parseable certificate returns 1" {
    local workers_before workers_after
    workers_before="$(worker_pids)"

    run env SSL_CERT_FILE=/dev/null "${RECONCILE}"

    workers_after="$(worker_pids)"
    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *'could not obtain served certificate via TLS probe'* ]]
    [[ "${workers_after}" == "${workers_before}" ]]
}

@test "live concurrent mismatch invocations converge with one reload" {
    local reloads_before reloads_after
    local expected served
    set_desired_generation 1
    expected="$(generation_fingerprint 1)"
    reloads_before="$(reload_count)"

    run bash -c '
        set +e
        "${RECONCILE}" >"${INTEGRATION_FIXTURE_ROOT}/concurrent-1.out" 2>&1 &
        first_pid=$!
        "${RECONCILE}" >"${INTEGRATION_FIXTURE_ROOT}/concurrent-2.out" 2>&1 &
        second_pid=$!

        wait "${first_pid}"
        first_status=$?
        wait "${second_pid}"
        second_status=$?

        printf "first=%d second=%d\n" "${first_status}" "${second_status}"
        if ((first_status != 0 || second_status != 0)); then
            cat "${INTEGRATION_FIXTURE_ROOT}/concurrent-1.out"
            cat "${INTEGRATION_FIXTURE_ROOT}/concurrent-2.out"
            exit 1
        fi
    '

    wait_for_generation 1
    sleep 0.2
    reloads_after="$(reload_count)"
    served="$(served_fingerprint)"
    printf '# concurrent reloads: before=%s after=%s\n' \
        "${reloads_before}" "${reloads_after}" >&3
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == *'first=0 second=0'* ]]
    [[ "${served}" == "${expected}" ]]
    [[ "$((reloads_after - reloads_before))" -eq 1 ]]
}
