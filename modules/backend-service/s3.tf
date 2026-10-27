# S3 bucket for product media (MEDIA_STORAGE_BACKEND=s3). Uploads are durable
# from day one. The task role gets read/write (see iam.tf).
#
# TWO CLASSES OF OBJECT, and the difference is the whole access model:
#
#   - PUBLIC-READ prefixes (var.media_public_read_prefixes): product photos,
#     vendor logos, storefront art. Rendered by signed-out browsers and by the
#     app, so a presigned URL is the wrong tool - image_url would expire and a
#     cached page or shared link would break.
#   - EVERYTHING ELSE stays private and is reached only through a presigned URL
#     the backend mints. Digital-download assets live here; that is the paywall.
#
# This was DRIFTED until lb-28 (2026-10-24). Production had carried a
# hand-applied bucket policy with six public-read statements since launch,
# while this file declared `block_public_policy = true` and a comment saying
# the bucket was entirely private. The two had to be reconciled before any
# other change here: a `tofu apply` against the old declaration would have set
# block_public_policy back to true and taken every product image off the
# marketplace. Dev had NOT drifted, which is why the prefixes are a variable
# rather than hardcoded - dev keeps the fully private shape.

locals {
  media_bucket = var.media_bucket_name != "" ? var.media_bucket_name : "lytebuy-media-${var.env}"
}

resource "aws_s3_bucket" "media" {
  bucket = local.media_bucket
}

locals {
  media_public_read = length(var.media_public_read_prefixes) > 0
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  # ACLs stay blocked in every environment. ACL-based public access is the
  # legacy path and nothing here needs it - the policy below is how public read
  # is granted, which keeps the grant auditable in one place.
  block_public_acls  = true
  ignore_public_acls = true

  # These two must be false for the bucket policy below to be accepted, so they
  # follow whether any public prefix is configured. An environment with no
  # public prefixes keeps the fully locked-down shape.
  block_public_policy     = !local.media_public_read
  restrict_public_buckets = !local.media_public_read
}

# Public read, scoped to the configured prefixes.
#
# GetObject ONLY, and never ListBucket: an anonymous caller can read an object
# whose key they already hold, and cannot enumerate the bucket to discover
# others. Verified against production - an unauthenticated GET of a product
# image is 200, and a GET of the bucket root is 403.
resource "aws_s3_bucket_policy" "media_public_read" {
  count  = local.media_public_read ? 1 : 0
  bucket = aws_s3_bucket.media.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for entry in var.media_public_read_prefixes : {
        Sid       = entry.sid
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.media.arn}/${entry.prefix}"
      }
    ]
  })

  # The public-access-block must be relaxed before a public policy is accepted,
  # or the PutBucketPolicy call fails with AccessDenied on a fresh apply.
  depends_on = [aws_s3_bucket_public_access_block.media]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CORS so a browser can PUT to a presigned URL and GET media from the web client.
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = split(",", var.cors_allowed_origins)
    max_age_seconds = 3000
  }
}
