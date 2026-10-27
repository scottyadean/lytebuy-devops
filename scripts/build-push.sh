#!/usr/bin/env bash
# Build the lytebuy-backend image and push it to ECR, then roll the running task.
#
#   scripts/build-push.sh <env> [tag]
#   scripts/build-push.sh dev            # tag defaults to "latest"
#   scripts/build-push.sh dev v3
#
# Cross-builds for linux/amd64 (Fargate x86) because the Mac is arm64. Reads the
# ECR repo + cluster/service from the env's tofu outputs.
set -euo pipefail

ENV="${1:?usage: build-push.sh <env> [tag]}"
TAG="${2:-latest}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
BACKEND_DIR="$ROOT/../lytebuy-backend"

cd "$ENV_DIR"
REGION="$(awk -F'"' '/^region/ {print $2}' backend.tfvars)"
REGION="${REGION:-us-west-2}"
REPO="$(tofu output -raw ecr_repository_url)"
CLUSTER="$(tofu output -raw ecs_cluster)"
SERVICE="$(tofu output -raw ecs_service)"
REGISTRY="${REPO%%/*}"

echo "Logging in to ECR ($REGISTRY)..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building $REPO:$TAG (linux/amd64) from $BACKEND_DIR ..."
docker build --platform linux/amd64 -t "$REPO:$TAG" -t "$REPO:latest" "$BACKEND_DIR"

echo "Pushing..."
docker push "$REPO:$TAG"
docker push "$REPO:latest"

echo "Forcing a new deployment on $SERVICE ..."
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment --region "$REGION" >/dev/null || \
  echo "(service not scaled up yet - that's fine; start.sh will launch the new image)"

echo "Done. Pushed $REPO:$TAG"
