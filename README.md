# rirl-tls-nginx-validation

Terraform-managed Docker/Nginx validation target and certificate-consumer
reconciliation implementation for `atreides.lan.rirl.dev`.

The existing Certbot state remains external and is mounted read-only.

This repository owns nginx-specific certificate activation and convergence
verification. The caller does not need to know nginx commands, container
internals, health endpoints, or certificate comparison details.

## Isolation defaults

```text
Container:          rirl-tls-validation-nginx
Docker network:     rirl-tls-validation
Terraform host bind: 127.0.0.1
Host port:          18443
Container port:     443
Restart policy:     no
Certbot state:      read-only
```

The Terraform default binds the validation endpoint to loopback. The currently
validated deployment may override `https_host_ip` with a LAN address so that
cross-host canary validation is possible. Treat that as an explicit deployment
choice rather than an invariant of this repository.

## RECONCILE interface

The stable consumer entry point is:

```bash
./scripts/reconcile.bash
```

Contract:

```text
exit 0     nginx is proven converged on the currently authoritative certificate
exit 1     convergence could not be established
exit 2     reconciliation could not be attempted because of usage/environment
```

The interface is intentionally small. Callers should depend only on invocation
and exit semantics.

The current implementation is a **host-side control command**. It uses Docker
to inspect and control the already-running nginx container. It is not a
separate reconciliation container.

Operationally:

```text
observe stable desired certificate
        |
        v
probe certificate actually served over TLS
        |
        +-- match --> no reload --> success
        |
        +-- mismatch
              |
              v
           nginx -t
              |
              v
           nginx reload
              |
              v
       fresh desired observation
              |
              v
       fresh live TLS probe
              |
              v
        prove convergence
```

Certificate identity is compared using the leaf certificate SHA-256
fingerprint.

Desired state is read from the certificate visible inside the nginx container.
Served state is measured independently through a live TLS handshake. The
implementation deliberately does not use `/healthz`, `/status`, or
`cert-status.bash` as proof of the certificate nginx is actually serving.

To avoid declaring convergence against a moving target, RECONCILE observes
desired state before and after the served-certificate probe and requires the
desired observation to be stable. After a reload it again derives current
desired state and verifies the certificate served over TLS.

A lock serializes concurrent reconciliation attempts. Repeated invocation is
therefore safe and idempotent: when nginx already serves the desired
certificate, no reload is performed.

## Status endpoints

```text
GET /healthz
GET /status
```

`/status` returns JSON containing certificate validity, expiry, days remaining,
issuer, serial number, configured warning threshold, and last check time.

`/healthz` returns HTTP 200 only while the certificate **file visible to the
container** is healthy.

Default states:

```text
healthy   more than 30 days remaining
warning   30 days or fewer remaining
expired   certificate expiration passed
invalid   certificate unreadable or unparsable
```

The status is refreshed every 5 minutes by default.

These endpoints are useful for certificate-file health and liveness, but they
are **not convergence proof**. They do not establish which certificate nginx is
currently presenting over a TLS handshake. RECONCILE uses an independent live
TLS probe for that purpose.

## Docker health

Docker health is driven by `/healthz`:

```bash
docker inspect   --format '{{.State.Health.Status}}'   rirl-tls-validation-nginx
```

Docker health therefore reflects the status endpoint semantics described
above; it should not be interpreted as proof that the served certificate
matches current desired state.

## Configure

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply
```

## Validate

Human-oriented validation:

```bash
./scripts/validate.bash
```

Contract tests:

```bash
./tests/run.bash
```

Live integration tests:

```bash
./tests/integration/run.bash --live
```

The validated reconciliation suite covers the already-converged path,
mismatch/reload/convergence, repeated invocation, invalid nginx configuration,
TLS probe failure, and concurrent reconciliation with serialized reload.

Reproducible operational scenarios are documented under:

```text
docs/scenarios/
```

See:

```text
tests/integration/README.adoc
```

## Architecture documentation

Current reconciliation architecture:

```text
docs/architecture/reconciliation.md
```

Historical design review:

```text
docs/architecture/reviews/rirl-tls-architecture-review.md
```

The historical review records the pre-RECONCILE state and should not be read as
a description of the current implementation.

## Destroy

```bash
./scripts/destroy.bash
```

## Separate availability concern

The current Terraform restart policy is:

```text
restart = "unless-stopped"
```

Container availability and restart behavior remain intentionally separate from
RECONCILE correctness.

Reproducible availability scenarios:

```text
docs/scenarios/container-availability.md
```

Completed live validation:

```text
docs/validation/container-availability.md
```
