locals {
  certbot_state_dir = pathexpand(var.certbot_state_dir)

  nginx_config = templatefile(
    "${path.module}/nginx/default.conf.tftpl",
    {
      tls_hostname = var.tls_hostname
    }
  )
}
