#!/usr/bin/env bash
# Push backend secrets into SSM Parameter Store as SecureStrings, under
# /lytebuy/<env>/backend/<NAME>. Reads a gitignored secrets/backend.<env>.env
# (KEY=VALUE per line) - same fill-in-the-blanks UX as the old .env.production,
# but the values land in SSM (never in tofu state, never committed).
#
#   scripts/put-secrets.sh <env>
#
# The ECS task's execution role reads these at launch (see modules/.../iam.tf).
set -euo pipefail

ENV="${1:?usage: put-secrets.sh <env>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
FILE="$ROOT/secrets/backend.$ENV.env"

REGION="$(awk -F'"' '/^region/ {print $2}' "$ENV_DIR/backend.tfvars")"; REGION="${REGION:-us-west-2}"
PREFIX="/lytebuy/$ENV/backend"

[ -f "$FILE" ] || { echo "missing $FILE (copy secrets/backend.dev.env.example and fill it)" >&2; exit 1; }

count=0
placeholders=0
while IFS= read -r line || [ -n "$line" ]; do
  # Skip blanks and comments.
  case "$line" in ''|\#*) continue ;; esac
  name="${line%%=*}"
  value="${line#*=}"
  [ -n "$name" ] && [ -n "$value" ] || { echo "skipping malformed line: $line" >&2; continue; }

  # Refuse placeholders. Without this a FILL_ME / CHANGE_ME lands in SSM as a
  # real-looking SecureString, the task boots with it, and the failure surfaces
  # somewhere far away - a Stripe webhook that never verifies, or an S3 client
  # that 403s - with nothing pointing back to the unfilled secret. Failing here
  # is the cheapest place to find out.
  case "$value" in
    *FILL_ME*|*CHANGE_ME*|sk_test_...|pk_test_...|whsec_...|ca_...|your_rotated_key)
      echo "ERROR: $name is still a placeholder ($value)" >&2
      placeholders=$((placeholders + 1))
      continue
      ;;
  esac

  aws ssm put-parameter \
    --name "$PREFIX/$name" \
    --value "$value" \
    --type SecureString \
    --overwrite \
    --region "$REGION" >/dev/null
  echo "  put $PREFIX/$name"
  count=$((count + 1))
done < "$FILE"

echo "Pushed $count secrets to SSM under $PREFIX."

if [ "$placeholders" -gt 0 ]; then
  echo >&2
  echo "$placeholders secret(s) were NOT pushed because they are still placeholders." >&2
  echo "The service will not work correctly until they are filled in and this is re-run." >&2
  exit 1
fi
echo "If the service is running, roll it to pick up changes:"
echo "  scripts/build-push.sh $ENV   # or: aws ecs update-service --force-new-deployment ..."
