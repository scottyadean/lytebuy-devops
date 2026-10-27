# Root module for the DEV (beta) environment. Configures the provider + remote
# state, then calls the reusable backend-service module. Env-specific values live
# in backend.tfvars; the S3 backend is configured at init time from
# backend.tfbackend (see scripts/deploy.sh).

terraform {
  required_version = ">= 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {} # configured via -backend-config=backend.tfbackend
}

provider "aws" {
  region = var.region

  # Guardrail: refuse to run against the wrong account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "lytebuy"
      Component   = "backend"
      Environment = var.env
      ManagedBy   = "opentofu"
    }
  }
}

# CloudFront only accepts an ACM certificate from us-east-1, whatever region the
# rest of the stack runs in. This alias exists solely so the client-web module can
# look that certificate up.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "lytebuy"
      Component   = "client-web"
      Environment = var.env
      ManagedBy   = "opentofu"
    }
  }
}

variable "env" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }
variable "api_hostname" { type = string }
variable "cors_allowed_origins" { type = string }
variable "app_hostname" {
  description = "Where the Expo web build is served, e.g. dev-app.lytebuy.com."
  type        = string
}
variable "image_tag" {
  type    = string
  default = "latest"
}
variable "db_bootstrap_password" {
  type      = string
  sensitive = true
}

variable "bastion_enabled" {
  description = "Create the SSM bastion for direct RDS access (see modules/backend-service/bastion.tf)."
  type        = bool
  default     = false
}

module "backend" {
  source = "../../modules/backend-service"

  env                   = var.env
  account_id            = var.account_id
  region                = var.region
  api_hostname          = var.api_hostname
  app_hostname          = var.app_hostname
  cors_allowed_origins  = var.cors_allowed_origins
  image_tag             = var.image_tag
  db_bootstrap_password = var.db_bootstrap_password
  bastion_enabled       = var.bastion_enabled
  # desired_count stays at its default (0) - scaling is owned by
  # scripts/start.sh / stop.sh, not tofv (the service ignores desired_count changes).
}

# The Expo web build (dev-app.lytebuy.com). Static S3 + CloudFront - no compute,
# because the export is a plain folder of files. Deployed by
# scripts/deploy-client.sh, not by tofu.
module "client_web" {
  source = "../../modules/client-web"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  env          = var.env
  app_hostname = var.app_hostname
}

output "api_url" { value = module.backend.api_url }
output "app_url" { value = module.client_web.app_url }
output "client_bucket" { value = module.client_web.bucket }
output "client_distribution_id" { value = module.client_web.distribution_id }
output "alb_dns_name" { value = module.backend.alb_dns_name }
output "rds_endpoint" { value = module.backend.rds_endpoint }
output "ecr_repository_url" { value = module.backend.ecr_repository_url }
output "media_bucket" { value = module.backend.media_bucket }
output "ecs_cluster" { value = module.backend.ecs_cluster }
output "ecs_service" { value = module.backend.ecs_service }
output "rds_identifier" { value = module.backend.rds_identifier }
output "bastion_instance_id" { value = module.backend.bastion_instance_id }
output "db_tunnel_command" { value = module.backend.db_tunnel_command }
