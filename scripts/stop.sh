#!/usr/bin/env bash
# STOP the environment to save money: scale the ECS service to 0 tasks, then stop
# the RDS instance. The ALB + DNS stay up, so https://<api_hostname> keeps
# resolving (it just returns 503 with no healthy targets) and the Stripe webhook
# config never has to change. All data in RDS survives.
#
#   scripts/stop.sh <env>
set -euo pipefail

ENV="${1:?usage: stop.sh <env>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
cd "$ENV_DIR"

REGION="$(awk -F'"' '/^region/ {print $2}' backend.tfvars)"; REGION="${REGION:-us-west-2}"
CLUSTER="$(tofu output -raw ecs_cluster)"
SERVICE="$(tofu output -raw ecs_service)"
RDS_ID="$(tofu output -raw rds_identifier)"

echo "Scaling $SERVICE to 0 tasks..."
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 0 --region "$REGION" >/dev/null

echo "Waiting for tasks to drain..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" || true

echo "Stopping RDS $RDS_ID (AWS auto-restarts it after 7 days)..."
aws rds stop-db-instance --db-instance-identifier "$RDS_ID" --region "$REGION" >/dev/null \
  || echo "(RDS already stopped or stopping)"

echo "Stopped. Compute is now \$0; you still pay the ALB (~\$17/mo) + RDS storage."
echo "The URL stays live and returns 503 until you run: scripts/start.sh $ENV"
