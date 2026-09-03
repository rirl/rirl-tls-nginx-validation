resource "docker_network" "validation" {
  name   = var.network_name
  driver = "bridge"
}

resource "docker_image" "validation" {
  name = "rirl-tls-nginx-validation:local"

  build {
    context    = path.module
    dockerfile = "docker/Dockerfile"
  }

  keep_locally = true
}

resource "docker_container" "nginx_tls_validation" {
  name    = var.container_name
  image   = docker_image.validation.image_id
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.validation.name
  }

  env = [
    "TLS_HOSTNAME=${var.tls_hostname}",
    "CERT_WARNING_DAYS=${var.certificate_warning_days}",
    "STATUS_REFRESH_SECONDS=${var.status_refresh_seconds}",
  ]

  ports {
    internal = 443
    external = var.https_host_port
    ip       = var.https_host_ip
    protocol = "tcp"
  }

  mounts {
    target    = "/etc/letsencrypt"
    source    = local.certbot_state_dir
    type      = "bind"
    read_only = true
  }

  upload {
    content = local.nginx_config
    file    = "/etc/nginx/conf.d/default.conf"
  }

  healthcheck {
    test = [
      "CMD-SHELL",
      "wget --no-check-certificate --quiet --spider https://127.0.0.1/healthz || exit 1"
    ]
    interval = "30s"
    timeout  = "5s"
    retries  = 3
  }
}
