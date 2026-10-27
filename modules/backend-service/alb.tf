# Application Load Balancer: the STABLE public front door. Its DNS name persists
# when the ECS service is scaled to 0, so https://<api_hostname> never changes
# across stop/start - Stripe webhook config stays put. HTTP:80 redirects to
# HTTPS:443, which terminates TLS with the existing wildcard cert and forwards to
# the backend task on 8000.

resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  # DUALSTACK so the AAAA record in dns.tf points at something that answers.
  # While this was the default (ipv4), anything preferring IPv6 - notably
  # Amplify's Lambda compute - failed with "fetch failed" against an address the
  # ALB never listened on. Free: AWS bills public IPv4 addresses, not IPv6.
  ip_address_type = "dualstack"
}

resource "aws_lb_target_group" "backend" {
  name        = "${local.name}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip" # Fargate awsvpc tasks register by IP.

  health_check {
    path                = "/api/v1/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Give a booting task time to run migrations before the ALB starts counting
  # health failures against it.
  deregistration_delay = 30
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.wildcard.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
