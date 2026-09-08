# Certificate drift reconciliation scenario

## Purpose

This scenario reproduces a condition where the currently authoritative
certificate differs from the certificate nginx is actually serving over TLS.

RECONCILE is responsible for restoring:

```text
served certificate == currently authoritative certificate
```

When a mismatch is detected, RECONCILE validates the nginx configuration,
reloads nginx, and then performs a new TLS handshake to prove convergence.

When nginx is already converged, RECONCILE returns success without reloading
nginx.

## Safety

Use the repository's disposable live integration environment for this scenario.

Do not rotate, replace, or modify the authoritative Certbot lineage merely to
exercise RECONCILE.

The live integration runner:

- creates an ephemeral local certificate authority;
- creates two short-lived leaf-certificate generations;
- starts a disposable nginx container;
- exposes it only on a dynamically assigned loopback port;
- mounts disposable certificate state;
- removes the disposable resources when the run completes.

The suite requires access to the Docker socket. Run it only from trusted source
on a trusted development host.

## Reproduce

From the repository root:

```bash
./tests/integration/run.bash --live
```

The relevant live test is:

```text
live mismatch validates reloads and serves the desired certificate
```

The disposable fixture starts nginx with certificate generation 2 loaded.

The test then repoints the disposable Certbot-style certificate symlinks to
generation 1 without reloading nginx. This deliberately creates certificate
drift:

```text
desired state: generation 1
served state:  generation 2
```

The generation numbers are fixture identifiers only; they do not imply
chronological ordering.

RECONCILE is then invoked to detect and repair that drift.

## Expected behavior

RECONCILE should:

1. observe a stable desired certificate;
2. obtain the served certificate through a live TLS handshake;
3. detect the mismatch;
4. validate nginx configuration with `nginx -t`;
5. reload nginx;
6. re-observe desired state;
7. perform another live TLS handshake;
8. return success only after served state matches desired state.

Expected output includes:

```text
Mismatch detected
Reload verified
```

The live test additionally verifies that:

- RECONCILE exits `0`;
- the served SHA-256 leaf fingerprint matches the desired generation;
- nginx workers are replaced by the reload.

## Already-converged follow-up

The live suite also verifies the already-converged path.

Expected behavior is:

```text
Already converged
No reload performed
```

and the nginx worker set remains unchanged.

This demonstrates operational idempotence.

## Related validation

Executable validation:

```text
tests/integration/reconcile-live.bats
tests/integration/run.bash
```

Architecture:

```text
docs/architecture/reconciliation.md
```

The integration suite also exercises invalid nginx configuration, TLS
verification failure, and concurrent reconciliation. Those failure cases remain
test-suite concerns rather than separate manual fault-injection procedures.
