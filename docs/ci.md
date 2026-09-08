# Continuous Integration

This repository uses GitHub Actions as a behavioral regression gate for the
nginx TLS certificate-consumer reconciliation implementation.

## Required checks

The stable pull-request check names are:

- `CI / Static`
- `CI / Unit & Contract`

Both checks run for pull requests targeting `development` or `main`, pushes to
`development` or `main`, and manual `workflow_dispatch` runs.

`CI / Unit & Contract` invokes the repository-owned `./tests/run.bash` entry
point. The workflow does not select individual Bats files.

`CI / Live Integration` runs only for trusted pushes to `development` or `main`
and manual `workflow_dispatch` runs. It is deliberately excluded from pull
requests because the suite mounts `/var/run/docker.sock` into its Bats runner
and therefore has broad control over the Docker daemon.

## Reporting

The unit/contract runner writes:

- `test-results/unit/report.tap`
- `test-results/unit/report.xml`

The live integration runner writes:

- `test-results/integration/report.tap`
- `test-results/integration/report.xml`

The workflow preserves each test step's original exit status, writes a readable
GitHub Actions job summary from TAP, and uploads TAP/JUnit even after test
failures.

Generated reports are not tracked by Git.

## Security boundary

Pull-request jobs use `pull_request`, never `pull_request_target`. The workflow
has only `contents: read` permission, persists no checkout credentials, and
receives no repository secrets.

The Docker live integration suite is not executed for pull requests. Trusted
execution is limited to pushes to protected project branches and explicit
manual workflow runs.

No production certificate material, DNS credentials, Certbot state, LAN access,
or other deployment secrets are required by CI. The live suite creates
disposable local certificate material and an ephemeral nginx container.

## Local workflow-equivalent validation

Run the standard checks:

```bash
bash -n \
  scripts/*.bash \
  tests/run.bash \
  tests/integration/run.bash

shellcheck \
  scripts/*.bash \
  tests/run.bash \
  tests/integration/run.bash

rm -rf test-results/unit
./tests/run.bash
```

Then, from a trusted local Docker environment with the target image available,
run:

```bash
rm -rf test-results/integration
./tests/integration/run.bash --live
```

Inspect:

```text
test-results/unit/report.tap
test-results/unit/report.xml
test-results/integration/report.tap
test-results/integration/report.xml
```

## Pinned GitHub Actions

External actions are pinned to immutable commits:

- `actions/checkout` v7.0.1: `3d3c42e5aac5ba805825da76410c181273ba90b1`
- `actions/upload-artifact` v7.0.1: `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`

Version comments in the workflow document the human-readable release while the
commit SHA is the executable reference.
