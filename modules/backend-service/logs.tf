resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/lytebuy-backend-${var.env}"
  retention_in_days = var.log_retention_days
}
