# Two roles:
#  - execution role: what ECS/Fargate itself needs to LAUNCH the task (pull the
#    ECR image, write logs, and resolve the SSM secrets into the container env).
#  - task role: what the APP needs at runtime (read/write the media bucket).

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role ---------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ECR pull + CloudWatch logs.
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Resolve the SSM SecureString secrets into the container env at launch.
data "aws_iam_policy_document" "exec_ssm" {
  statement {
    sid       = "ReadBackendSecrets"
    actions   = ["ssm:GetParameters"]
    resources = [local.ssm_param_arn_wildcard]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "exec_ssm" {
  name   = "${local.name}-exec-ssm"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.exec_ssm.json
}

# --- Task role (runtime app permissions) ------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# THE APP USES THIS ROLE DIRECTLY - no static keys.
#
# MEDIA_STORAGE_ACCESS_KEY / SECRET_KEY are deliberately absent from
# `secret_names` (see variables.tf). Both default to None in
# app/core/config.py, and boto3 treats None as "use the normal credential
# chain", which on Fargate is this role. Two fewer long-lived credentials to
# store, rotate and leak.
#
# Actions below are exactly what the code calls - verified by grepping
# app/services/storage.py, not guessed:
#   put_object, upload_fileobj      -> s3:PutObject
#   get_object, generate_presigned_url -> s3:GetObject
#   delete_object                   -> s3:DeleteObject
#   list_objects_v2 (paginated)     -> s3:ListBucket
#
# A presigned URL carries the SIGNER's permissions, so GetObject on the role is
# what makes a download link work for a buyer with no AWS identity at all.
data "aws_iam_policy_document" "task_media" {
  statement {
    sid = "MediaBucketObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      # REQUIRED by upload_fileobj. It switches to a multipart upload for large
      # files (digital goods are capped at 500 MB), and without Abort a failed or
      # cancelled upload leaves orphaned parts in the bucket that are billed
      # forever and are invisible in a normal object listing.
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.media.arn}/*"]
  }
  # Transactional email (LB-Client-6/7). The task role signs SendEmail, so the
  # app needs no SES keys of its own - EMAIL_ACCESS_KEY/SECRET_KEY stay unset.
  #
  # Resource "*" with a FROM-ADDRESS CONDITION rather than a bare grant: SES
  # identity arns are awkward to reference for a domain identity, and the
  # condition is the tighter control anyway - it stops this role sending as any
  # address other than the configured sender, even if application code passed a
  # different From.
  statement {
    sid = "SendTransactionalEmail"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.email_from]
    }
  }

  # Blog images (LB-8.10) live in a SEPARATE, pre-existing bucket that already
  # carries a public-read policy on blog/*. It is not managed by this module -
  # hence a literal arn rather than a resource reference - so the scope is
  # written as narrowly as the feature needs: objects under blog/ only, never
  # the whole bucket, and no delete.
  #
  # Without this the upload endpoint returns a 500 from botocore with an
  # AccessDenied that never reaches the editor as anything useful.
  statement {
    sid = "BlogMediaObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::${var.blog_media_bucket}/blog/*"]
  }
  # ListBucket is scoped by PREFIX rather than granted on the whole bucket: the
  # media library only ever lists blog/, and a bucket-wide list would expose
  # every other key in a bucket this module does not own.
  statement {
    sid = "BlogMediaList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.blog_media_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["blog/*"]
    }
  }
  statement {
    sid = "MediaBucketList"
    actions = [
      "s3:ListBucket",
      # Lets the app see and clean up its own in-flight multipart uploads. Pairs
      # with AbortMultipartUpload above; this one is on the BUCKET, not objects.
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.media.arn]
  }
}

resource "aws_iam_role_policy" "task_media" {
  name   = "${local.name}-task-media"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_media.json
}
