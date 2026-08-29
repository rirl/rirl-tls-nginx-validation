# rirl-tls-nginx-validation

Disposable Terraform-managed Docker/Nginx target for validating the existing
Let's Encrypt certificate for `atreides.lan.rirl.dev`.

The existing Certbot state remains external and is mounted read-only.

## Isolation defaults

```text
Container:       rirl-tls-validation-nginx
Docker network:  rirl-tls-validation
Host bind:       127.0.0.1
Host port:       18443
Container port:  443
Restart policy:  no
Certbot state:   read-only
```

## Status endpoints

```text
GET /healthz
GET /status
```

`/status` returns JSON containing certificate validity, expiry, days remaining,
issuer, serial number, configured warning threshold, and last check time.

`/healthz` returns HTTP 200 only while the certificate is healthy.

Default states:

```text
healthy   more than 30 days remaining
warning   30 days or fewer remaining
expired   certificate expiration passed
invalid   certificate unreadable or unparsable
```

The status is refreshed every 5 minutes by default.

## Docker health

Docker health is driven by `/healthz`:

```bash
docker inspect   --format '{{.State.Health.Status}}'   rirl-tls-validation-nginx
```

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

```bash
./scripts/validate.bash
```

## Destroy

```bash
./scripts/destroy.bash
```
