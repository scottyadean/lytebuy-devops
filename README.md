# lytebuy-devops

> **Deploying the whole system, not just the API?** See
> [`../docs/deployment-map.md`](../docs/deployment-map.md) - every component,
> what depends on what, and the order to ship them in. Run
> `../scripts/aws-status.sh` to see what is actually live right now.
>
> This README covers the **backend** only, which is one of seven components.

Infrastructure-as-code (OpenTofu) for deploying the **lytebuy-backend** API to AWS.

The goal is a **cost-optimized, stoppable** beta: a real HTTPS endpoint that Stripe
test (then live) webhooks can reach, that you can stop and start to save money when
you are not testing.

## Architecture

ECS Fargate (1 task) + Application Load Balancer + RDS Postgres 16 (`db.t4g.micro`)
+ a `redis:7-alpine` sidecar in the same task. Public subnets, no NAT gateway, no
ElastiCache. See `docs` in the plan; the short version:

- The **ALB** gives a stable DNS name that survives scaling the task to 0, so the
  public URL `https://dev-api.lytebuy.com` never changes across stop/start - Stripe
  webhook config never needs to be touched.
- **Redis runs as a task sidecar** because the backend entrypoint blocks on a TCP
  wait for Redis at boot; the sidecar costs ~$0 and holds only cache/rate-limit
  data that is safe to lose on restart.
- **Secrets** live in **SSM Parameter Store** (`/lytebuy/<env>/backend/<NAME>`),
  matching the lytebuy-blog-service convention. Values never enter tofu state.

Aligns with the existing AWS footprint: account `329104270934`, region
`us-west-2`, Route53 zone `lytebuy.com`, the existing `*.lytebuy.com` ACM cert.

## Rough cost (us-west-2)

- Running 24/7: ~$40-42/mo.
- Stopped (task = 0 + RDS stopped): ~$21/mo (the ALB stays up).

## Layout

```
bootstrap/                 one-time: S3 state bucket + DynamoDB lock table
environments/<env>/        per-env tfvars + S3 backend config
modules/backend-service/   the reusable stack (vpc, alb, ecs, rds, s3, iam, dns...)
scripts/                   put-secrets / build-push / deploy / start / stop
secrets/                   local plaintext staging (gitignored) for put-secrets.sh
```

## First-time setup

> **Step-by-step runbook: see [DEPLOY.md](DEPLOY.md).** The summary below is the
> same flow in brief. For the full list of AWS resources this stack creates and
> their costs, see [RESOURCES.md](RESOURCES.md).

```sh
# 0. Prereqs: awscli configured for account 329104270934, opentofu >= 1.8, docker.

# 1. Create the remote-state bucket + lock table (once).
cd bootstrap && tofu init && tofu apply && cd ..

# 2. Stand up the infra with the service scaled to 0 (no image/secrets yet).
scripts/deploy.sh dev            # applies with desired_count from tfvars (start at 0)

# 3. Build and push the backend image to the new ECR repo.
scripts/build-push.sh dev latest

# 4. Fill secrets/backend.dev.env (copy from the .example), then push to SSM.
#    DATABASE_URL / ALEMBIC_DATABASE_URL use the rds_endpoint output from step 2.
scripts/put-secrets.sh dev

# 5. Scale the service to 1 (set desired_count=1 in environments/dev/backend.tfvars).
scripts/deploy.sh dev

# 6. Verify.
curl https://dev-api.lytebuy.com/api/v1/health   # expect status: ok
```

## Daily cost control

```sh
scripts/stop.sh dev     # task -> 0, RDS stopped. URL stays up (503). Data survives.
scripts/start.sh dev    # RDS up, task -> 1, waits for healthy, checks /health.
```

## Notes

- Migrations run on container boot (`alembic upgrade head`, idempotent). Safe for
  the single-task beta. Split into a one-off task before running more than one task.
- Test -> live Stripe is a **secrets swap** (update SSM params, force new
  deployment). No infrastructure change - the URL is stable.
- `prod` (`api.lytebuy.com`, larger sizes) is a later copy of the same module.
