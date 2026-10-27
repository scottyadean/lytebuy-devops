# Three tiers: the ALB accepts HTTPS/HTTP from the world; the task accepts 8000
# only from the ALB; RDS accepts 5432 only from the task. The task's public IP is
# for EGRESS only - nothing inbound reaches it except via the ALB.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ingress to the load balancer"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    # Required for dualstack: without it the ALB accepts an IPv6 connection at
    # the listener and the security group drops it, which looks identical to the
    # IPv4-only failure it was meant to fix.
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description = "HTTP from anywhere (redirected to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    # Or an IPv6 client hitting http:// never even reaches the redirect.
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # NO explicit ipv6_cidr_blocks here, deliberately. An allow-all egress rule
    # (protocol "-1") already covers IPv6 - AWS attaches ::/0 itself - so adding
    # it fails the apply with InvalidPermission.Duplicate. The INGRESS rules do
    # need it spelled out; egress does not.
  }

  tags = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Backend task: inbound only from the ALB, egress anywhere"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App port from the ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Egress for ECR pull, SSM, Stripe, etc."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-task" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS: inbound Postgres only from the backend task"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from the task only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }

  tags = { Name = "${local.name}-db" }
}
