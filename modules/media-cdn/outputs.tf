output "media_url" {
  description = "Base URL for MEDIA_STORAGE_PUBLIC_URL."
  value       = "https://${var.media_hostname}"
}

output "distribution_id" {
  description = "For cache invalidation after a deliberate overwrite."
  value       = aws_cloudfront_distribution.media.id
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.media.domain_name
}

output "resize_function_name" {
  value = aws_lambda_function.resize.function_name
}
