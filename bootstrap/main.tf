# One-time bootstrap of the remote-state backend for lytebuy-devops.
#
# This stack uses LOCAL state (chicken/egg: it creates the very bucket the other
# stacks store their state in). Apply it once, commit nothing sensitive, and from
# then on every other stack uses the S3 backend + DynamoDB lock created here.
#
#   cd bootstrap && tofu init && tofu apply
#
# Idempotent: safe to re-run. Destroying it would orphan every other stack's
# state, so it sets prevent_destroy on the bucket and table.

terraform {
  required_version = ">= 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Guardrail: refuse to run against the wrong account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "lytebuy"
      Component = "devops-state"
      ManagedBy = "opentofu"
    }
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "account_id" {
  type    = string
  default = "329104270934"
}

locals {
  state_bucket = "lytebuy-tofu-state-${var.account_id}-${var.region}"
  lock_table   = "lytebuy-tofu-locks"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

# Versioning lets us recover a clobbered or corrupted state file.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# State can contain sensitive values - never allow public access.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}
