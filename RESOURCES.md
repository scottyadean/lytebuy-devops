# lytebuy-devops - AWS Resources

Everything the `dev` (beta) stack creates or uses, by concern. Region
**us-west-2**, account **329104270934**. `<name>` = `lytebuy-backend-dev`.

Cost column: **~$/mo running** (task up + RDS up). When **stopped**
(`scripts/stop.sh dev`), compute drops to $0 and RDS to storage-only; the ALB and
storage remain (see totals at the bottom).

---

## Created by tofu

### Networking (VPC) - `modules/backend-service/vpc.tf`, `security_groups.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| VPC | `aws_vpc.this` | `10.20.0.0/16`, DNS on | $0 |
| Internet Gateway | `aws_internet_gateway.this` | egress for the public subnets | $0 |
| Public subnets (x2) | `aws_subnet.public` | one per AZ; `map_public_ip_on_launch` | $0 |
| Route table + assoc | `aws_route_table.public`, `aws_route_table_association.public` | default route -> IGW | $0 |
| ALB security group | `aws_security_group.alb` | 443/80 from the world | $0 |
| Task security group | `aws_security_group.task` | 8000 from the ALB SG only | $0 |
| DB security group | `aws_security_group.db` | 5432 from the task SG only | $0 |

> No NAT gateway (deliberate - saves ~$32/mo). The task gets a public IP for
> egress; nothing inbound reaches it except via the ALB.

### Load balancer (ingress / TLS) - `alb.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| Application Load Balancer | `aws_lb.this` | the **stable** public front door | ~$17 |
| Target group | `aws_lb_target_group.backend` | port 8000, health `/api/v1/health` = 200 | $0 |
| HTTPS listener | `aws_lb_listener.https` | 443, TLS via the `*.lytebuy.com` cert | $0 |
| HTTP redirect listener | `aws_lb_listener.http_redirect` | 80 -> 443 | $0 |

> The ALB stays up when stopped - that's what keeps the URL and Stripe webhook
> config stable.

### Compute (ECS Fargate) - `ecs.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| ECS cluster | `aws_ecs_cluster.this` | | $0 |
| Task definition | `aws_ecs_task_definition.backend` | 0.25 vCPU / 0.5 GB; **backend + redis sidecar**; x86_64 | $0 |
| ECS service | `aws_ecs_service.backend` | desired-count = the stop/start knob (0 <-> 1) | ~$9 |

### Container registry - `ecr.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| ECR repository | `aws_ecr_repository.backend` | `lytebuy-backend`, scan-on-push | ~$1 |
| ECR lifecycle policy | `aws_ecr_lifecycle_policy.backend` | keep last 10 images | $0 |

### Database - `rds.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| DB subnet group | `aws_db_subnet_group.this` | | $0 |
| RDS instance | `aws_db_instance.this` | Postgres 16, `db.t4g.micro`, 20 GB gp3, single-AZ, 7-day backups, deletion protection | ~$13 (running) / ~$2 (stopped) |

### Object storage (product media) - `s3.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| Media bucket | `aws_s3_bucket.media` | `lytebuy-media-dev`, private | ~pennies |
| Public-access block | `aws_s3_bucket_public_access_block.media` | blocks all public access | $0 |
| Encryption config | `aws_s3_bucket_server_side_encryption_configuration.media` | AES256 | $0 |
| CORS config | `aws_s3_bucket_cors_configuration.media` | GET/PUT/HEAD from allowed origins | $0 |

### IAM - `iam.tf`

| Resource | tofu address | Notes |
|---|---|---|
| Task execution role | `aws_iam_role.execution` | ECS launch: ECR pull, logs, read SSM secrets |
| - managed policy attach | `aws_iam_role_policy_attachment.execution_managed` | `AmazonECSTaskExecutionRolePolicy` |
| - SSM/KMS inline policy | `aws_iam_role_policy.exec_ssm` | `ssm:GetParameters` + `kms:Decrypt` on the backend params |
| Task role | `aws_iam_role.task` | runtime app perms |
| - media inline policy | `aws_iam_role_policy.task_media` | read/write the media bucket |

### DNS - `dns.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| A alias record | `aws_route53_record.api` | `dev-api.lytebuy.com` -> ALB | ~pennies |
| AAAA alias record | `aws_route53_record.api_aaaa` | IPv6 -> ALB | $0 |

### Logs - `logs.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| CloudWatch log group | `aws_cloudwatch_log_group.backend` | `/ecs/lytebuy-backend-dev`, 7-day retention | ~$1-2 |

### Remote state (bootstrap, once per account) - `bootstrap/main.tf`

| Resource | tofu address | Notes | ~$/mo |
|---|---|---|---|
| State S3 bucket | `aws_s3_bucket.state` | `lytebuy-tofu-state-329104270934-us-west-2`, versioned, KMS, `prevent_destroy` | ~pennies |
| - versioning / encryption / PAB | `aws_s3_bucket_versioning.state`, `..._server_side_encryption_configuration.state`, `..._public_access_block.state` | | $0 |
| DynamoDB lock table | `aws_dynamodb_table.lock` | `lytebuy-tofu-locks`, pay-per-request | ~pennies |

---

## Used by tofu but NOT created here (existing / data sources)

These are looked up, not managed - they come from `lytebuy-blog-service` or AWS.

| Thing | data source | Where it comes from |
|---|---|---|
| Route53 hosted zone | `data.aws_route53_zone.root` | existing `lytebuy.com` zone |
| Wildcard TLS cert | `data.aws_acm_certificate.wildcard` | existing `*.lytebuy.com` ACM cert |
| Availability zones | `data.aws_availability_zones.available` | AWS (picks 2) |

---

## Created outside tofu (by scripts)

| Thing | Created by | Notes |
|---|---|---|
| SSM SecureString params | `scripts/put-secrets.sh` | `/lytebuy/dev/backend/<NAME>` (SECRET_KEY, DATABASE_URL, Stripe keys, etc.). Free tier. Referenced by the task def via ARN; values never enter tofu state. |
| Backend container image | `scripts/build-push.sh` | pushed to the ECR repo above as `:latest` |

---

## Rough monthly total (us-west-2)

| State | ~$/mo | What's on |
|---|---|---|
| **Running** (task + RDS up) | **~$40-42** | Fargate ~$9 + RDS ~$13 + ALB ~$17 + ECR/logs/DNS ~$3 |
| **Stopped** (`stop.sh dev`) | **~$21** | ALB ~$17 + RDS storage ~$2 + ECR/logs/DNS ~$2 |

SSM Standard params, the state bucket, the lock table, Route53 records, and the
media bucket are all effectively free at beta scale.
