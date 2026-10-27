#!/usr/bin/env bash
#
# Stand the dev backend up from nothing, in order, checking as it goes.
#
#   ./scripts/bringup.sh dev
#
# RESUMABLE BY DESIGN. Every step checks whether it is already done and skips if
# so, because the two steps in the middle NEED YOU - filling in the database URL,
# and registering the Stripe webhook - and a bring-up you cannot re-run after a
# pause is not much use. Run it, do what it asks, run it again.
#
# It does NOT auto-approve the tofu apply. That step creates ~$40/mo of billable
# infrastructure; you should read the plan.

set -euo pipefail

ENV="${1:-dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT/environments/$ENV"
SECRETS="$ROOT/secrets/backend.$ENV.env"

export AWS_PROFILE="${AWS_PROFILE:-lytebuy}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
skip() { printf '  \033[90mskip\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31mstop:\033[0m %s\n\n' "$1" >&2; exit 1; }

# Read one tofu output, or return empty.
#
# NOT just `tofu output -raw x`: when the output does not exist tofu exits 0 AND
# prints its "No outputs found" warning to STDOUT, so a naive check both reports
# success and captures the warning text as the value. That is exactly what went
# wrong the first time this ran - the script announced "already applied" against
# an empty state and then built a DATABASE_URL containing the warning banner.
#
# So: take the value, and reject anything that is not a single plausible line.
tf_out() {
  local v
  v=$(cd "$ENV_DIR" && tofu output -raw "$1" 2>/dev/null) || return 1
  case "$v" in
    ''|*Warning:*|*'│'*|*'╵'*) return 1 ;;
  esac
  printf '%s' "$v"
}

# A step that needs Scott. Exits 0, not 1: stopping to wait for a human is the
# script working, not failing.
pause() {
  printf '\n\033[33mNEEDS YOU:\033[0m %s\n\n' "$1"
  printf 'Then re-run:  ./scripts/bringup.sh %s\n\n' "$ENV"
  exit 0
}

[ -d "$ENV_DIR" ] || die "no such environment: $ENV_DIR"

bold "lytebuy backend bring-up ($ENV)"
echo "  profile: $AWS_PROFILE"

# --- 0. things that must be true before anything else -----------------------

command -v tofu  >/dev/null || die "tofu is not installed"
command -v aws   >/dev/null || die "aws cli is not installed"
aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS credentials are not working for profile '$AWS_PROFILE'"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ok "aws account $ACCOUNT"

# Only build-push needs docker, but failing here beats failing 10 minutes in.
docker info >/dev/null 2>&1 || die "docker is not running (needed to build the image)"
ok "docker running"

# The RDS master password. Needed TWICE - by the tofu apply, and again inside
# DATABASE_URL - and RDS will never show it to you again, so losing it means
# resetting the master password by hand.
#
# Stored in .db-password (gitignored, mode 600) rather than only in the
# environment, because this script is meant to be re-run: exporting a secret
# again on every run is how it ends up in shell history or, worse, typed
# differently the second time.
PW_FILE="$ROOT/.db-password"

if [ -z "${TF_VAR_db_bootstrap_password:-}" ] && [ -f "$PW_FILE" ]; then
  TF_VAR_db_bootstrap_password="$(cat "$PW_FILE")"
  export TF_VAR_db_bootstrap_password
  ok "db password loaded from .db-password"
elif [ -z "${TF_VAR_db_bootstrap_password:-}" ]; then
  printf '\n  No RDS master password set.\n'
  printf '  [g] generate one   [t] type mine   [q] quit\n  > '
  # Prefer the terminal so this still works when the script is piped, but fall
  # back to stdin. The test OPENS /dev/tty rather than just checking -r: in a
  # sandbox or CI the node can exist and be readable yet fail on open.
  if (exec </dev/tty) 2>/dev/null; then
    read -r choice </dev/tty
  else
    read -r choice
  fi
  case "$choice" in
    g|G)
      # RDS rejects / @ " and spaces in a master password, so the alphabet is
      # restricted rather than using a general-purpose generator.
      TF_VAR_db_bootstrap_password=$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits+'-_.~';print(''.join(secrets.choice(a) for _ in range(32)))")
      ;;
    t|T)
      # -s so it does not land in the terminal scrollback.
      printf '  password: '
      if (exec </dev/tty) 2>/dev/null; then
        read -rs TF_VAR_db_bootstrap_password </dev/tty
      else
        read -rs TF_VAR_db_bootstrap_password
      fi
      printf '\n'
      [ -n "$TF_VAR_db_bootstrap_password" ] || die "empty password"
      case "$TF_VAR_db_bootstrap_password" in
        */*|*@*|*\"*|*\ *) die "RDS rejects / @ \" and spaces in a master password" ;;
      esac
      ;;
    *) die "no password, stopping" ;;
  esac
  export TF_VAR_db_bootstrap_password
  ( umask 077; printf '%s' "$TF_VAR_db_bootstrap_password" > "$PW_FILE" )
  ok "db password saved to .db-password (gitignored, mode 600)"
else
  # Already exported - keep a copy so a later run does not need it again.
  [ -f "$PW_FILE" ] || ( umask 077; printf '%s' "$TF_VAR_db_bootstrap_password" > "$PW_FILE" )
  ok "db password set"
fi

# --- 1. remote state --------------------------------------------------------

bold "1. Remote state backend"
REGION=$(awk -F'"' '/^region/ {print $2}' "$ENV_DIR/backend.tfvars"); REGION="${REGION:-us-west-2}"
STATE_BUCKET="lytebuy-tofu-state-${ACCOUNT}-${REGION}"

if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  skip "$STATE_BUCKET already exists"
else
  echo "  creating $STATE_BUCKET (S3 + DynamoDB lock, a few cents a month)"
  ( cd "$ROOT/bootstrap" && tofu init -input=false && tofu apply )
  ok "state backend created"
fi

# --- 2. infrastructure ------------------------------------------------------

bold "2. Infrastructure (VPC, ALB, ECS, RDS, ECR, client CDN)"
if RDS_ENDPOINT=$(tf_out rds_endpoint); then
  skip "already applied"
else
  printf '\n  \033[33mThis creates ~$40/mo of billable resources. Read the plan.\033[0m\n\n'
  "$ROOT/scripts/deploy.sh" "$ENV"
  ok "infrastructure up"
  RDS_ENDPOINT=$(tf_out rds_endpoint) || die \
"the apply finished but rds_endpoint is still empty.
   Something went wrong above - re-read the apply output before continuing."
fi

API_URL=$(tf_out api_url) || die "api_url output is missing after apply"
ok "rds: $RDS_ENDPOINT"
ok "api: $API_URL"

# --- 3. secrets -------------------------------------------------------------

bold "3. Secrets"
[ -f "$SECRETS" ] || die "missing $SECRETS"

if grep -qE '^(DATABASE_URL|ALEMBIC_DATABASE_URL)=.*FILL_ME' "$SECRETS"; then
  # Offer to write them, rather than printing a template with the password left
  # as a variable - inside a file that would be a literal "$TF_VAR_..." string,
  # and the resulting DATABASE_URL would fail in a way that looks like a network
  # problem rather than a typo.
  printf '\n  The database URLs are not filled in yet.\n'
  printf '  Write them now using %s and the saved password? [y/N] ' "$RDS_ENDPOINT"
  if (exec </dev/tty) 2>/dev/null; then read -r yn </dev/tty; else read -r yn; fi
  case "$yn" in
    y|Y)
      PW="$TF_VAR_db_bootstrap_password"
      # In-place edit of just those two lines; everything else is left alone.
      python3 - "$SECRETS" "$RDS_ENDPOINT" "$PW" <<'PYEOF'
import re, sys
path, host, pw = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'^DATABASE_URL=.*$',
           f'DATABASE_URL=postgresql+asyncpg://lytebuy:{pw}@{host}:5432/lytebuy',
           s, count=1, flags=re.M)
s = re.sub(r'^ALEMBIC_DATABASE_URL=.*$',
           f'ALEMBIC_DATABASE_URL=postgresql+psycopg://lytebuy:{pw}@{host}:5432/lytebuy',
           s, count=1, flags=re.M)
open(path, 'w').write(s)
PYEOF
      ok "database urls written"
      ;;
    *)
      pause "Fill the database URLs in
   $SECRETS

     DATABASE_URL=postgresql+asyncpg://lytebuy:PASSWORD@$RDS_ENDPOINT:5432/lytebuy
     ALEMBIC_DATABASE_URL=postgresql+psycopg://lytebuy:PASSWORD@$RDS_ENDPOINT:5432/lytebuy

   PASSWORD is the value in $ROOT/.db-password - paste it literally, a shell
   variable will not expand inside the file."
      ;;
  esac
fi
ok "database urls filled"

# put-secrets exits non-zero when anything is still a placeholder. That is the
# guard doing its job, and at this point only the Stripe webhook secret should
# still be outstanding - so a failure here is expected, not fatal.
if "$ROOT/scripts/put-secrets.sh" "$ENV"; then
  ok "all secrets pushed"
  SECRETS_COMPLETE=1
else
  printf '  \033[33mnote\033[0m some secrets are still placeholders (see above)\n'
  SECRETS_COMPLETE=0
fi

# --- 4. image + run ---------------------------------------------------------

bold "4. Build, push, start"
"$ROOT/scripts/build-push.sh" "$ENV"
"$ROOT/scripts/start.sh" "$ENV"

bold "5. Health"
# The task can be "stable" before the app finishes migrations, so poll rather
# than curl once and declare failure.
for i in $(seq 1 20); do
  BODY=$(curl -fsS --max-time 10 "$API_URL/api/v1/health" 2>/dev/null || true)
  if [ -n "$BODY" ]; then
    echo "  $BODY"
    case "$BODY" in
      *'"database":true'*) ok "healthy" ; break ;;
      *) printf '  \033[33mreachable but not fully healthy\033[0m\n' ; break ;;
    esac
  fi
  printf '  waiting for the api (%d/20)\n' "$i"
  sleep 15
done

if [ -z "${BODY:-}" ]; then
  die "the API never answered. Check the logs:
     aws logs tail /ecs/lytebuy-backend-$ENV --follow --region $REGION

   A task that crash-loops here is almost always a bad DATABASE_URL."
fi

# --- 6. what is left --------------------------------------------------------

if [ "$SECRETS_COMPLETE" = "0" ]; then
  pause "Register the Stripe webhooks now that $API_URL is reachable, and put the
   whsec_ values in $SECRETS

   1. Developers -> Webhooks
      $API_URL/api/v1/payments/webhook
      payment_intent.succeeded, payment_intent.payment_failed, charge.refunded,
      charge.dispute.created, charge.dispute.closed
      -> STRIPE_WEBHOOK_SECRET

   2. CONNECT webhooks (a different part of the dashboard)
      $API_URL/api/v1/payments/webhook/connect
      account.updated
      -> STRIPE_CONNECT_WEBHOOK_SECRET

   Re-running this script will push them and redeploy the task."
fi

bold "Done"
cat <<EOF
  api        $API_URL
  app        $(cd "$ENV_DIR" && tofu output -raw app_url 2>/dev/null || echo '(not applied)')

  next
    ./scripts/deploy-client.sh $ENV      deploy the web client
    ../scripts/aws-status.sh $ENV        what is live
    cd ../lytebuy-scheduler && ./env.sh stop   park it (~\$40/mo -> ~\$21/mo)
EOF
