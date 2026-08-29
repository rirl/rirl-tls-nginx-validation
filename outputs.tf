output "status_endpoint" {
  value = "https://${var.tls_hostname}:${var.https_host_port}/status"
}

output "health_endpoint" {
  value = "https://${var.tls_hostname}:${var.https_host_port}/healthz"
}
