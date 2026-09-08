# NGINX validation container availability validation

## Scope

This validation covers the availability behavior of the
`rirl-tls-validation-nginx` consumer after changing its Docker restart policy
from `no` to `unless-stopped`.

The RECONCILE correctness contract is unchanged by this work.

## Implementation under test

Commit:

```text
8f5fcfc feat(tls): enable nginx validation container restart policy
```

Terraform configuration:

```hcl
restart = "unless-stopped"
```

The Docker provider also resolves the managed container with:

```text
must_run = true
```

Terraform therefore expects the managed container to exist and be running when
Terraform reconciliation occurs, while Docker enforces runtime restart behavior
between Terraform runs.

## Baseline finding

Before the change, the container was configured with:

```text
restart=no
```

A previously running container had exited cleanly with exit code `0` and was not
automatically restarted.

The Docker object was later absent while Terraform state still contained the
managed container resource. `terraform plan` detected this drift and proposed
recreating the missing container.

## Validation matrix

### Terraform recovery and deployment

`terraform apply` recreated the missing validation container with:

```text
status=running
health=healthy
restart=unless-stopped
restart-count=0
```

Result: PASS.

### Unexpected PID 1 termination

The host PID corresponding to container PID 1 was terminated externally with
SIGKILL.

Docker automatically restarted the container. The container returned to:

```text
status=running
health=healthy
```

and `RestartCount` incremented. Repeating the failure caused `RestartCount` to
increment again.

Result: PASS.

### Explicit operator stop

The container was stopped with:

```text
docker stop rirl-tls-validation-nginx
```

The container remained stopped and Docker did not automatically restart it.

This confirms that `unless-stopped` preserves explicit operator intent.

Result: PASS.

### Docker daemon restart

The Docker daemon was restarted with:

```text
sudo systemctl restart docker
```

The validation container returned automatically without `terraform apply` or
`docker start` and returned healthy.

`RestartCount` did not increment during daemon-level recovery.

Result: PASS.

### Host reboot

Before reboot:

```text
status=running
health=healthy
restart=unless-stopped
restart-count=0
```

After a full host reboot:

```text
docker daemon: active
status=running
health=healthy
restart=unless-stopped
restart-count=0
```

The container returned automatically without Terraform reconciliation or manual
container startup.

Result: PASS.

### RECONCILE regression check

After host reboot, RECONCILE was executed against the restored container.

Result:

```text
Already converged: served certificate matches stable desired state.
No reload performed.
reconcile exit=0
```

The container remained:

```text
status=running
health=healthy
restart=unless-stopped
```

Result: PASS.

## Conclusion

The nginx validation consumer now satisfies the intended availability behavior:

- unexpected workload termination is automatically recovered by Docker;
- repeated unexpected termination continues to recover;
- explicit operator stop is respected;
- Docker daemon restart restores the consumer;
- host reboot restores the consumer;
- the established RECONCILE correctness contract remains unchanged.

The restart policy change therefore improves consumer availability without
altering certificate reconciliation semantics.
