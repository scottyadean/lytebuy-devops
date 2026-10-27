# lytebuy-backend - Deploy Spec Sheet

Step-by-step to deploy the backend to AWS (ECS Fargate + ALB + RDS) and to
stop/start it for cost control. Environment: **dev** (beta). Region:
**us-west-2**. Account: **329104270934**. Public URL: **https://dev-api.lytebuy.com**.

For the why behind the architecture, see `README.md`. This sheet is the runbook.

---

## 0. Prerequisites (once)

- [ ] **AWS CLI** configured for account `329104270934`:
      `aws sts get-caller-identity` shows that account.
- [ ] **OpenTofu >= 1.8** (`tofu version`) and **Docker** (running).
- [ ] Route53 zone `lytebuy.com` and the `*.lytebuy.com` ACM cert exist in the
      account (they do - from lytebuy-blog-service). No action, just confirm.
- [ ] A strong **RDS master password** chosen (used once at DB create):
      ```sh
      export TF_VAR_db_bootstrap_password='<a-strong-password>'
      ```
      Keep it - you'll also put it inside DATABASE_URL in step 4.

> Run every command below from the `lytebuy-devops/` directory.

---

## 1. Create the remote state backend (once per account)

```sh
cd bootstrap
tofu init
tofu apply            # creates the S3 state bucket + DynamoDB lock table
cd ..
```

Idempotent; safe to skip if already done.

---

## 2. Stand up the infrastructure (service starts at 0 tasks)

```sh
scripts/deploy.sh dev
```

Creates the VPC, ECR repo, ALB, RDS, S3 media bucket, IAM, DNS record, log group.
The ECS service is created with **desired-count 0** (no image or DB secrets yet -
nothing tries to run). Prints outputs at the end.

Grab the RDS host for the next step:

```sh
cd environments/dev && tofu output -raw rds_endpoint && cd ../..
```

---

## 3. Build and push the backend image

```sh
scripts/build-push.sh dev
```

Cross-builds `linux/amd64` from `../lytebuy-backend`, pushes to the new ECR repo
as `:latest`. (The "service not scaled up yet" note is expected here.)

---

## 4. Put the secrets in SSM

```sh
cp secrets/backend.dev.env.example secrets/backend.dev.env
# Edit secrets/backend.dev.env - fill in:
#   - SECRET_KEY (python -c "import secrets;print(secrets.token_urlsafe(48))")
#   - DATABASE_URL / ALEMBIC_DATABASE_URL: use the rds_endpoint from step 2 as
#     HOST and TF_VAR_db_bootstrap_password as PASS
#   - FIRST_SUPERUSER_EMAIL / FIRST_SUPERUSER_PASSWORD
#   - Stripe TEST keys (sk_test_ / pk_test_); leave the two whsec_ blank for now
#   - MAPQUEST_API_KEY (the ROTATED key, not the leaked one)
#   - MEDIA_STORAGE_ACCESS_KEY / SECRET_KEY
#   - SENTRY_DSN (optional; leave empty to disable)

scripts/put-secrets.sh dev
```

`secrets/backend.dev.env` is gitignored - never commit it. Values land in SSM as
SecureStrings under `/lytebuy/dev/backend/`.

---

## 5. Start the service

```sh
scripts/start.sh dev
```

Starts RDS, waits until available, scales ECS to 1 task, waits healthy, then
checks `/api/v1/health`. Success prints `status: ok`.

Verify manually:

```sh
curl https://dev-api.lytebuy.com/api/v1/health
# expect: {"status":"ok","database":true,"cache":true,...}
```

Troubleshooting:
- `database:false` -> RDS not reachable / `DATABASE_URL` wrong (re-check step 4).
- `cache:false` -> the redis sidecar/`REDIS_URL` is off (should be
  `redis://127.0.0.1:6379/0` - set by tofu, not by you).
- Task won't stay up -> tail logs:
  `aws logs tail /ecs/lytebuy-backend-dev --follow --region us-west-2`

---

## 6. Wire Stripe test webhooks

In the Stripe **test-mode** dashboard -> Developers -> Webhooks, add two endpoints
pointing at the stable URL:

- `https://dev-api.lytebuy.com/api/v1/payments/webhook`  (main payments)
- `https://dev-api.lytebuy.com/api/v1/payments/webhook/connect`  (Connect payouts)

Also set the Connect return/redirect URL to `https://dev-api.lytebuy.com/...`.

Copy each endpoint's signing secret (`whsec_...`) into `secrets/backend.dev.env`
(`STRIPE_WEBHOOK_SECRET`, `STRIPE_CONNECT_WEBHOOK_SECRET`), then:

```sh
scripts/put-secrets.sh dev
scripts/build-push.sh dev        # force-new-deployment to pick up the new secrets
```

Trigger a test event in Stripe and confirm a **200** in its delivery log. Because
`STRIPE_WEBHOOK_INSECURE=false`, this proves the real signed path end to end.

---

## Daily cost control

```sh
scripts/stop.sh dev     # ECS -> 0 tasks, RDS stopped. URL stays up (503). Data safe.
scripts/start.sh dev    # RDS up -> ECS -> 1 -> waits healthy -> checks /health.
```

- **Running:** ~$40-42/mo.  **Stopped:** ~$21/mo (ALB stays up; that's what keeps
  the URL and Stripe config stable).
- A stopped RDS auto-restarts after **7 days** - run `stop.sh` again if you're
  parked longer.

---

## Redeploy after a code change

```sh
scripts/build-push.sh dev        # rebuild, push, force new deployment
```

Migrations run automatically on container boot (`alembic upgrade head`,
idempotent). No separate migration step for the single-task beta.

---

## Flip to live Stripe (when ready for real money)

No infrastructure change - the URL is stable, so it's a **secrets swap**:

1. Edit `secrets/backend.dev.env`: live keys (`sk_live_`, `pk_live_`, live
   `whsec_`, live `ca_` Connect id).
2. `scripts/put-secrets.sh dev`
3. Register the webhook endpoints again in **live** mode (same URLs).
4. `scripts/build-push.sh dev`  (force-new-deployment).

---

## Direct DB access via the SSM bastion

RDS is private (not publicly accessible; SG admits only the app task). To reach
it from your laptop, turn on the optional SSM bastion (a t4g.nano, ~$3/mo while
on) defined in `modules/backend-service/bastion.tf`. No SSH key or open port -
access is through AWS Session Manager.

1. Enable it (adds the instance + an RDS ingress rule from the bastion):
   ```sh
   scripts/deploy.sh dev -var bastion_enabled=true
   ```
2. Print the ready-made tunnel command (maps localhost:5432 -> RDS:5432):
   ```sh
   cd environments/dev && tofu output -raw db_tunnel_command && cd ../..
   ```
3. Run that command in one terminal (needs the AWS Session Manager plugin:
   `session-manager-plugin`). In another terminal, connect with the same
   credentials that are in `DATABASE_URL`:
   ```sh
   psql "postgresql://lytebuy:<db_bootstrap_password>@localhost:5432/lytebuy"
   ```
4. Turn it back off when done (removes the instance + its RDS rule):
   ```sh
   scripts/deploy.sh dev -var bastion_enabled=false
   ```

Requires the Session Manager plugin locally:
`brew install --cask session-manager-plugin`.

---

## Tear down (only if abandoning the env)

RDS has `deletion_protection` and takes a final snapshot; the state bucket is
`prevent_destroy`. To remove the running stack:

```sh
cd environments/dev
tofu destroy -var-file=backend.tfvars
```

(You must first disable RDS deletion protection or destroy will refuse - a
deliberate guardrail against nuking the money database by accident.)
