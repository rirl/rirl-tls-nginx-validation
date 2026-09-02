# Review: `rirl-lan-tls` / `rirl-tls-nginx-validation` — Certificate Lifecycle Architecture


> **Historical architecture review**
>
> This review records the state of `rirl-lan-tls` and
> `rirl-tls-nginx-validation` before the RECONCILE interface and its
> orchestration were implemented. Findings are preserved as reviewed evidence;
> some implementation gaps described below have since been resolved.
>
> For current behavior, consult the repository README and current RECONCILE
> implementation/tests.

Reviewed artifacts: `rirl-lan-tls.zip`, `rirl-tls-nginx-validation.zip` (as uploaded, current working-tree contents, not a git history). All findings below are grounded in the actual file contents inspected; where I infer beyond what's on disk, I say so explicitly.

---

## 1. Executive assessment

**Sound direction, under-implemented, with one real design gap in the proposed RECONCILE contract itself.**

The reconciliation-over-event-fan-out reasoning in the objective is correct, and the two-repository split is a reasonable boundary *in principle*. But the review has to be honest about where the repositories actually are:

- `rirl-lan-tls` currently implements **only `SCHEDULE → RENEW`**. There is no code anywhere in this repository that invokes a consumer, checks a consumer's health, or aggregates a lifecycle outcome. `ACTIVATE` and `VERIFY` do not exist as automation — they were performed **by hand** during the forced-renewal validation (see §10). So the "architectural boundary" between the two repos that the objective asks me to check for leaks is, right now, not being tested by any code at all: there's nothing on the `rirl-lan-tls` side to leak nginx details into, because it doesn't call anything.
- `rirl-tls-nginx-validation` has real building blocks (`cert-status.bash`, `reload.bash`, `validate.bash`) but **no RECONCILE-equivalent operation exists yet**. `reload.bash` is an unconditional "validate config, reload, refresh status" script — it always reloads, never compares desired-vs-served state, and never re-verifies the *served* certificate after reload. `cert-status.bash` inspects a certificate **file on disk**, not what nginx is actually presenting over TLS. This is the same gap the forced-renewal evidence itself surfaces: the file rotates the instant Certbot succeeds; the served certificate does not, until something reloads nginx. A `/healthz` built on file inspection will report "healthy" while nginx is serving a stale (but still valid) certificate — which is exactly the situation reconciliation is supposed to detect and fix.

So: the *philosophy* (reconciliation, small consumer interface, defer distributed machinery) is right and worth keeping. The *specific proposed contract* for RECONCILE has a latent flaw — "compare desired vs. served" is stated correctly in prose, but nothing in the repository yet defines *how* "served" is observed, and the one existing status mechanism (`cert-status.bash`) is the wrong tool for that job if reused naively. That has to be fixed at design time, not discovered after RECONCILE is declared stable.

Overall: **sound with important changes**, primarily to the "actually served" measurement inside `rirl-tls-nginx-validation`, and secondarily a set of smaller correctness gaps documented below (no locking, hardcoded restart policy despite it being described as configurable, stale/duplicated documentation, unproven canary semantics).

---

## 2. Repository reality

### `rirl-lan-tls`

Actually implemented:

- `scripts/renew-certificates.bash` — a `set -Eeuo pipefail` wrapper that:
  - parses `--dry-run` / `--force-renewal` (mutually exclusive), `-h`;
  - checks `docker` and `stat` are on `PATH`;
  - checks the Cloudflare credentials file exists **and** is mode `600` (via `stat -c '%a'`);
  - checks the Certbot state directory exists;
  - checks `docker info` succeeds (daemon reachable);
  - checks the pinned image (`certbot/dns-cloudflare:v5.7.0`) is already present locally, and runs `docker run --pull=never`, so an unattended run cannot silently upgrade the image;
  - runs `docker run --rm --pull=never --mount ...cloudflare.ini:ro --mount ...letsencrypt certbot/dns-cloudflare:v5.7.0 renew --non-interactive [--dry-run|--force-renewal]`.
  - This is it. The script prints a completion line and exits. There is no step after `certbot renew` returns.
- `systemd/user/rirl-lan-tls-renew.{service,timer}` — user-level oneshot service, `OnCalendar=*-*-* 00,12:00:00`, `RandomizedDelaySec=30m`, `Persistent=true`.
- `config/*.example` — non-secret templates, correctly kept out of git via `.gitignore` (`*.ini`, `*.env`, `letsencrypt/`, `*.key`, `*.pem`, etc.).
- `docs/evidence/2026-08-30-forced-renewal-validation/*` and `docs/evidence/2026-08-31-renewal-timer-restoration/*` — real captured artifacts (certificate fingerprints, journal excerpts, timer status), analyzed in §10.
- `docs/lets-encrypt-lan-rirl-dev-ubuntu-first.md` — a **superseded planning document**. It references `/opt/acme`, a system-level unit named `letsencrypt-docker-renew.timer`, and root-owned credential files — none of which match the current implementation (user-level systemd, `~/.local/share/rirl-lan-tls/letsencrypt`, `~/.config/rirl-lan-tls/...`). This is dead documentation sitting next to live documentation with no marker distinguishing them. It should be labeled historical or removed; a future reader (including a future automated agent) has no signal that it's obsolete.

Not implemented, despite being described in the objective as part of `rirl-lan-tls`'s ownership:

- renewal preflight beyond environment/credential checks (there is no check of certificate expiry state independent of what Certbot itself decides);
- "invoking required certificate consumers after renewal" — absent;
- "aggregating lifecycle outcome" — absent, there is only Certbot's own exit code;
- "reporting operational success or failure" as a distinct lifecycle concept — absent; today "success" == "the `docker run certbot renew` command exited 0," which conflates "no renewal needed," "renewal succeeded," and (implicitly, since nothing else runs) "the whole lifecycle is fine."

### `rirl-tls-nginx-validation`

Actually implemented:

- Terraform (`main.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `runtime.tf`, `providers.tf`, `versions.tf`) provisioning a Docker network, a locally built image, and a container named `rirl-tls-validation-nginx` (default from `variables.tf`), with:
  - `restart = "no"` **hardcoded as a literal string in `main.tf`** — this is not a variable. There is no `variable "restart_policy"` in `variables.tf`. The objective describes this as something that "currently may have a restart policy equivalent to `no`," implying it's a tunable; in the actual repo it is not tunable at all without editing `main.tf`.
  - Certbot state bind-mounted **read-only** at `/etc/letsencrypt` — correct, minimal.
  - nginx config injected via Terraform's `upload { content = ... }` (i.e., baked into the container by Terraform at `apply` time from `nginx/default.conf.tftpl`), not a live bind mount — a config change requires `terraform apply` (which recreates the container, per Terraform's semantics for `docker_container` content changes), not just an edit-and-reload.
  - A Docker healthcheck hitting `https://127.0.0.1/healthz` with `wget --no-check-certificate` — reasonable for a same-container liveness probe.
- `docker/Dockerfile` — `nginx:1.28-alpine` + `bash openssl coreutils python3`, copies `cert-status.bash` and `container-entrypoint.bash` in as the entrypoint.
- `scripts/container-entrypoint.bash` — runs `cert-status --once` at startup (best-effort, `|| true`), backgrounds a loop that re-runs it every `STATUS_REFRESH_SECONDS` (default 300s), then `exec nginx -g 'daemon off;'`.
- `scripts/cert-status.bash` — reads `/etc/letsencrypt/live/<host>/fullchain.pem` via `openssl x509`, computes `status` (`healthy`/`warning`/`expired`/`invalid`) from **notBefore/notAfter on the file**, and atomically (`mv` after temp-file write) publishes `status.json` and a `healthz` sentinel file that nginx serves via `alias`. **This never inspects what nginx is actually presenting over its TLS listener.** It is a certificate-file freshness monitor, not a served-certificate monitor.
- `scripts/reload.bash` — unconditionally: checks the container is running, `docker exec ... nginx -t`, `docker exec ... nginx -s reload`, `docker exec ... cert-status` (a file re-read, which cannot have changed as a result of the reload it just performed), then prints success. No comparison of desired vs. served state before or after.
- `scripts/validate.bash` — a genuinely useful **diagnostic**: dumps Docker health status, curls `/status` and `/healthz` (with `--resolve` to pin the target), and does a **live `openssl s_client -connect ... -servername ... -verify_return_error`** probe of the actual TLS handshake, printing the served certificate's subject/issuer/dates/serial/SAN. This is the correct technique for "what is nginx actually serving," and it is the one piece of the repo that does it. It is human-oriented output only (no comparison, no stable machine-readable success/fail signal beyond "did any command in the pipeline fail").
- `scripts/destroy.bash` — trivial `terraform destroy` wrapper.
- `terraform.tfvars` (present in the extracted archive, though `.gitignore` excludes it from git) sets `https_host_ip = "192.168.1.142"` — the actual LAN IP of the host — **overriding** the `README.md` "Isolation defaults" table and `variables.tf`'s documented default of `127.0.0.1`. The README's claim that the validation endpoint is bound to loopback is **not what is actually deployed**; it's reachable from the LAN, which is in fact required for the `harkonnen` cross-host canary evidence to work at all, but the README doesn't say that. This is a live documentation/implementation mismatch, not just a stale doc.

Not implemented:

- Any RECONCILE-shaped operation: nothing compares "desired/authoritative certificate" against "certificate actually served," skips action when already converged, or re-verifies the *served* certificate after taking action. `reload.bash` performs an action unconditionally; `cert-status.bash`/`validate.bash` observe state but don't compare or gate on it.
- Any defined certificate-identity comparison mechanism (fingerprint/serial/SPKI/etc.) — none of the scripts compute or compare an identity value between "on-disk" and "served." `cert-status.bash` extracts a serial from the file for display only; `validate.bash` extracts subject/issuer/dates/serial from the live connection for display only. Nothing puts these two values side by side.

---

## 3. Architecture evaluation

The intended rule — *"`rirl-lan-tls` knows a consumer must reconcile; it should not need to know how"* — is a good rule, and as things stand **it is not violated, because it is not yet exercised**. `rirl-lan-tls` contains zero references to nginx, Docker container names, `nginx -t`, TLS paths, or health endpoints. There's nothing to leak.

That's a pass by default, not a pass by design. The actual test of the boundary happens the moment someone wires `renew-certificates.bash` to call something in `rirl-tls-nginx-validation`. At that point the boundary is only as good as the interface chosen (§4). Two risks to flag now, before that wiring happens:

- **The `certbot_state_dir` path (`~/.local/share/rirl-lan-tls/letsencrypt`) is duplicated as a literal default in `variables.tf` in the *consumer* repo.** This is a shared assumption about how `rirl-lan-tls` lays out its state, sitting in the other repository, with no single source of truth. It happens to be consistent today. It is exactly the kind of coupling that the "boundary" concern is supposed to catch, and it's already present — just not yet exercised through an interface call.
- **The nginx config template hardcodes the assumption that the desired certificate is whatever `certbot`'s `live/<hostname>/` symlink currently points to**, with no indirection for "authoritative certificate" as a concept distinct from "whatever's in the mounted directory." That's fine for one host/one domain, but it means "authoritative certificate" is currently *defined implicitly* by filesystem convention, not stated anywhere as an explicit contract. Objective.md correctly flags this as something to interrogate (§4 below).

Verdict: the two-repository split is a reasonable foundation, but it hasn't been tested yet, because the interface it's meant to protect doesn't exist. Don't declare the boundary validated until RECONCILE exists and `rirl-lan-tls` actually calls it.

---

## 4. RECONCILE contract evaluation

Working through the objective's own checklist against what the repo currently makes possible:

**"Currently authoritative certificate" is not sufficiently well-defined today.** The only candidate definition available from the repo is "whatever `certbot`'s `live/<hostname>/fullchain.pem` symlink currently resolves to, as observed through the read-only bind mount at the moment RECONCILE runs." That's a workable definition, but it needs to be written down as the contract, because it has real edge cases the repo doesn't currently handle: Certbot's `live/` uses a symlink-to-`archive/N` scheme specifically so that renewal is atomic from a *reader's* perspective — but "atomic" here means the symlink swap is atomic, not that a reconciler reading through a bind-mounted directory can't observe a directory listing mid-swap on some filesystems/mount configurations. This is a low-probability but nonzero window; a symlink resolve immediately followed by a read is close to safe, and Certbot deliberately designs `live/` this way, so I would not add extra machinery for it now, but it's worth a one-line comment in the RECONCILE implementation rather than silent reliance on Certbot's atomicity guarantee.

**Certificate equality mechanism**: none is chosen yet. My recommendation, in order of preference:
1. **Leaf certificate SHA-256 fingerprint** (`openssl x509 -noout -fingerprint -sha256`) computed both from the on-disk `fullchain.pem`'s leaf cert and from the live TLS handshake's leaf cert (what `validate.bash` already extracts, minus the fingerprint step it's currently missing). This is unambiguous, doesn't require parsing SPKI, and directly answers "is this the same certificate object."
2. Serial number is an acceptable secondary/logging field (already extracted in both `cert-status.bash` and `validate.bash`) but should not be the *sole* comparison key — Let's Encrypt serials are large random-looking integers with no ambiguity risk, so this is a minor point, but fingerprint is the more standard and audit-friendly choice and costs nothing extra to compute.
3. Avoid SPKI-only comparison — SPKI would still match across a key-reuse renewal even though the certificate object itself changed, which is not what we want to detect ("is nginx serving *this* certificate," not "is nginx serving *a* certificate with this key").
4. Fullchain hash (whole file, including intermediates) is unnecessary; the leaf is what identifies "this issuance," and intermediate rotation from Let's Encrypt is a separate, rarer event that shouldn't be conflated with "did my renewal take effect."

**"Desired certificate can change during reconciliation" — yes, and the contract needs to say what happens then.** Realistic causes: a second renewal fires while the first RECONCILE is still running (unlikely at twice-daily cadence, but possible with manual `--force-renewal` overlapping a scheduled run), or an operator runs `reload.bash`/a future RECONCILE by hand while the timer also fires. The correct behavior is: **re-read desired state at the start of the post-reload verification step, not reuse the value captured before the reload began.** If they differ, that's not a failure — it's *"another change arrived, converge to whichever is authoritative now."* Concretely: capture `desired_before`, act if `desired_before != served`, reload, then re-derive `desired_after` and compare `served_after == desired_after` (not `== desired_before`). This makes RECONCILE naturally chase a moving target instead of asserting a stale one.

**Retries are safe only if RECONCILE is actually idempotent** (§6) — which requires the compare-before-reload step described above (item 4 of the proposed contract) to actually be implemented, since right now the only reload-capable script (`reload.bash`) always reloads.

**"nginx reload success is distinguishable from actual TLS convergence" — currently it is not, in `reload.bash`.** `nginx -s reload` returning 0 only means the signal was accepted and the new master accepted the config; it does not prove workers finished loading the new cert into their SSL contexts, nor that a subsequent TLS handshake will present it. The forced-renewal evidence (§10) demonstrates the gap manually was closed by taking a fresh `openssl s_client` sample *after* reload — that step needs to be inside RECONCILE, and today it isn't inside any script; it was done by hand.

**"Verification could accidentally observe an intermediary/proxy" and "stale mounts, symlinks, Docker volumes, DNS resolution, SNI, caching, race conditions"**: the single biggest structural risk here is that **`validate.bash`'s live-probe technique needs to be the one used for verification, not `cert-status.bash`'s file-read technique**, precisely because a file read cannot detect a proxy/cache/wrong-endpoint problem — only an actual TLS handshake against the real listener can. `validate.bash` already does this reasonably well: it uses `--resolve` on the curl calls and `-servername` on the `openssl s_client` call, which pins the target and exercises SNI correctly rather than trusting ambient DNS resolution. RECONCILE's verification step should reuse exactly this technique (ideally by calling into a probe function shared with `validate.bash`, not duplicating it a third time).

**Health/canary checks belong layered outside RECONCILE's core compare-act-verify loop, not fused into it.** RECONCILE's job is narrowly "prove the correct certificate is being served." A broader canary (e.g., checking `/` returns 200, checking response latency, checking a downstream dependency) is a different concern with a different failure semantics — a canary failure doesn't necessarily mean the certificate is wrong. Keep `cert-status.bash`'s `/healthz`/`/status` endpoints as a *separate*, continuously-refreshed liveness/expiry signal for external monitoring, and give RECONCILE its own on-demand, synchronous compare-act-verify path that doesn't depend on the 5-minute-refreshed background status file at all. Today RECONCILE would be tempted to shortcut by reusing `cert-status.bash`'s output — resist that; it's the wrong data source for the reason stated in §2/§10.

**Recommended minimal exit contract** (this directly answers the "smallest robust contract" ask in §11/§9 of the objective):

```
Exit 0   convergence proven: served certificate's SHA-256 fingerprint == desired
         certificate's SHA-256 fingerprint, as of a probe taken after any
         reload this invocation performed (or immediately, if no reload was
         needed).
Exit 1   convergence could not be established (config invalid, reload failed,
         post-reload probe still mismatches, probe itself failed/timed out,
         desired certificate unreadable/unparsable).
Exit 2   usage/environment error (bad arguments, container not found/not
         running, runtime config missing) — distinguishable from "tried and
         failed to converge" so a caller can tell "I couldn't even ask" from
         "I asked and it's not converged," per the objective's own §7 outcome
         list (7 vs. 5/6/8).
```

Nonzero-but-not-1/2 is unnecessary at this scale; two failure exit codes plus a clear stderr message covers everything the objective's outcome list distinguishes, and stderr/stdout content (not additional exit codes) should carry the "why."

---

## 5. Failure and recovery analysis

| # | Failure | Current behavior | Desired behavior | Recovery | Gap |
|---|---|---|---|---|---|
| 1 | Certbot renews, nginx reconciliation never runs | This is the **current default state of the whole system** — nothing runs after `certbot renew` | RECONCILE invoked and its exit code aggregated into lifecycle result | Next RECONCILE invocation (manual or future scheduled) converges | **Total gap**: no invocation exists at all |
| 2 | Certbot renews, nginx reload fails | `reload.bash` propagates `nginx -t`/`nginx -s reload` exit code via `set -e`; script exits nonzero, no lifecycle-level record | Nonzero RECONCILE exit surfaces as "activation failed," distinct from renewal outcome | Operator/timer reruns RECONCILE; old cert still served (nginx doesn't crash on failed reload) | Partial: exit propagation works in `reload.bash` itself, but nothing consumes that exit code today |
| 3 | Reload succeeds, nginx keeps serving old cert (worker didn't pick it up) | **Not detected.** `reload.bash` re-runs `cert-status`, which re-reads the same file, not the live socket, so it will report "healthy" regardless | Post-reload live probe (à la `validate.bash`) required before declaring success | Manual `validate.bash` run would catch it; nothing automated would | **Real gap**, matches the forced-renewal evidence's own operational finding |
| 4 | nginx already serves correct cert when reconciliation starts | `reload.bash` reloads anyway (unconditional) | Compare first; skip reload; still verify and return success | N/A — no failure, but unnecessary reload | **Gap**: violates idempotence requirement (item 4 of proposed contract) directly |
| 5 | Reconciliation process crashes mid-run | No process today does multi-step reconciliation, so nothing to crash mid-sequence; `reload.bash` failing mid-way leaves nginx in whatever state the last successful `docker exec` left it (e.g., config validated, reload not yet issued) | Re-invocation must be safe from any crash point — this is the core idempotence requirement | Re-run RECONCILE; compare-then-act design makes a repeat run naturally safe | Depends entirely on §6 being satisfied when RECONCILE is built |
| 6 | Host reboots after renewal, before reconciliation | Certbot state persists (bind mount / host filesystem); container has `restart = "no"`, so it does **not** come back automatically | Container/consumer availability should be independent of whether it happens to also own reconciliation timing | Manual `terraform apply`/`docker start`, or an operator running RECONCILE once reachable | Matches objective's own question about restart policy (§8 below) — currently `no` and not configurable |
| 7 | nginx container stopped when renewal occurs | `renew-certificates.bash` doesn't check for or depend on it at all — renewal succeeds regardless | Renewal should succeed independently (correct architecturally); a **subsequent required-consumer check** should surface degraded status | Next RECONCILE attempt when container is back | This is actually **correctly decoupled today**, by omission rather than design — renewal not depending on the consumer's runtime state is good, but there is no compensating check that later reports "consumer never actually applied it" |
| 8 | Reconciliation container/service stopped | `reload.bash` explicitly checks `docker inspect ... State.Running` and exits 1 with a clear message if not running | Same — this is already correct behavior for a "can't even invoke" case (outcome #7 in the objective's list) | Start the container, re-run | **No gap** — this one case is handled well |
| 9 | Docker unavailable | `renew-certificates.bash` checks `docker info` before attempting renewal and exits 1 with a clear message; `reload.bash` checks `command -v docker` | Same | Retry once Docker is back (next timer run, or manual) | **No gap** on the renewal side; reasonable on the reconcile side |
| 10 | Desired cert files exist but stale/incomplete/mis-mounted/inaccessible | `cert-status.bash` handles unreadable/unparsable files (`write_invalid_status`, exit 1); nothing currently defines "stale" beyond expiry math | RECONCILE should treat "can't read/parse desired cert" as a hard failure (exit 1/2), never as "already converged" | Fix mount/permissions, re-run | Partially handled for the *unreadable* case; "stale" (readable but not what's expected, e.g. wrong domain in SAN) is not checked anywhere |
| 11 | nginx config validates but runtime reload fails | `reload.bash` runs `nginx -t` then separately `nginx -s reload`; if `-s reload` fails, `set -e` aborts the script with nonzero exit | Distinguish "config invalid" (never reload) from "reload itself failed" (config was fine) in the reported outcome | Re-run after fixing whatever caused reload to fail (rare — reload failing after `-t` passes is unusual, e.g., permission or resource issue) | Minor gap: currently both failure modes just propagate as "the script failed," no differentiated message |
| 12 | Verification observes the wrong SNI/vhost | `validate.bash` correctly pins target with `--resolve` and `-servername`; `cert-status.bash` doesn't probe over the network at all so this doesn't apply to it | RECONCILE's verification must use explicit `-servername`/`--resolve`-style pinning, not ambient DNS | N/A if built correctly | No current gap in `validate.bash`'s technique; the gap is that this technique isn't reused anywhere reconciliation-shaped |
| 13 | DNS resolves to the wrong machine | `validate.bash` sidesteps this via `--resolve`/explicit `HTTPS_HOST_IP`; a naive RECONCILE that used plain hostname resolution instead would be vulnerable | Always pin the target IP/port explicitly for the verification probe, never rely on the LAN's or container's ambient DNS | N/A if built correctly | Design risk to avoid, not a current bug (nothing does DNS-dependent verification today) |
| 14 | Certbot reports "no renewal required" | Handled today — evidence in `docs/evidence/2026-08-31-renewal-timer-restoration/scheduled-renewal-run.txt` shows exactly this path, script logs "completed successfully" | Same, but this should be a distinct lifecycle outcome ("no renewal needed" ≠ "renewal succeeded") from #2/#9 in the objective's outcome list | N/A | Currently conflated: script's success message doesn't distinguish "renewed" from "not due," though the underlying Certbot log lines do carry that information if read |
| 15 | Reconciliation manually invoked independent of renewal | `reload.bash`/`validate.bash` can already be run standalone | Must remain safe/idempotent standalone — this is a design requirement for RECONCILE, not a bug today | N/A | Depends on §6 |
| 16 | Reconciliation runs twice concurrently | No locking anywhere in `rirl-tls-nginx-validation` scripts (no flock/lockfile) | Concurrent RECONCILE invocations should either serialize (flock) or be safe to interleave because each performs its own compare-act-verify against current state | Second invocation would currently just also run `nginx -t`/reload — likely harmless but wasteful, and could interleave two `docker exec nginx -s reload` calls with unclear ordering guarantees | **Real gap**: no lock exists; low risk at today's invocation frequency, but should be closed once RECONCILE is invoked automatically and possibly manually at the same time |
| 17 | Renewal and reconciliation overlap | No coupling exists yet, so no overlap is possible today by construction | Once wired, `rirl-lan-tls` should not invoke RECONCILE until `certbot renew` has fully returned (sequential by design, not concurrent) — the "invoke after renewal" pattern in the objective already implies this | N/A | Not a current gap given the linear design intent; flag as a requirement to preserve when wiring happens |
| 18 | Two certificate versions visible during a race | Only possible once concurrent access exists; addressed by capturing "desired" fresh at verification time (§4) rather than trusting a value read before acting | Re-derive desired state after acting, before declaring convergence | N/A if built correctly | Design requirement, not a current bug |
| 19 | Authoritative cert replaced mid-verification | Same as #18 — needs "verify against current desired, not captured desired" | Same | N/A | Design requirement |
| 20 | Machine restored from backup, local state stale | Nothing today detects this specifically; `cert-status.bash` would report whatever the restored file says, `validate.bash` would report whatever nginx is actually serving — the two could legitimately disagree post-restore | RECONCILE run once after restore would correctly detect and fix the mismatch, *if* the container/services are back up | Manual RECONCILE invocation post-restore | No special handling needed beyond RECONCILE itself existing and being safe to run on demand |
| — | (found in review, not in objective's list) `cert-status.bash`'s `/healthz` reports "healthy" based on file freshness, not served-certificate identity | As implemented | `/healthz` should remain a liveness/expiry signal; it must not be treated as proof of served-certificate convergence by any canary or RECONCILE reuse | N/A | **Real gap** — see §2, §4, §10 |
| — | (found in review) `reload.bash` always reloads regardless of current convergence state | As implemented | Compare before acting (contract item 4) | N/A | **Real gap** — directly contradicts the proposed RECONCILE contract |

---

## 6. Idempotence analysis

RECONCILE, as currently *proposed*, is not automatically idempotent just because it's specified with an if/else — idempotence has to be true of the *implementation*, and today the only reload-capable script (`reload.bash`) is provably **not** idempotent in effect (it performs a real reload on every call, satisfying "safe to call repeatedly" only in the weak sense of "doesn't corrupt state," not in the sense the objective wants: "no unnecessary reload").

What must be true for genuine idempotence:

1. **The compare-before-act step must exist and must be checked before any `nginx -t`/`nginx -s reload` is issued.** This is the single missing piece; everything else follows from it.
2. **The comparison must use the same certificate-identity representation on both sides** (§4: leaf SHA-256 fingerprint, computed fresh each call — never cached across invocations, since a cached "last known desired" value is itself a source of staleness).
3. **The "served" side of the comparison must come from a live TLS probe, not a file read**, or the comparison is comparing "file vs. file" and will never distinguish "renewed but not yet reloaded" from "renewed and reloaded" — which is precisely the bug that would make an operator believe reconciliation converged when it didn't.
4. **No mutation of "desired" state as a side effect of comparison.** None of the current scripts mutate the Certbot state directory (it's read-only mounted), so this is already satisfied structurally — worth preserving explicitly as an invariant when RECONCILE is written, since it's easy to accidentally break by, e.g., "helpfully" touching a marker file inside the mounted directory.
5. **Concurrency**: true idempotence under concurrent invocation additionally requires either a lock (simplest: `flock` on a well-known path, e.g., `/run/cert-status/reconcile.lock` inside the container, or a host-side lock if RECONCILE is invoked via `docker exec` from outside) or a design where two concurrent reloads are provably harmless (nginx reload is designed to be safe to call concurrently/repeatedly at the daemon level — old workers drain, new workers start — so two overlapping `nginx -s reload` calls are not by themselves dangerous; the risk is two overlapping *comparison* results racing each other's decision to act, which a lock resolves cleanly and cheaply at this scale).
6. **No reload should be treated as free.** Even a "harmless" nginx reload briefly cycles worker processes; calling RECONCILE from a monitoring loop at high frequency without the compare-first gate would turn "idempotent by contract" into "actually reloading every N seconds," which is the real-world failure mode idempotence is meant to prevent — not corruption, but *needless churn* that could show up as transient latency or connection resets under load. This is exactly why item 4 of the proposed contract matters operationally, not just aesthetically.

Given `flock` plus a fresh live-probe comparison before and after action, RECONCILE can be made genuinely idempotent with a small, well-understood implementation. Nothing about the current repository structure blocks this.

---

## 7. Security findings

**Critical:** none identified.

**High:** none identified.

**Medium:**
- `main.tf`'s nginx config is injected via Terraform `upload{}` from a template that only parameterizes `tls_hostname`; the container otherwise runs as root (no `user`/`read_only` root filesystem/`cap_drop` set on `docker_container.nginx_tls_validation`). This is normal for an nginx base image (nginx's master process needs root to bind privileged... actually 443 isn't privileged for the container's own namespace, but nginx images commonly still start as root and drop privilege internally) and is not urgent to change, but tightening with `cap_drop = ["ALL"]` plus only the capabilities nginx actually needs, and/or a read-only root filesystem with an explicit writable tmpfs for `/run/cert-status`, would reduce blast radius if the container were ever compromised through some other vector. This is future hardening, not a current exploitable gap given the LAN-only, single-purpose nature of the container.
- `README.md`'s documented "Isolation defaults" (`Host bind: 127.0.0.1`) do not match the deployed `terraform.tfvars` (`https_host_ip = "192.168.1.142"`, the LAN IP). This isn't a credential leak, but it is a live documentation/reality mismatch about network exposure that an operator reading only the README would get wrong. Fix the README to state the actual deployed default is LAN-reachable-by-design (which the cross-host `harkonnen` canary requires), or make `127.0.0.1` genuinely the default and treat the LAN IP as an explicit, called-out override.

**Low:**
- `cert-status.bash` only ever reads `fullchain.pem` (public certificate material), never `privkey.pem` — good hygiene; the reconciliation/status tooling doesn't need private key access even though the nginx process in the same container inherently does (it's the TLS terminator). Worth preserving as an explicit invariant when RECONCILE is added: RECONCILE's own logic should never need to touch `privkey.pem` either.
- Cloudflare credential handling in `rirl-lan-tls` is properly scoped: mode-600 check enforced by the script (not just documented), read-only bind mount into the ephemeral Certbot container, `.gitignore` excludes `*.ini`. No command-injection surface was found in `renew-certificates.bash` — all variable expansions are quoted, no `eval`, no unsanitized input reaches a shell metacharacter context (the only "input" is `--dry-run`/`--force-renewal`, matched via a fixed `case` statement).
- `reload.bash`/`validate.bash` similarly quote all expansions and don't construct commands from unsanitized input; `CONTAINER_NAME`/`TLS_HOSTNAME`/etc. come from a Terraform-generated `runtime.env` or explicit environment overrides, not from arbitrary user text at invocation time.
- `terraform.tfstate`/`terraform.tfvars`/`generated/runtime.env` were present in the extracted archive despite being `.gitignore`d (`.gitignore` excludes `.terraform/`, `*.tfstate*`, `terraform.tfvars`, `generated/`) — this is expected if the zip is a raw working-tree snapshot rather than a git export, and none of these files contain credentials (no Cloudflare token or key material passes through Terraform at all — correctly kept entirely inside `rirl-lan-tls`/Certbot). Worth a quick `git status`/`git ls-files` check to confirm these truly aren't tracked, since I can't verify git history from a zip.

**Future hardening (not urgent):**
- No `cap_drop`/non-root `user`/read-only rootfs on the validation container (noted above).
- No explicit TLS client trust-store pinning beyond default system CAs for the `harkonnen`-style cross-host canary (relies on standard Let's Encrypt chain trust, which is appropriate here — no need for anything heavier).
- No secrets platform (Vault, etc.) is needed at this scale; a single scoped Cloudflare token in a mode-600 file, kept out of git, matches the actual threat model (a home/LAN environment with one credential, one consumer). Introducing Vault now would be complexity without a corresponding threat.

---

## 8. Operational concerns

- **systemd**: user-level oneshot + calendar timer is the right level of mechanism for this problem — it doesn't need root, it composes with `Persistent=true` to catch missed runs across reboots/suspends, and `RandomizedDelaySec=30m` avoids thundering-herd-style simultaneous Cloudflare API calls (largely irrelevant at a single-host scale, but harmless). `Type=oneshot` correctly ties "service considered done" to "script exited," and systemd's own semantics prevent a second `start` of the same running oneshot unit — no extra locking is needed at the renewal-script level, though see §5 row 16/17 for the reconciliation side, which has no such protection once it exists as a separately-invocable script.
- No explicit `TimeoutStartSec` is set on the service unit — this inherits systemd's default (90s in most distros). DNS-01 with `--dns-cloudflare-propagation-seconds 30` plus ACME challenge round-trips could plausibly approach that on a slow network; worth setting an explicit generous timeout (e.g. `TimeoutStartSec=5m`) so a transient slow DNS propagation doesn't get killed mid-renewal and reported as a failure it wasn't.
- **Docker restart policy** is hardcoded `no` in `main.tf`, not exposed as a Terraform variable despite the objective treating it as something under active consideration. Given the container's actual role — it's not a public-facing service, it's a validation/canary target that's also, once reconciliation exists, in the critical path for "is TLS actually working" — I'd separate two concerns exactly as the objective suggests: **availability** (should the container come back after a host reboot or crash) is a Docker/systemd question, and **reconciliation correctness** (does the served cert match the desired cert) is RECONCILE's job regardless of restart policy. I'd lean toward `unless-stopped` *once RECONCILE exists*, specifically because an unreachable "required" consumer should currently cause the lifecycle to report failure per the objective's stated inclination (§9 below) — and a container that silently stays down after a reboot converts "renewal succeeded, activation temporarily pending" into "activation permanently never happens until someone notices," which is a worse operational failure mode than nginx restarting into a container that then gets reconciled on the next scheduled/manual RECONCILE run. I would not recommend automatic restart *before* RECONCILE exists, though — right now a restarted container would just come back serving whatever cert was last baked in, with no self-healing mechanism to notice drift, so restart-without-reconcile doesn't buy much. Sequence matters here (see §11).
- Docker health checks currently only drive `docker inspect`'s reported health status; nothing consumes that to *act* (no restart-on-unhealthy policy, no alerting integration mentioned in the repo). That's fine for now — the objective is right not to over-build this — but note it explicitly as "observability exists, automated response does not," so it isn't mistaken for more than it is.
- Logging: `renew-certificates.bash` logs to stdout/stderr with ISO-8601 timestamps, which journald captures cleanly (confirmed in `docs/evidence/2026-08-31-renewal-timer-restoration/scheduled-renewal-run.txt`). `reload.bash`/`validate.bash` use plain `printf`, fine for interactive/manual use; if RECONCILE is meant to be invoked by `rirl-lan-tls` and its output captured, consider a clear stdout/stderr split (human-readable summary to stdout, errors to stderr) since the caller will likely just check the exit code and log whatever came out.
- Manual forced renewal is supported cleanly via `--force-renewal`, and was used correctly for the evidence run — a reasonable "break glass" path that stays inside the same audited script rather than bypassing it.
- Recovery after reboot: Certbot state is host-persistent and outside the container lifecycle, which is correct; the validation container's `restart = "no"` means it does *not* come back automatically, which is the main reboot-recovery gap today (row 6, §5).

---

## 9. Configuration/coupling review

Duplicated or shared assumptions found:

| Value | Where it lives today | Assessment |
|---|---|---|
| `~/.local/share/rirl-lan-tls/letsencrypt` (Certbot state path) | Literal in `rirl-lan-tls/scripts/renew-certificates.bash` **and** default in `rirl-tls-nginx-validation/variables.tf` | Real duplication of a cross-repo assumption. Given the objective's own stated preference against premature shared infrastructure, I would **not** build a shared config module or generated-config pipeline for a single string. I would document the path explicitly as a stated contract in both READMEs (already partially done) and leave it duplicated — it's simple, it's obvious when it breaks (the container fails to find certs), and a shared-config mechanism would be more machinery than the problem justifies at one host, one domain. |
| `atreides.lan.rirl.dev` (TLS hostname) | Documented (not scripted) in `rirl-lan-tls`; a real Terraform variable default in `rirl-tls-nginx-validation` | Same reasoning — acceptable duplication at this scale. If a second host/domain is added, this is the first place I'd introduce a small shared values file (e.g., a `.env` or `.tfvars`-style file checked into a location both repos can read, or generated from one source), but not before there's a second consumer to justify it. |
| `rirl-tls-validation-nginx` (container name) | Only in `rirl-tls-nginx-validation`; appears in `rirl-lan-tls`'s evidence doc as **documentation only**, never in code | Correctly *not* leaked into `rirl-lan-tls` code today — this is the boundary working as intended, precisely because nothing calls the container yet. Keep it that way: when RECONCILE is wired, `rirl-lan-tls` should receive "how to invoke this consumer" (a command/path/target) via configuration, not learn the container name and reach for `docker exec` itself. |
| `18443` (validation HTTPS port), `192.168.1.142` (host IP) | `rirl-tls-nginx-validation` only | Not currently duplicated elsewhere — fine as is. |

None of this duplication is currently harmful. The objective is right to resist a monorepo or a generalized shared-config framework to eliminate a couple of duplicated strings — that would be solving a problem ("configuration drift across N consumers") that doesn't exist yet ("N=1 consumer, 1 host, 1 domain"). The one place I'd actually act now, cheaply, is making the **colocated invocation target configurable in `rirl-lan-tls`** (see §11) — not to eliminate duplication, but because it's the one piece of coupling that will otherwise get hardcoded as "call this exact container by this exact name" at the moment someone wires it up, which is precisely the premature lock-in the objective is trying to avoid.

---

## 10. Evidence quality

What `docs/evidence/2026-08-30-forced-renewal-validation/` actually proves, versus what it's presented as proving:

**Proven, with good rigor:**
- Certbot obtained a genuinely new production certificate (`pre-renewal-certificate.txt` / `post-renewal-certificate.txt` show distinct serials and SHA-256 fingerprints, with the `live/` archive generation advancing from `cert1.pem` to `cert2.pem`).
- nginx did **not** automatically pick up the new certificate immediately after renewal — `nginx-served-after-renewal-before-reload.txt` shows the *old* fingerprint still being served, captured via what appears to be a live TLS probe (the file's own text says "This file is a preserved contemporaneous observation from terminal output," which is a reasonable, if informal, provenance note).
- After a manual `nginx -t` + `nginx -s reload`, nginx served the new certificate — `nginx-served-after-reload.txt` shows the new fingerprint.
- The whole reload step was **manual**, performed by an operator, not by any script in the repository. The `README.adoc`'s own "Operational finding" section says this explicitly: *"A future implementation should ensure that reload occurs only after successful renewal"* — i.e., the evidence author already knows this wasn't automated. Good self-awareness in the evidence doc; worth preserving that honesty when this gets summarized elsewhere.

**Not proven, or proven more weakly than the surrounding narrative implies:**
- `atreides-canary.txt` and `harkonnen-canary.txt` contain only `Result: ok` with a timestamp — **no captured certificate identity alongside the canary result**, and no record of exactly what the canary checked. If the canary hit `/healthz`, then per §2/§4 above, `/healthz` is driven by `cert-status.bash`'s **file read**, not a live TLS probe — so a passing canary at that moment proves "the file on disk is a valid, non-expiring certificate," which by the time of these two files (captured *after* the reload, per the timestamps: `nginx-served-after-reload.txt` at 16:34:28, canaries at 16:35:12/16:38:07) is consistent with convergence but does not, by itself, *prove* convergence the way a fresh `openssl s_client` sample would. The stronger evidence for "harkonnen actually sees the new cert" would be a captured fingerprint from `harkonnen`'s own TLS handshake, which isn't present. This is a real, if minor, evidentiary gap: the strongest claim the evidence directory supports is "before reload the served cert was old; after reload, an `openssl`-based probe from the reconciliation host showed the new cert; separately, both hosts' canary checks returned ok a few minutes later" — which is good evidence but one inferential step short of "harkonnen cryptographically confirmed serving of the new certificate."
- The systemd timer was **intentionally paused** for this experiment (`README.adoc`: *"The normal renewal timer was intentionally paused before the experiment"*), and `systemd-timer-state.txt` shows `Active: inactive (dead)` with an odd log line: `rirl-lan-tls-renew.timer: Failed with result 'resources'`. That specific wording is unusual for a timer being deliberately disabled and is worth a follow-up to confirm it was benign (e.g., a side effect of how the timer was stopped) rather than a genuine resource-related failure that happened to coincide with the experiment. The `2026-08-31-renewal-timer-restoration/` evidence shows the timer subsequently active and firing correctly on schedule (`scheduled-renewal-run.txt` shows a clean "not yet due" run), which is reassuring but doesn't retroactively explain the odd log line from the day before.
- The forced renewal used `--force-renewal`, added as an ad hoc extension to the script for the experiment per the adoc ("The repository-approved renewal script was extended with an explicit `--force-renewal` option") — this matches what's actually in `renew-certificates.bash` today (the flag exists in the shipped script, not just as a one-off patch), so the evidence and the current script are consistent. Good.

**Net assessment**: the evidence convincingly establishes the *problem* (renewal alone doesn't rotate what nginx serves) and convincingly establishes that a *manual* reload procedure fixes it. It does **not** establish that any *automated* mechanism does this correctly, because no such mechanism exists yet to test. That's an honest gap, not a misrepresentation — the evidence doc's own "Follow-up" section already lists "define the nginx reload hook or equivalent post-renewal action" as outstanding work, which matches this review's findings.

---

## 11. Recommended implementation sequence

The proposed 10-step sequence is fundamentally correct — work inside `rirl-tls-nginx-validation` first, stabilize RECONCILE, only then touch `rirl-lan-tls`. I'd refine it as follows:

1. Make no further orchestration changes yet. *(agree)*
2. Work only in `rirl-tls-nginx-validation`. *(agree)*
3. **Before defining RECONCILE's code, write down the "authoritative certificate" definition and the comparison mechanism as a one-paragraph contract** (§4's answers above) — this is cheap and prevents the file-vs-served confusion from leaking into the implementation the way it currently exists in `cert-status.bash`.
4. Implement desired-versus-served comparison **as a small, separately testable function/script** (e.g., a `compare-cert` step that takes no action, just prints/returns match-or-not) — this can reuse `validate.bash`'s live-probe technique for "served" and `cert-status.bash`'s file-read technique for "desired," but must not conflate the two.
5. Verify the already-converged path (RECONCILE called when nothing needs to change: no reload, exit 0).
6. Implement validate → reload → **re-derive desired → re-probe served → compare** for the mismatch path — note the extra "re-derive desired" step relative to the original proposal, needed for the moving-target case (§4/§5 rows 18–19).
7. Add a `flock`-based (or equivalent) concurrency guard — this wasn't explicit in the original sequence but should land before step 8, since testing failure/recovery cases without it risks masking a real interleaving bug as a flaky test.
8. Test repeated invocation/idempotence (§6).
9. Test failure/recovery cases (§5's table as a test checklist).
10. Stabilize the interface (§4's CLI contract).
11. Only then modify `rirl-lan-tls` to invoke the consumer interface — and when this happens, invoke it via a **configurable target** (a config value naming the reconciliation command/container, with a sensible colocated default), not a hardcoded `docker exec rirl-tls-validation-nginx ...` inline in the orchestrator script (see §12 for why this specific piece of configuration is worth doing now rather than deferring).

---

## 12. Changes you would NOT make yet

- **Deploy-hook/event-bus mechanism** — defer. A concrete future requirement that would justify it: multiple consumers where near-real-time propagation actually matters operationally (e.g., a consumer with a much shorter acceptable staleness window than "next scheduled RECONCILE"), or a consumer that can't be cheaply polled/invoked on demand. At one consumer, twice-daily renewal checks, reconciliation is trivially invoked synchronously right after renewal — an event bus solves a coordination problem that doesn't exist yet.
- **Message queue** — defer, for the same reason; there's no producer/consumer decoupling need with a single orchestrator directly invoking a single consumer.
- **Distributed consumer registry** — defer until there's a second host or a second consumer that genuinely needs dynamic discovery rather than a static config value. The objective's own instinct (a small config override with a sensible default) is correct for "1–2 consumers, known in advance, mostly colocated."
- **Vault or another secrets platform** — defer; current threat model is a single scoped Cloudflare token, already handled with mode-600 files and `.gitignore`, matching a home-LAN scale. Justify this later only if the number of distinct secrets or the number of people/systems needing access grows meaningfully.
- **Kubernetes operators** — defer; there's one host and one container. This would be solving an orchestration problem the environment doesn't have.
- **Ansible/AWX orchestration** — defer; systemd timers plus small scripts are simpler and already proven for this scope. Reconsider only if the number of hosts genuinely grows past what a few systemd units and a config file can reasonably express.
- **Generalized certificate distribution framework** — defer; the objective's own "eventual abstraction" sketch (authority → authoritative state → consumers → reconciliation → verified convergence) is a fine *mental model* to keep in mind, but building the generalized framework now, for one consumer, is exactly the premature abstraction the objective warns against.
- **Premature shared libraries between the two repos** — defer per §9; the duplicated strings today are small and low-risk. Revisit if/when a second consumer repo appears and the duplication becomes 3-way.
- **Monorepo conversion** — defer; the current split is doing useful boundary-enforcing work (§3), and a monorepo would make it easier, not harder, for orchestration code to casually reach into consumer internals.

**One thing I would *not* defer, contrary to a strict reading of "avoid excessive interface design"**: making the reconciliation *invocation target* configurable in `rirl-lan-tls` (a config value with a colocated default, exactly as the objective already leans toward) should happen at the same time RECONCILE is first wired in — not as a later refactor — because the cost of doing it right the first time is near zero (one config variable) and the cost of doing it wrong the first time (a hardcoded `docker exec <container-name>` string baked into the orchestrator) is exactly the kind of accidental permanent coupling the objective is trying to avoid. This is consistent with, not contrary to, "don't build a registry" — it's the smallest possible version of that idea, not a preview of the larger one.

---

## 13. Concrete next patch

Scope: **`rirl-tls-nginx-validation` only.** No changes to `rirl-lan-tls` yet, per the agreed sequence.

**Files to add/change:**

- New: `scripts/reconcile.bash` — the RECONCILE implementation. Suggested shape:
  - Reuse `runtime.env`-sourcing pattern already established in `reload.bash`/`validate.bash`.
  - `desired_fingerprint()`: read the leaf cert from the mounted `fullchain.pem`, `openssl x509 -noout -fingerprint -sha256`.
  - `served_fingerprint()`: live probe exactly as `validate.bash` does (`openssl s_client -connect "${HTTPS_HOST_IP}:${HTTPS_HOST_PORT}" -servername "${TLS_HOSTNAME}" -verify_return_error`), piped to `openssl x509 -noout -fingerprint -sha256`.
  - Main flow: compute `desired`/`served`; if equal, exit 0 (no reload). If not equal: `docker exec ... nginx -t` (fail closed, exit 1, no reload on failure); `docker exec ... nginx -s reload`; re-read `desired` (fresh) and re-probe `served` (fresh); compare again; exit 0 only if they now match, else exit 1 with a clear stderr message distinguishing "reload ran but still mismatched" from "reload command itself failed."
  - Optional `flock` around the whole compare-act-verify sequence, keyed on a fixed path, to satisfy §6's concurrency requirement.
- Change: `scripts/cert-status.bash` — no functional change needed; **document in a comment at the top of the file** that this is a file-freshness monitor, explicitly not a served-certificate check, so a future reader doesn't reuse it as RECONCILE's verification step by mistake. This is cheap and directly prevents the confusion identified in §2/§4/§10.
- Change: `README.md` — fix the "Isolation defaults" table to reflect the actually deployed `https_host_ip` (or make `127.0.0.1` the true default and document the LAN override explicitly as an override, whichever is the intended long-term posture).
- Optional: `variables.tf` — add a `restart_policy` variable (default `"no"`) so the objective's own stated intent ("possibly `unless-stopped`... as a future availability consideration") has somewhere to land without editing `main.tf` directly when that decision is made.

**Tests to add** (shell-level, matching the existing style — no existing test framework was found in either repo, so plain scripted checks invoked manually or via a future CI step are appropriate at this scale):
1. Already-converged path: run `reconcile.bash` twice in a row against a stable cert; assert second run performs no `nginx -s reload` (can be asserted via `docker logs` timestamp/absence of a reload log line, or by instrumenting a counter) and both runs exit 0.
2. Mismatch path: force a stale served cert (e.g., start the container, then swap the mounted directory's content and re-point without reloading — or simply reuse the exact scenario already captured in the forced-renewal evidence), run `reconcile.bash`, assert exit 0 and that a live probe post-run shows the new fingerprint.
3. `nginx -t` failure path: inject an invalid config, assert `reconcile.bash` exits 1 **without** having issued `nginx -s reload` (assert via absence of a reload-related log entry, or by checking the previously-served cert is still what's served afterward).
4. Container-not-running path: stop the container, run `reconcile.bash`, assert a distinct exit code/message from the "ran but didn't converge" case (this already exists as a pattern in `reload.bash`'s `docker inspect` check — carry it over).
5. Concurrency: two overlapping invocations (backgrounded `&` in a test script) both eventually report a consistent final state; no partial/torn output in `status.json` (already protected by the existing tmp-file-then-`mv` pattern in `cert-status.bash` — verify `reconcile.bash` follows the same pattern for any output it writes).

**Acceptance criteria:**
- `reconcile.bash` exits 0 if and only if a live TLS probe against the actual listener shows the certificate's SHA-256 leaf fingerprint matching the currently mounted `fullchain.pem`'s leaf fingerprint, checked *after* any reload performed during that invocation.
- Calling `reconcile.bash` twice in immediate succession when already converged results in exactly one reload total (the first, if needed) — not two.
- `nginx -t` failure never results in `nginx -s reload` being issued.
- Exit codes distinguish "converged" (0), "attempted and failed to converge" (1), and "couldn't even attempt" (2 — container missing/not running/runtime config missing), matching §4's contract.

**Proposed stable RECONCILE CLI contract** (for `scripts/reconcile.bash`):

```
Invocation:    ./scripts/reconcile.bash
Inputs:        none required positionally; behavior is driven entirely by
               generated/runtime.env plus the same TLS_HOSTNAME / HTTPS_HOST_IP /
               HTTPS_HOST_PORT / CONTAINER_NAME environment overrides already
               supported by reload.bash/validate.bash.
Configuration: generated/runtime.env (Terraform-produced), overridable via
               environment variables of the same names, exactly matching the
               existing pattern in reload.bash/validate.bash — no new
               configuration mechanism introduced.
Exit codes:    0  converged (proven via live probe after any action taken)
               1  attempted, convergence not established
               2  could not attempt (environment/usage error, container
                  unreachable)
stdout:        human-readable one-line-per-step summary (no reload performed /
               reload performed and verified / etc.)
stderr:        error detail on nonzero exit
Structured
output:        not needed yet — add only if/when rirl-lan-tls needs to
               programmatically distinguish failure sub-reasons beyond the
               exit code; today's three-way exit code is sufficient for a
               caller that just needs "did activation succeed."
Timeout:       inherit caller's timeout (e.g., systemd's TimeoutStartSec once
               invoked from rirl-lan-tls); reconcile.bash itself should not
               need an internal timeout beyond openssl s_client's own
               connect-timeout behavior, which is already bounded.
Concurrency:   safe to invoke concurrently; internally serialized via flock
               around the compare-act-verify sequence.
Idempotence:   safe to call repeatedly; a call against an already-converged
               target performs no reload.
```

This is deliberately the smallest interface that satisfies the objective's own stated preference — a script with a stable CLI and exit-code contract, reusing the configuration pattern already established by `reload.bash`/`validate.bash`, with no new interface technology (no API, no socket, no Make target) introduced.

---

## Closing note on the invariant

> After a successful lifecycle run, every required consumer included in that lifecycle is proven to be serving the currently authoritative certificate.

This is the right invariant, and it's currently **false in practice** (per §10, only manually and partially demonstrated), but it's also **achievable** with the smallest of the changes described above — a compare-act-verify RECONCILE script that uses a live TLS probe for "served," not a file read. The invariant doesn't require anything more elaborate than that; the objective was right to resist reaching for event fan-out or heavier machinery to satisfy it. The gap between "invariant stated" and "invariant proven" here is a few dozen lines of shell reusing techniques already present in `validate.bash`, not an architecture problem.
