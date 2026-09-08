resource "local_file" "runtime_env" {
  filename             = "${path.module}/generated/runtime.env"
  directory_permission = "0755"
  file_permission      = "0644"

  content = <<-EOT
TLS_HOSTNAME=${var.tls_hostname}
HTTPS_HOST_IP=${var.https_host_ip}
HTTPS_HOST_PORT=${var.https_host_port}
CONTAINER_NAME=${var.container_name}
EOT
}