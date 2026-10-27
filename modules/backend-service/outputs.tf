output "api_url" {
  description = "Public HTTPS URL of the API."
  value       = "https://${var.api_hostname}"
}

output "alb_dns_name" {
  description = "The ALB DNS name (stable across stop/start)."
  value       = aws_lb.this.dns_name
}

output "rds_endpoint" {
  description = "RDS host - used to compose DATABASE_URL/ALEMBIC_DATABASE_URL in SSM."
  value       = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = var.db_name
}

output "db_username" {
  value = var.db_username
}

output "ecr_repository_url" {
  description = "Push backend images here (scripts/build-push.sh)."
  value       = aws_ecr_repository.backend.repository_url
}

output "media_bucket" {
  value = aws_s3_bucket.media.id
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service" {
  value = aws_ecs_service.backend.name
}

output "rds_identifier" {
  value = aws_db_instance.this.identifier
}

output "bastion_instance_id" {
  description = "EC2 instance id of the SSM bastion (null when bastion_enabled=false)."
  value       = var.bastion_enabled ? aws_instance.bastion[0].id : null
}

output "db_tunnel_command" {
  description = "Local SSM port-forward that maps localhost:5432 -> RDS:5432 through the bastion. Then: psql 'postgresql://<user>:<pass>@localhost:5432/<db>'."
  value = var.bastion_enabled ? join(" ", [
    "aws ssm start-session",
    "--target ${aws_instance.bastion[0].id}",
    "--document-name AWS-StartPortForwardingSessionToRemoteHost",
    "--parameters '${jsonencode({
      host            = [aws_db_instance.this.address]
      portNumber      = ["5432"]
      localPortNumber = ["5432"]
    })}'",
  ]) : null
}
