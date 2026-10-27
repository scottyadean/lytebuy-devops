# Optional SSM bastion for direct psql access to the private RDS instance.
#
# RDS is publicly_accessible = false and its SG only admits the task SG, so there
# is no way in from a laptop. This tiny instance sits in a public subnet and is
# reached via AWS SSM Session Manager (no SSH key, no inbound port 22). A local
# `aws ssm start-session ... AWS-StartPortForwardingSessionToRemoteHost` then
# tunnels localhost:5432 -> RDS:5432 through it.
#
# Gated on var.bastion_enabled (default false) so it costs nothing until turned
# on, and can be destroyed independently by flipping the flag.

# Amazon Linux 2023 (ARM64) - has the SSM agent preinstalled.
data "aws_ssm_parameter" "al2023_arm" {
  count = var.bastion_enabled ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# The bastion's own SG: egress only (SSM is outbound-initiated). No inbound.
resource "aws_security_group" "bastion" {
  count       = var.bastion_enabled ? 1 : 0
  name        = "${local.name}-bastion"
  description = "SSM bastion: no inbound, egress anywhere (SSM + RDS)"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-bastion" }
}

# Allow Postgres from the bastion SG into RDS (in addition to the task SG rule).
resource "aws_security_group_rule" "db_from_bastion" {
  count                    = var.bastion_enabled ? 1 : 0
  type                     = "ingress"
  description              = "Postgres from the SSM bastion"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.bastion[0].id
}

# IAM: the instance role that lets SSM manage the box (Session Manager).
data "aws_iam_policy_document" "bastion_assume" {
  count = var.bastion_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  count              = var.bastion_enabled ? 1 : 0
  name               = "${local.name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume[0].json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.bastion_enabled ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.bastion_enabled ? 1 : 0
  name  = "${local.name}-bastion"
  role  = aws_iam_role.bastion[0].name
}

resource "aws_instance" "bastion" {
  count                  = var.bastion_enabled ? 1 : 0
  ami                    = data.aws_ssm_parameter.al2023_arm[0].value
  instance_type          = "t4g.nano"
  subnet_id              = values(aws_subnet.public)[0].id
  vpc_security_group_ids = [aws_security_group.bastion[0].id]
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = { Name = "${local.name}-bastion" }
}
