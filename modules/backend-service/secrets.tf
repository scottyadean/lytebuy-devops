# Secrets are SSM SecureString params managed OUT OF BAND by scripts/put-secrets.sh
# under /lytebuy/<env>/backend/<NAME>. We construct their ARNs deterministically
# (never read the values) so no secret material lands in tofu state. The ECS task
# execution role resolves them at launch (see ecs.tf `secrets` block + iam.tf).

locals {
  ssm_prefix = "/lytebuy/${var.env}/backend"

  # name -> ARN, for the task definition `secrets` block.
  secret_arns = {
    for name in var.secret_names :
    name => "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.ssm_prefix}/${name}"
  }

  # Wildcard the execution role is allowed to read.
  ssm_param_arn_wildcard = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.ssm_prefix}/*"
}
