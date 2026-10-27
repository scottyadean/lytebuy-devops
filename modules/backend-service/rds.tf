# Managed Postgres 16 - the durable store for buyer/vendor/ledger/Stripe data.
# db.t4g.micro single-AZ for the beta (~$13/mo running, ~$2/mo when stopped).
# Can be stopped up to 7 days via `aws rds stop-db-instance` (see scripts/stop.sh);
# AWS auto-starts it after 7 days.
#
# The master password is NOT managed here. It is generated when you fill
# secrets/backend.<env>.env and composed into DATABASE_URL/ALEMBIC_DATABASE_URL in
# SSM. `manage_master_user_password` would put Secrets Manager in the loop and
# charge per-secret; instead we set the password out of band on first create.
#
# NOTE: because the password is set out of band, the initial `tofu apply` creates
# the instance with a password from var.db_bootstrap_password (a throwaway you set
# once); rotate/set the real one via RDS modify or keep this bootstrap value and
# reference it in DATABASE_URL. For a beta, keeping the bootstrap password and
# putting it in the SSM DATABASE_URL is simplest. See README.

variable "db_bootstrap_password" {
  description = "Initial RDS master password (set once at create; goes into the SSM DATABASE_URL). Provide via TF_VAR_db_bootstrap_password env, never commit it."
  type        = string
  sensitive   = true
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = [for s in aws_subnet.public : s.id]
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_bootstrap_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  multi_az               = false
  publicly_accessible    = false

  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final"

  # Password lives in SSM (DATABASE_URL); don't let a tfvars drift force a change.
  lifecycle {
    ignore_changes = [password]
  }
}
