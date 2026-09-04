# NGINX validation container availability scenarios

## Purpose

These scenarios reproduce the availability semantics of the Terraform-managed
nginx validation consumer when Docker restart policy is:

```text
unless-stopped
```

Availability is intentionally separate from RECONCILE correctness.

The completed validation record is retained at:

```text
docs/validation/container-availability.md
```

## Preconditions

Apply the current Terraform configuration and confirm the container is running:

```bash
terraform apply

docker inspect \
  --format 'status={{.State.Status}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} restart-count={{.RestartCount}}' \
  rirl-tls-validation-nginx
```

Expected baseline:

```text
status=running
health=healthy
restart=unless-stopped
```

## Scenario: unexpected PID 1 termination

This tests recovery from unexpected workload death rather than an operator
request to stop the container.

Terminate the host process corresponding to container PID 1:

```bash
sudo kill -KILL "$(docker inspect --format '{{.State.Pid}}' rirl-tls-validation-nginx)"
```

Then inspect recovery:

```bash
docker inspect \
  --format 'status={{.State.Status}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} restart-count={{.RestartCount}}' \
  rirl-tls-validation-nginx
```

Expected behavior:

- Docker automatically restarts the container;
- status returns to `running`;
- health returns to `healthy`;
- `RestartCount` increases.

## Scenario: explicit operator stop

Stop the container intentionally:

```bash
docker stop rirl-tls-validation-nginx
```

Expected behavior:

- the container remains stopped;
- Docker does not automatically restart it.

Restore the consumer before continuing:

```bash
docker start rirl-tls-validation-nginx
```

Confirm it becomes healthy before running another scenario.

## Scenario: Docker daemon restart

This affects all containers managed by the local Docker daemon. Perform it only
when disruption to other local containers is acceptable.

```bash
sudo systemctl restart docker
```

Then verify the validation container returns automatically and becomes healthy.

No Terraform reconciliation or manual `docker start` should be required.

## Scenario: host reboot

This is the broadest availability test and interrupts the entire host.

Before reboot, capture:

```bash
docker inspect \
  --format 'status={{.State.Status}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} restart-count={{.RestartCount}}' \
  rirl-tls-validation-nginx
```

Reboot the host using the normal administrative procedure.

After the host and Docker daemon return, verify:

```bash
systemctl is-active docker

docker inspect \
  --format 'status={{.State.Status}} health={{.State.Health.Status}} restart={{.HostConfig.RestartPolicy.Name}} restart-count={{.RestartCount}}' \
  rirl-tls-validation-nginx
```

Expected behavior:

- Docker is active;
- the validation container returned automatically;
- the container is running and healthy;
- restart policy remains `unless-stopped`.

## RECONCILE sanity check

After an availability recovery, RECONCILE can verify that availability recovery
did not alter certificate-consumer correctness:

```bash
./scripts/reconcile.bash
```

For an already-converged consumer, expected behavior is:

```text
Already converged
No reload performed
```

## Validation record

The completed live validation and observed PASS results are retained at:

```text
docs/validation/container-availability.md
```

That file records what was actually validated. This document describes how the
behavior can be reproduced.
