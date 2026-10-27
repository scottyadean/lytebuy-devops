#!/usr/bin/env bash
#
# Build and deploy the Expo web client to dev-app.lytebuy.com.
#
#   ./scripts/deploy-client.sh [env]      (env defaults to dev)
#
# THE THING THAT MAKES THIS DANGEROUS: EXPO_PUBLIC_* values are INLINED INTO THE
# BUNDLE at export time, so whatever the build reads is what every user gets. A
# stale LAN IP or a test Stripe key does not fail loudly - it produces a build
# that is quietly broken or quietly wrong.
#
# The env now reaches the build through `npm run build:web:<env>` (dotenv-cli ->
# process environment) rather than by copying a file into place. Expo loads
# .env.local and .env.development in PREFERENCE to .env, both gitignored, so the
# copy approach could be silently overridden by a developer's local file.
#
# So this script refuses to deploy a build whose API URL is not the environment's
# real API. That check is the whole reason it exists rather than being two commands
# in a README.

set -euo pipefail

ENV="${1:-dev}"
PROFILE="${AWS_PROFILE:-lytebuy}"
REGION="${AWS_REGION:-us-west-2}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLIENT="$ROOT/lytebuy-client"
ENVDIR="$ROOT/lytebuy-devops/environments/$ENV"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

# --- where does this env actually live? ------------------------------------
# Read from tofu outputs rather than hardcoded, so the script cannot drift from
# the infrastructure.
say "Reading $ENV outputs from tofu"
BUCKET=$(tofu -chdir="$ENVDIR" output -raw client_bucket 2>/dev/null) \
  || die "no client_bucket output - has 'tofu apply' been run for $ENV?"
DIST_ID=$(tofu -chdir="$ENVDIR" output -raw client_distribution_id)
APP_URL=$(tofu -chdir="$ENVDIR" output -raw app_url)
API_URL=$(tofu -chdir="$ENVDIR" output -raw api_url)

echo "    bucket:       $BUCKET"
echo "    distribution: $DIST_ID"
echo "    app:          $APP_URL"
echo "    api:          $API_URL"

# --- pick the right env file ------------------------------------------------
# One file per environment, chosen here and passed to the build as process env.
ENV_FILE="$CLIENT/.env.$ENV"
say "Using $ENV_FILE"
[ -f "$ENV_FILE" ] || die "no $ENV_FILE - create it from .env.dev"
# NO LONGER copied over .env. Expo loads .env.local and .env.development in
# PREFERENCE to .env, both gitignored, so a developer's local file could shadow
# the one we just put in place - and did: a prod export once baked
# http://localhost:8000 into the bundle because .env.local named it.
# `npm run build:web:$ENV` passes the file through dotenv-cli instead, which
# lands in the PROCESS environment and beats every file Expo reads.

CONFIGURED_API=$(grep -E '^EXPO_PUBLIC_API_URL=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
[ -n "$CONFIGURED_API" ] || die "EXPO_PUBLIC_API_URL is not set in $ENV_FILE"

if [ "$CONFIGURED_API" != "$API_URL" ]; then
  die "EXPO_PUBLIC_API_URL is '$CONFIGURED_API' but $ENV's API is '$API_URL'.
     Fix $ENV_FILE and re-run."
fi

# A live Stripe key in a dev build (or a test key in prod) is the other way this
# goes wrong silently. Warn rather than block: only you know which is intended.
STRIPE_KEY=$(grep -E '^EXPO_PUBLIC_STRIPE_PUBLISHABLE_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
case "$ENV:$STRIPE_KEY" in
  dev:pk_live_*)  printf '\033[33mwarning:\033[0m a LIVE Stripe key in a dev build\n' ;;
  prod:pk_test_*) printf '\033[33mwarning:\033[0m a TEST Stripe key in a prod build\n' ;;
esac

# --- build ------------------------------------------------------------------
say "Building the web bundle"
# --clear: Metro caches EXPO_PUBLIC_* values, so a rebuild after changing .env
# can emit a byte-identical bundle with the OLD url still inlined. That is not
# hypothetical - it shipped a LAN IP to dev-app and looked like a CORS error.
( cd "$CLIENT" && rm -rf dist .expo node_modules/.cache && npm run "build:web:$ENV" )
[ -d "$CLIENT/dist" ] || die "build produced no dist/"

# VERIFY THE ARTIFACT, not the source. Checking .env only proves what we asked
# for; this proves what is actually in the file users download.
say "Verifying the built bundle"
if ! grep -rqF "$API_URL" "$CLIENT/dist/_expo/static/js/web/"*.js 2>/dev/null; then
  die "the built bundle does not contain '$API_URL'.
     Something overrode the env file - check for a stale cache or a competing
     .env.local, and do NOT deploy this build."
fi
# `|| true` because FINDING NOTHING IS THE GOOD OUTCOME here, but grep signals it
# by exiting 1 - and under `set -euo pipefail` that non-zero exit killed this
# script silently, right after printing "Verifying the built bundle". The deploy
# looked like it hung at verification when in fact the bundle was clean and the
# guard itself was the only thing failing.
WRONG=$(grep -rhoE 'https?://(192\.168|10\.|localhost|127\.0\.0\.1)[^"]*' \
  "$CLIENT/dist/_expo/static/js/web/"*.js 2>/dev/null | sort -u | head -3 || true)
[ -z "$WRONG" ] || die "the built bundle still references a local host: $WRONG"
echo "    bundle points at $API_URL"

# --- upload -----------------------------------------------------------------
# TWO PASSES, on purpose. Hashed assets are immutable and get a one-year cache;
# index.html must NOT be, or a browser keeps serving the old app long after a
# deploy and you cannot tell why.
say "Uploading hashed assets (long cache)"
aws s3 sync "$CLIENT/dist" "s3://$BUCKET" \
  --profile "$PROFILE" --region "$REGION" \
  --delete \
  --exclude "index.html" \
  --cache-control "public,max-age=31536000,immutable"

say "Uploading index.html (no cache)"
aws s3 cp "$CLIENT/dist/index.html" "s3://$BUCKET/index.html" \
  --profile "$PROFILE" --region "$REGION" \
  --cache-control "no-cache,no-store,must-revalidate" \
  --content-type "text/html"

# --- invalidate -------------------------------------------------------------
say "Invalidating CloudFront"
INVALIDATION=$(aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" --paths "/*" \
  --profile "$PROFILE" \
  --query 'Invalidation.Id' --output text)
echo "    invalidation: $INVALIDATION (takes a minute or two to complete)"

say "Done -> $APP_URL"
