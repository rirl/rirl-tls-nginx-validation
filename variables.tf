variable "container_name" {
  type    = string
  default = "rirl-tls-validation-nginx"
}

variable "network_name" {
  type    = string
  default = "rirl-tls-validation"
}

variable "tls_hostname" {
  type    = string
  default = "atreides.lan.rirl.dev"
}

variable "certbot_state_dir" {
  type    = string
  default = "~/.local/share/rirl-lan-tls/letsencrypt"
}

variable "https_host_ip" {
  type    = string
  default = "127.0.0.1"
}

variable "https_host_port" {
  type    = number
  default = 18443
}

variable "certificate_warning_days" {
  type    = number
  default = 30
}

variable "status_refresh_seconds" {
  type    = number
  default = 300
}
