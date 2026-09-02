# Nginx Certificate Reconciliation Architecture

## Purpose

`rirl-tls-nginx-validation` is the certificate consumer for the current nginx
validation target.

Its stable external responsibility is:

```text
RECONCILE
```

The caller asks the consumer to reconcile. The consumer owns all nginx-specific
mechanics required to prove convergence.

## Contract

```text
exit 0     consumer is proven converged on the currently authoritative certificate
exit 1     convergence could not be established
exit 2     reconciliation could not be attempted because of usage/environment
```

The caller should not depend on implementation details beyond this contract.

## Desired State

The currently authoritative certificate is the certificate visible to nginx
through its read-only Certbot state mount.

RECONCILE derives the desired leaf-certificate SHA-256 fingerprint from inside
the nginx container. This keeps the desired-state observation in the same
filesystem namespace used by the consumer.

The reconciliation logic does not require access to the private key for
certificate identity comparison.

## Served State

Served state is measured independently from desired state.

RECONCILE performs a live TLS handshake against the configured nginx listener,
using the configured hostname for SNI and certificate verification, and derives
the SHA-256 fingerprint of the leaf certificate actually returned by nginx.

This distinction is fundamental:

```text
certificate file visible to nginx
```

is not the same fact as:

```text
certificate nginx is currently serving over TLS
```

A prior forced-renewal experiment proved that those states can diverge.

## Why status endpoints are not convergence proof

`cert-status.bash`, `/status`, and `/healthz` inspect the certificate file
visible inside the container.

They remain useful for certificate validity, expiry monitoring, and Docker
health, but they do not prove which certificate nginx is presenting to a TLS
client.

RECONCILE therefore does not use those mechanisms as its source of truth for
served state.

## Stable observation

Desired state can theoretically change while reconciliation is observing the
system.

To avoid comparing served state against a transient or stale desired value,
RECONCILE performs a stable observation:

```text
desired_before
served
desired_after
```

The observation is accepted only when:

```text
desired_before == desired_after
```

If desired state changes during the observation window, the operation retries
instead of declaring either convergence or mismatch from an unstable sample.

## Already-converged path

When:

```text
served == stable desired
```

RECONCILE returns success immediately.

No `nginx -t` and no reload are performed.

This makes repeated invocation operationally idempotent and avoids unnecessary
worker replacement.

## Mismatch path

When served state differs from stable desired state:

```text
1. validate nginx configuration with nginx -t
2. reload nginx
3. re-observe current desired state
4. re-probe the live TLS listener
5. prove served == current stable desired
```

Reload command success alone is never treated as convergence proof.

## Moving desired state after reload

Post-reload verification derives desired state again instead of reusing the
pre-reload fingerprint.

This allows reconciliation to converge on whichever certificate is currently
authoritative rather than proving success against a stale target captured
before the reload.

## Concurrency

A reconciliation lock serializes concurrent invocations.

This prevents two callers from independently observing the same mismatch and
issuing redundant overlapping reloads.

The live integration suite verifies that concurrent mismatch invocations
converge while producing only one nginx reload.

## Tactical deployment versus strategic interface

Strategically:

```text
certificate orchestrator -> RECONCILE interface
```

Currently:

```text
host-side reconcile.bash
        |
        v
Docker daemon
        |
        v
existing nginx container
```

The host-side script and Docker control path are tactical implementation
choices, not the architectural contract.

A future packaging or invocation mechanism may change without changing the
meaning of RECONCILE.

## Repository boundary

This repository owns:

- desired-certificate observation;
- served-certificate observation;
- nginx configuration validation;
- nginx reload;
- convergence proof;
- concurrency control;
- nginx-specific health and diagnostic behavior.

The orchestrating repository should not need to know:

- nginx command lines;
- container names;
- internal certificate paths;
- `/healthz` or `/status` implementation;
- fingerprint computation details.

## Validation

The current implementation has been validated through:

```text
22/22 mocked Bats contract tests
6/6 live integration tests
```

The live suite covers:

```text
already converged -> success without worker replacement
mismatch -> validate, reload, serve desired certificate
second invocation -> idempotent
invalid nginx config -> no reload
TLS verification failure -> reconciliation failure
concurrent mismatch -> convergence with one reload
```

## Historical review

The pre-implementation architecture review is retained at:

```text
docs/architecture/reviews/rirl-tls-architecture-review.md
```

It intentionally preserves findings from before RECONCILE was implemented.
Some gaps described there are now resolved and should not be interpreted as
current-state defects.

## Separate availability concern

Consumer availability is related to, but distinct from, reconciliation
correctness.

The current Docker restart policy remains `no`. Whether to change that policy,
for example to `unless-stopped`, should be handled as a separate availability
decision.
