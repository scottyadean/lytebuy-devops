variable "env" {
  description = "Environment name (dev, prod). Used in resource names."
  type        = string
}

variable "root_domain" {
  description = "Route53 zone apex. The wildcard cert and the zone are looked up from this."
  type        = string
  default     = "lytebuy.com"
}

variable "app_hostname" {
  description = "Hostname the client web build is served at, e.g. dev-app.lytebuy.com."
  type        = string
}
