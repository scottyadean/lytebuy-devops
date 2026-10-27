variable "env" {
  description = "Environment name (dev, prod). Used in resource names and SSM paths."
  type        = string
}

variable "account_id" {
  description = "AWS account id (guardrail + deterministic SSM ARNs)."
  type        = string
  default     = "329104270934"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-west-2"
}

# --- DNS / TLS --------------------------------------------------------------

variable "root_domain" {
  description = "Existing Route53 hosted zone (public)."
  type        = string
  default     = "lytebuy.com"
}

variable "api_hostname" {
  description = "Public API hostname, e.g. dev-api.lytebuy.com. Must be under root_domain and covered by the *.lytebuy.com ACM cert."
  type        = string
}

# The HUMAN-FACING app, which is NOT the API. These are different hosts, and
# conflating them is not cosmetic: APP_PUBLIC_URL is what the backend puts in
# every email link, Stripe Connect return URL and share link. It was built from
# api_hostname, so a prod sign-in email linked to https://api.lytebuy.com/email-login
# - a URL with no such route, so the link was simply dead.
variable "app_hostname" {
  description = "Public app hostname, e.g. app.lytebuy.com. Where humans land from emails and Stripe redirects - NOT the API host."
  type        = string
}

# --- Networking -------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# --- Compute ----------------------------------------------------------------

variable "image_tag" {
  description = "ECR image tag to run for the backend container."
  type        = string
  default     = "latest"
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory (MiB). 512 fits the backend + redis sidecar for a beta."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "ECS service desired task count. The stop/start knob: 0 = no compute cost. Beta runs 1."
  type        = number
  default     = 0
}

variable "redis_sidecar_image" {
  description = "Redis image for the in-task sidecar."
  type        = string
  default     = "redis:7-alpine"
}

# --- Database ---------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS storage (GiB)."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "lytebuy"
}

variable "db_username" {
  description = "RDS master username. The master PASSWORD is NOT set here - it lives in SSM and is composed into DATABASE_URL out of band (see README/put-secrets)."
  type        = string
  default     = "lytebuy"
}

# --- Non-secret application env (mirrors docker-compose.prod.yml posture) ----

variable "cors_allowed_origins" {
  description = "CORS_ALLOWED_ORIGINS for the API (comma-separated)."
  type        = string
  default     = "https://lytebuy.com"
}

variable "media_bucket_name" {
  description = "S3 bucket name for product media. Defaults to lytebuy-media-<env>."
  type        = string
  default     = ""
}

# --- Secrets ----------------------------------------------------------------

variable "secret_names" {
  description = "Names of SSM SecureString params under /lytebuy/<env>/backend/ to inject into the task as `secrets`. Values are managed out of band by scripts/put-secrets.sh - never in tofu state."
  type        = list(string)
  default = [
    "SECRET_KEY",
    "DATABASE_URL",
    "ALEMBIC_DATABASE_URL",
    "FIRST_SUPERUSER_EMAIL",
    "FIRST_SUPERUSER_PASSWORD",
    "STRIPE_SECRET_KEY",
    "STRIPE_PUBLISHABLE_KEY",
    "STRIPE_WEBHOOK_SECRET",
    # STRIPE_CONNECT_CLIENT_ID is deliberately ABSENT. It is declared in
    # app/core/config.py:53 and read by NOTHING - a ca_... client id belongs to
    # OAuth-based Standard Connect, and lytebuy uses Express accounts created via
    # Account.create + AccountLink.create (services/connect.py), which authenticate
    # with the platform secret key alone.
    #
    # Listing it here would be worse than pointless: `secrets` entries are required
    # at launch, so ECS would refuse to start the task until an unused value was
    # invented and stored in SSM.
    "STRIPE_CONNECT_WEBHOOK_SECRET",
    "MAPQUEST_API_KEY",
    # MEDIA_STORAGE_ACCESS_KEY / MEDIA_STORAGE_SECRET_KEY are deliberately ABSENT.
    #
    # The task role (iam.tf, aws_iam_role.task) already grants Get/Put/Delete on
    # the media bucket, so the app does not need static keys at all. Both settings
    # default to None in app/core/config.py, and boto3 treats None as "use the
    # normal credential chain" - which on Fargate resolves to the task role.
    # Verified, not assumed: a client built with both keys None still resolves
    # credentials.
    #
    # Listing them here would FORCE static keys back: `secrets` entries are
    # required at launch, so ECS refuses to start the task if the SSM parameter
    # is missing. Two fewer long-lived credentials to store, rotate and leak.
    # PostHog error tracking - the only error reporter. Sentry was removed in
    # favour of one dashboard for client and server (2026-10-22).
    #
    # Safe to list because both have REAL values in secrets/backend.<env>.env,
    # so put-secrets.sh creates the SSM params. An EMPTY value would not: the
    # script skips empty lines, the parameter is never created, and - per the
    # launch rule above - ECS then refuses to start the task at all.
    #
    # ORDER MATTERS, same rule: run scripts/put-secrets.sh BEFORE `tofu apply`.
    # The other way round leaves a task definition pointing at parameters that
    # do not exist yet, and the service will not start.
    #
    # Both names, or neither: app/core/config.py requires BOTH to initialize
    # (a key with no host silently ships to PostHog Cloud US).
    "POSTHOG_API_KEY",
    "POSTHOG_HOST",
  ]
}

variable "log_retention_days" {
  description = "CloudWatch log retention (matches blog-service = 7)."
  type        = number
  default     = 7
}

variable "bastion_enabled" {
  description = "Create a tiny SSM bastion (t4g.nano) for direct psql access to the private RDS. Off by default; flip on when you need DB access, off to stop its cost."
  type        = bool
  default     = false
}

variable "media_public_read_prefixes" {
  description = <<-DESC
    Key prefixes inside the media bucket served to anonymous readers via a
    bucket policy, instead of a presigned URL (lb-28).

    EMPTY BY DEFAULT, so a new environment stays fully private and a mistake
    here cannot expose one. Production opts in through backend.tfvars; dev runs
    with none and is unaffected.

    WHY THIS EXISTS AT ALL. A product photo is loaded by every browser and app
    that renders a listing, including signed-out ones. Minting a presigned URL
    per image would make image_url expire, so a cached page or a shared link
    would break, and it would put the backend in the path of every thumbnail.
    Public read on exactly the prefixes that are already public is the honest
    shape - and it is what production has done since launch.

    SCOPE IS THE WHOLE POINT. These are per-prefix GetObject grants, never
    bucket-wide, and never ListBucket - so an anonymous caller can read a
    product image whose key they already have but cannot enumerate the bucket.
    Digital-download assets (vendors/*/downloads/*) are deliberately NOT here:
    those are the paywall, and they stay presigned-only.

    Each entry carries its own `sid` rather than deriving one from the prefix.
    That is not cosmetic: the statement ids have to match what production
    already has, or Terraform rewrites the live policy instead of adopting it -
    which is the exact drift this was meant to close. A derived name was tried
    first and produced "PublicReadVendorsLogos" against prod's
    "PublicReadVendorLogos" for all six statements.
  DESC
  type = list(object({
    sid    = string
    prefix = string
  }))
  default = []
}

variable "blog_media_bucket" {
  description = <<-DESC
    Bucket holding blog post images (LB-8.10). NOT created by this module - it
    predates it and already carries a public-read bucket policy on blog/*, which
    is what makes a cover image loadable by every reader without a presigned URL.
    The task role is granted access to blog/ only.
  DESC
  type        = string
  default     = "lytebuy-image-upload"
}

# --- Transactional email (LB-Client-6/7) ------------------------------------

variable "email_enabled" {
  description = <<-DESC
    Send transactional email (receipts, shipping notifications, refunds).
    FALSE by default so a new environment cannot mail real customers by
    accident; prod sets it true in backend.tfvars.
  DESC
  type        = bool
  default     = false
}

variable "email_from" {
  description = "Envelope sender. MUST be on a verified SES identity or every send fails."
  type        = string
  default     = "no-reply@lytebuy.com"
}

variable "email_from_name" {
  description = "Display name on the From header."
  type        = string
  default     = "lytebuy"
}

variable "email_reply_to" {
  description = "Where a customer's reply goes - a real inbox, not the no-reply sender."
  type        = string
  default     = "support@lytebuy.com"
}

variable "media_public_url" {
  description = <<-DESC
    Base URL the API puts in `image_url` for newly uploaded media, set as
    MEDIA_STORAGE_PUBLIC_URL on the task (lb-28).

    EMPTY BY DEFAULT, and empty means "build the direct S3 URL" - which is what
    app/services/storage.py:118 already does when the setting is None. So an
    environment that has no CDN keeps working unchanged rather than emitting
    URLs for a hostname that does not resolve.

    WHY THIS IS A PLAIN STRING AND NOT module.media_cdn.media_url. The CDN
    module takes the bucket name FROM this module, so reading its output back
    in here would be a dependency cycle. The caller passes the hostname it
    already owns to both.

    This only affects media uploaded AFTER it is set. Rows written earlier keep
    whatever absolute URL they were stored with, which is why lb-28 also
    rewrites the existing rows.
  DESC
  type        = string
  default     = ""
}
