#!/usr/bin/env bash
# Apply the OpenTofu stack for one environment.
#
#   scripts/deploy.sh <env> [extra tofu apply args...]
#   scripts/deploy.sh dev
#   scripts/deploy.sh dev -auto-approve
#
# Requires TF_VAR_db_bootstrap_password in the environment (the RDS master
# password, set once at create). Everything else comes from environments/<env>/.
set -euo pipefail

ENV="${1:?usage: deploy.sh <env> [tofu args...]}"
shift || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
[ -d "$ENV_DIR" ] || { echo "no such environment: $ENV_DIR" >&2; exit 1; }

if [ -z "${TF_VAR_db_bootstrap_password:-}" ]; then
  echo "TF_VAR_db_bootstrap_password is not set (the RDS master password)." >&2
  echo "  export TF_VAR_db_bootstrap_password='...'  # then re-run" >&2
  exit 1
fi

cd "$ENV_DIR"
tofu init -input=false -backend-config=backend.tfbackend
tofu apply -input=false -var-file=backend.tfvars "$@"

echo
echo "Outputs:"
tofu output
