output "bucket" {
  description = "S3 bucket the web build is synced into."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = "CloudFront distribution id - needed to invalidate after a deploy."
  value       = aws_cloudfront_distribution.site.id
}

output "app_url" {
  description = "Public URL of the client web build."
  value       = "https://${var.app_hostname}"
}
