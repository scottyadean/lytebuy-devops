#!/usr/bin/env bash
# START the environment: bring RDS up FIRST, wait until it's available, then scale
# the ECS service to 1. Ordering matters - the backend entrypoint blocks up to 60s
# waiting for Postgres, so the DB must be reachable before the task boots. Finally,
# poll the public health endpoint until it reports ok.
#
#   scripts/start.sh <env>
set -euo pipefail

ENV="${1:?usage: start.sh <env>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
cd "$ENV_DIR"

REGION="$(awk -F'"' '/^region/ {print $2}' backend.tfvars)"; REGION="${REGION:-us-west-2}"
CLUSTER="$(tofu output -raw ecs_cluster)"
SERVICE="$(tofu output -raw ecs_service)"
RDS_ID="$(tofu output -raw rds_identifier)"
API_URL="$(tofu output -raw api_url)"

echo "Starting RDS $RDS_ID ..."
aws rds start-db-instance --db-instance-identifier "$RDS_ID" --region "$REGION" >/dev/null \
  || echo "(RDS already available or starting)"

echo "Waiting for RDS to be available (this can take a few minutes)..."
aws rds wait db-instance-available --db-instance-identifier "$RDS_ID" --region "$REGION"

echo "Scaling $SERVICE to 1 task..."
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 1 --region "$REGION" >/dev/null

echo "Waiting for the service to stabilize (task running + ALB healthy)..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"

echo "Checking $API_URL/api/v1/health ..."
for i in $(seq 1 30); do
  body="$(curl -fsS "$API_URL/api/v1/health" 2>/dev/null || true)"
  case "$body" in
    *'"status":"ok"'*) echo "Healthy: $body"; exit 0 ;;
  esac
  sleep 5
done

echo "Started, but health did not report ok in time. Last response:" >&2
echo "  ${body:-<none>}" >&2
echo "Check logs: aws logs tail /ecs/lytebuy-backend-$ENV --follow --region $REGION" >&2
exit 1
