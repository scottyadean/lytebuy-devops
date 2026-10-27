# ECR repo for the backend image. scripts/build-push.sh builds --platform
# linux/amd64 (Fargate x86) and pushes here. Lifecycle keeps the last 10 images
# so old betas don't accumulate storage cost.

# PER-ENVIRONMENT, via local.name - "lytebuy-backend-dev", "lytebuy-backend-prod".
#
# This was hardcoded to "lytebuy-backend", unlike every other resource in the
# module, which only worked while dev was the only environment. Standing up prod
# failed with RepositoryAlreadyExistsException after RDS had already been created,
# because a repository name is unique per registry.
#
# Separate repos also mean a dev image cannot be deployed to production by a
# mistyped tag, and the "keep the last 10 images" lifecycle policy applies per
# environment rather than being shared between them.
resource "aws_ecr_repository" "backend" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
