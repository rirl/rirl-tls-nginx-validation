#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly TEST_HOSTNAME="reconcile-integration.lan.rirl.dev"
readonly TARGET_IMAGE="${RECONCILE_INTEGRATION_TARGET_IMAGE:-rirl-tls-nginx-validation:local}"
readonly RUNNER_IMAGE="${RECONCILE_INTEGRATION_RUNNER_IMAGE:-rirl-tls-bats-integration:1.14.0}"

usage() {
    cat <<USAGE
Usage: ${PROGRAM_NAME} --live

Run the trusted, disposable RECONCILE integration suite. This command mounts
/var/run/docker.sock into the Bats runner and therefore grants it broad control
over the local Docker daemon.
USAGE
}

if (($# != 1)) || [[ "$1" != '--live' ]]; then
    usage >&2
    exit 2
fi

if ((EUID == 0)); then
    printf 'ERROR: do not run the integration suite as root.\n' >&2
    exit 2
fi

for command in docker openssl sed stat timeout; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "${command}" >&2
        exit 2
    fi
done

if [[ ! -S /var/run/docker.sock ]]; then
    printf 'ERROR: Docker socket not found: /var/run/docker.sock\n' >&2
    exit 2
fi

if ! docker image inspect "${TARGET_IMAGE}" >/dev/null 2>&1; then
    printf 'ERROR: target image not found: %s\n' "${TARGET_IMAGE}" >&2
    printf 'ERROR: run terraform apply before the integration suite.\n' >&2
    exit 2
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
temp_parent="${TMPDIR:-/tmp}"
if [[ "${temp_parent}" != /* || "${temp_parent}" == '/' ]]; then
    printf 'ERROR: unsafe temporary parent: %s\n' "${temp_parent}" >&2
    exit 2
fi

test_root=''
container_name="rirl-tls-reconcile-integration-$(id -u)-$$"

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if docker container inspect "${container_name}" >/dev/null 2>&1; then
        if ! docker rm --force "${container_name}" >/dev/null; then
            printf 'ERROR: could not remove integration container: %s\n' \
                "${container_name}" >&2
            status=1
        fi
    fi

    if [[ -n "${test_root}" ]]; then
        case "${test_root}" in
            "${temp_parent%/}"/rirl-tls-reconcile-integration.*)
                rm -rf -- "${test_root}"
                ;;
            *)
                printf 'ERROR: refusing unexpected integration path: %s\n' \
                    "${test_root}" >&2
                status=1
                ;;
        esac
    fi

    exit "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

if docker container inspect "${container_name}" >/dev/null 2>&1; then
    printf 'ERROR: integration container already exists: %s\n' \
        "${container_name}" >&2
    exit 2
fi

test_root="$(mktemp -d "${temp_parent%/}/rirl-tls-reconcile-integration.XXXXXX")"
chmod 0700 "${test_root}"

archive_dir="${test_root}/letsencrypt/archive/${TEST_HOSTNAME}"
live_dir="${test_root}/letsencrypt/live/${TEST_HOSTNAME}"
mkdir -p "${archive_dir}" "${live_dir}"

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -sha256 \
    -days 2 \
    -subj '/CN=rirl RECONCILE integration CA' \
    -keyout "${test_root}/ca.key" \
    -out "${test_root}/ca.crt" \
    >/dev/null 2>&1

printf '%s\n' \
    "subjectAltName=DNS:${TEST_HOSTNAME}" \
    'extendedKeyUsage=serverAuth' \
    'keyUsage=digitalSignature,keyEncipherment' \
    'basicConstraints=CA:FALSE' \
    >"${test_root}/leaf.ext"

for generation in 1 2; do
    openssl req \
        -new \
        -newkey rsa:2048 \
        -nodes \
        -sha256 \
        -subj "/CN=${TEST_HOSTNAME}" \
        -keyout "${archive_dir}/privkey${generation}.pem" \
        -out "${test_root}/leaf${generation}.csr" \
        >/dev/null 2>&1

    serial_options=(-CAserial "${test_root}/ca.srl")
    if ((generation == 1)); then
        serial_options=(-CAcreateserial)
    fi

    openssl x509 \
        -req \
        -in "${test_root}/leaf${generation}.csr" \
        -CA "${test_root}/ca.crt" \
        -CAkey "${test_root}/ca.key" \
        "${serial_options[@]}" \
        -days 2 \
        -sha256 \
        -extfile "${test_root}/leaf.ext" \
        -out "${archive_dir}/cert${generation}.pem" \
        >/dev/null 2>&1

    cp "${test_root}/ca.crt" "${archive_dir}/chain${generation}.pem"
    cat \
        "${archive_dir}/cert${generation}.pem" \
        "${archive_dir}/chain${generation}.pem" \
        >"${archive_dir}/fullchain${generation}.pem"
done

chmod 0600 "${archive_dir}"/privkey*.pem "${test_root}/ca.key"

for filename in cert chain fullchain privkey; do
    ln -s \
        "../../archive/${TEST_HOSTNAME}/${filename}2.pem" \
        "${live_dir}/${filename}.pem"
done

sed \
    "s/\${tls_hostname}/${TEST_HOSTNAME}/g" \
    "${repo_root}/nginx/default.conf.tftpl" \
    >"${test_root}/default.conf"
cp "${test_root}/default.conf" "${test_root}/default.conf.good"

docker build \
    --tag "${RUNNER_IMAGE}" \
    --file "${repo_root}/tests/integration/Dockerfile" \
    "${repo_root}"

docker run \
    --detach \
    --name "${container_name}" \
    --label dev.rirl.test=reconcile-integration \
    --label "dev.rirl.owner=$(id -u)" \
    --restart no \
    --publish 127.0.0.1::443 \
    --env "TLS_HOSTNAME=${TEST_HOSTNAME}" \
    --env CERT_WARNING_DAYS=30 \
    --env STATUS_REFRESH_SECONDS=300 \
    --mount "type=bind,src=${test_root}/letsencrypt,dst=/etc/letsencrypt,readonly" \
    --mount "type=bind,src=${test_root}/default.conf,dst=/etc/nginx/conf.d/default.conf,readonly" \
    "${TARGET_IMAGE}" \
    >/dev/null

port_mapping="$(docker port "${container_name}" 443/tcp | head -n 1)"
https_port="${port_mapping##*:}"
if [[ ! "${https_port}" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: could not determine integration HTTPS port: %s\n' \
        "${port_mapping}" >&2
    exit 1
fi

cat >"${test_root}/runtime.env" <<RUNTIME
TLS_HOSTNAME=${TEST_HOSTNAME}
HTTPS_HOST_IP=127.0.0.1
HTTPS_HOST_PORT=${https_port}
CONTAINER_NAME=${container_name}
RUNTIME

ready=false
for ((attempt = 1; attempt <= 30; attempt++)); do
    if SSL_CERT_FILE="${test_root}/ca.crt" \
        timeout 2 openssl s_client \
            -connect "127.0.0.1:${https_port}" \
            -servername "${TEST_HOSTNAME}" \
            -verify_hostname "${TEST_HOSTNAME}" \
            -verify_return_error \
            </dev/null >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.2
done

if [[ "${ready}" != 'true' ]]; then
    printf 'ERROR: disposable nginx listener did not become ready.\n' >&2
    docker logs "${container_name}" >&2 || true
    exit 1
fi

results_dir="${repo_root}/test-results/integration"
mkdir -p "${results_dir}"
socket_gid="$(stat -c '%g' /var/run/docker.sock)"

docker run \
    --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    --group-add "${socket_gid}" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "${repo_root}:/code:ro" \
    --volume "${test_root}:/fixture" \
    --volume "${results_dir}:/test-results" \
    --workdir /code \
    --env DOCKER_HOST=unix:///var/run/docker.sock \
    --env SSL_CERT_FILE=/fixture/ca.crt \
    --env "INTEGRATION_CONTAINER_NAME=${container_name}" \
    --env INTEGRATION_FIXTURE_ROOT=/fixture \
    --env "INTEGRATION_HOSTNAME=${TEST_HOSTNAME}" \
    --env "INTEGRATION_HTTPS_PORT=${https_port}" \
    "${RUNNER_IMAGE}" \
    --formatter tap \
    --report-formatter junit \
    --output /test-results \
    tests/integration/reconcile-live.bats
