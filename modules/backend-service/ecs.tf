# ECS Fargate: one task running two containers - the backend + a redis sidecar.
# The sidecar is required because the backend entrypoint blocks on a TCP wait for
# Redis at boot (docker/backend/entrypoint.sh); ElastiCache would be always-on and
# unstoppable, defeating the cost goal, so Redis rides in-task on 127.0.0.1.
#
# desired_count is the STOP/START knob: 0 = no compute billed. Beta runs 1.
#
# MIGRATION TRAP (documented on purpose): the backend runs `alembic upgrade head`
# on boot. That is safe ONLY while exactly one task runs. Before ever setting
# desired_count > 1 or enabling rolling deploys that briefly run two tasks, split
# migrations into a one-off ECS RunTask and set RUN_MIGRATIONS=0 here (the
# entrypoint already honors that gate).

resource "aws_ecs_cluster" "this" {
  name = local.name
}

locals {
  backend_image = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"

  # Non-secret env mirrors the docker-compose.prod.yml posture. The entrypoint
  # wait-vars (POSTGRES_HOST/REDIS_HOST) MUST be set or the boot loop hangs.
  backend_env = concat([
    { name = "APP_ENV", value = "production" },
    { name = "APP_DEBUG", value = "false" },
    { name = "SEED_ON_STARTUP", value = "false" },
    { name = "STRIPE_WEBHOOK_INSECURE", value = "false" },
    # The APP host, not the API host - this is what goes in emails and Stripe
    # return URLs, and it is followed by a human in a browser.
    { name = "APP_PUBLIC_URL", value = "https://${var.app_hostname}" },
    { name = "CORS_ALLOWED_ORIGINS", value = var.cors_allowed_origins },

    # Redis sidecar on loopback.
    { name = "REDIS_URL", value = "redis://127.0.0.1:6379/0" },
    { name = "REDIS_HOST", value = "127.0.0.1" },
    { name = "REDIS_PORT", value = "6379" },

    # Entrypoint's Postgres wait target (the app reads DATABASE_URL separately,
    # from SSM). Host must be the RDS endpoint, port 5432.
    { name = "POSTGRES_HOST", value = aws_db_instance.this.address },
    { name = "POSTGRES_PORT", value = "5432" },

    # Transactional email via SES (LB-Client-6/7). These are NOT secrets - no
    # keys - so they live here rather than in SSM: the task role signs the
    # SendEmail call, exactly as it does for S3.
    #
    # EMAIL_ENABLED defaults to FALSE in app/core/config.py, which is why every
    # receipt and shipping notification was silently dropped in production even
    # though the code, templates and triggers were all built and tested.
    { name = "EMAIL_ENABLED", value = tostring(var.email_enabled) },
    { name = "EMAIL_REGION", value = var.region },
    { name = "EMAIL_FROM", value = var.email_from },
    { name = "EMAIL_FROM_NAME", value = var.email_from_name },
    { name = "EMAIL_REPLY_TO", value = var.email_reply_to },

    # Media -> S3.
    { name = "MEDIA_STORAGE_BACKEND", value = "s3" },
    { name = "MEDIA_STORAGE_BUCKET", value = local.media_bucket },
    { name = "MEDIA_STORAGE_REGION", value = var.region },
    { name = "MEDIA_STORAGE_USE_PATH_STYLE", value = "false" },
    ],
    # The CDN base URL, and ONLY when one is configured (lb-28). Appended as a
    # separate list rather than set inline because an empty string here is not
    # the same as absent: config.py treats None as "build the direct S3 URL",
    # while "" would make every image_url start with a bare "/".
    var.media_public_url == "" ? [] : [
      { name = "MEDIA_STORAGE_PUBLIC_URL", value = var.media_public_url },
    ],
  )

  # SSM SecureString params -> container `secrets` (resolved at launch, never in state).
  backend_secrets = [
    for name, arn in local.secret_arns : { name = name, valueFrom = arn }
  ]
}

resource "aws_ecs_task_definition" "backend" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "redis"
      image        = var.redis_sidecar_image
      essential    = true
      portMappings = [{ containerPort = 6379, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "redis"
        }
      }
    },
    {
      name      = "backend"
      image     = local.backend_image
      essential = true
      # Wait for the redis sidecar to be up before the backend's boot loop runs.
      dependsOn    = [{ containerName = "redis", condition = "START" }]
      portMappings = [{ containerPort = 8000, protocol = "tcp" }]
      environment  = local.backend_env
      secrets      = local.backend_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "backend"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "backend" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # public subnet egress (ECR/SSM/Stripe); no NAT.
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8000
  }

  # Give a fresh task time to migrate + boot before health checks fail it.
  health_check_grace_period_seconds = 120

  # stop/start flips desired_count out of band (scripts/stop.sh/start.sh); don't
  # let tofu fight those manual scale changes.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.https]
}
