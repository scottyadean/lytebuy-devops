# Static hosting for the Expo web build of lytebuy-client.
#
# dev-app.lytebuy.com -> CloudFront -> a PRIVATE S3 bucket.
#
# The Expo web export is a plain folder of files (`npm run build:web` -> dist/),
# so this needs no compute at all. Deploying is `aws s3 sync dist/` plus an
# invalidation - see scripts/deploy-client.sh.
#
# WHY NOT A PUBLIC S3 WEBSITE BUCKET: a website-endpoint bucket has to be public
# and cannot do HTTPS on a custom domain. CloudFront with Origin Access Control
# keeps the bucket private (no public-read policy anywhere) and terminates TLS
# with the existing wildcard cert. Same posture as the backend: nothing is
# world-readable that does not have to be.
#
# ~$1/mo at beta traffic: S3 storage is pennies and CloudFront's free tier covers
# the requests.

locals {
  name = "lytebuy-client-${var.env}"
}

data "aws_route53_zone" "root" {
  name         = "${var.root_domain}."
  private_zone = false
}

# CloudFront ONLY accepts a certificate from us-east-1, whatever region the rest
# of the stack lives in. The existing us-east-1 lytebuy.com cert already carries
# *.lytebuy.com as a SAN, so it covers dev-app.lytebuy.com - no second cert.
#
# LOOKED UP BY THE APEX, NOT THE WILDCARD, for the same reason as the ALB cert in
# backend-service/dns.tf: `domain` matches only a certificate's primary
# DomainName and does not search SANs, so "*.lytebuy.com" found nothing.
data "aws_acm_certificate" "wildcard_us_east_1" {
  provider    = aws.us_east_1
  domain      = var.root_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# --- the bucket -------------------------------------------------------------

resource "aws_s3_bucket" "site" {
  bucket = local.name
}

# Belt and braces with the OAC policy below: even if someone later attaches a
# public policy by hand, this blocks it.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  # A bad deploy is one `aws s3 sync` away from wiping the app. Versioning makes
  # that recoverable for the price of storing a few copies of a small bundle.
  versioning_configuration {
    status = "Enabled"
  }
}

# --- CloudFront -------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name
  default_root_object = "index.html"
  aliases             = [var.app_hostname]
  price_class         = "PriceClass_100" # NA + EU. Cheapest; lytebuy is US-only.

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed CachingOptimized.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # THE SPA RULE. Expo Router owns the URL: /orders and /product/abc exist in the
  # app but not as files in the bucket, so S3 answers 403/404. Without these, a
  # reload on any route but "/" shows an error page - and a shared product link
  # would be broken for everyone who clicks it.
  dynamic "custom_error_response" {
    for_each = [403, 404]
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.wildcard_us_east_1.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Only this distribution may read the bucket.
data "aws_iam_policy_document" "site" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

# --- DNS --------------------------------------------------------------------

# Alias records, so they follow the distribution if it is ever recreated.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.root.zone_id
  name    = var.app_hostname
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "app_aaaa" {
  zone_id = data.aws_route53_zone.root.zone_id
  name    = var.app_hostname
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}
