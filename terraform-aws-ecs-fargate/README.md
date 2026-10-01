# terraform-aws-ecs-fargate

Infrastructure for the containerized Django application: ECS Fargate behind an
Application Load Balancer, PostgreSQL in RDS, image in ECR.

## Layout

| File | Contents |
|---|---|
| `providers.tf` | provider versions, region, default tags |
| `variables.tf` | deployment parameters |
| `vpc.tf` | network, subnets, security groups |
| `db.tf` | PostgreSQL instance and the application secret |
| `ecs.tf` | registry, cluster, task definition, service, IAM roles |
| `alb.tf` | load balancer, target group, listener |
| `outputs.tf` | addresses, identifiers and ready-to-run build commands |

## How to run it

The registry has to exist before the image can be pushed, and the service needs
the image before it can start a task. That makes the first deployment a two-step
one:

```bash
terraform init && terraform apply -target=aws_ecr_repository.app
```

Then build and push. `terraform output push_commands` prints the exact sequence
with the registry address already filled in: ECR login, build, push.

```bash
terraform apply
```

By now the image exists, so the first task starts cleanly.

After a code change Terraform is not involved at all — rebuild, push with the
same tag and tell ECS to roll out:

```bash
aws ecs update-service --cluster hc-ecs-dev --service hc-ecs-dev --force-new-deployment --region eu-central-1
```

## Decisions

**Fargate over EC2.** The assignment only asks for an ECS cluster. Fargate removes
the servers from the picture entirely: no instances to patch, no agent to run, and
billing follows the task's lifetime.

**Tasks and database in private subnets.** Public subnets hold the load balancer
and the NAT gateway, nothing else. The task has no public address, so it cannot
be reached from the internet even if a security group is widened later — there is
no route in. Outbound traffic to ECR, CloudWatch Logs and Secrets Manager goes
through the NAT gateway.

**One NAT gateway, not one per zone.** A per-zone layout survives the loss of an
availability zone; this one is a single point of failure for outbound traffic.
The trade is deliberate — a second gateway doubles the cost for a stand that
serves no real users.

**The database password is never written down.** `manage_master_user_password`
makes RDS generate it, store it in Secrets Manager and rotate it. Terraform only
ever sees an ARN, so the password is absent from the code, the variables and the
state file.

**`SECRET_KEY` is the exception, and it is deliberate.** Django needs a stable
key, so Terraform generates one and stores it in Secrets Manager — which means
the value does pass through the state file. That is why the state here is local
and never committed. In production such a secret is created outside Terraform.

**Two IAM roles, not one.** The execution role belongs to the ECS platform: it
pulls the image, reads secrets and writes logs, all before the container starts.
The task role belongs to the application itself. This application needs no AWS
access at all, so its role is created empty — but created explicitly, so the
container inherits nothing by accident.

**Container health check duplicated in the task definition.** ECS ignores the
`HEALTHCHECK` instruction baked into the image; it only reads the `healthCheck`
field in the container definition. Without it the platform knows the process is
alive and nothing more — a hung application with an open port would never be
replaced.

**Read-only root filesystem.** The container cannot write to its own filesystem;
a volume is mounted at `/tmp` instead. One consequence is worth knowing: that
volume belongs to root, while the application runs as uid 10001, so the image
points `TMPDIR` at `/dev/shm`, which Fargate mounts as a world-writable tmpfs.

## Known gaps

| Gap | Why | What production does |
|---|---|---|
| HTTP listener, no TLS | no domain, and without a domain there is no ACM certificate | domain in Route 53, HTTPS listener with TLS 1.2+, port 80 redirecting |
| Mutable image tags | the image is rebuilt dozens of times a day on a lab stand | immutable tags, one per commit hash |
| Migrations run at container start | a single copy of the application, so no race is possible | a separate one-off ECS task before the rollout |
| State stored locally | the stand lives for days, not months | S3 backend with locking |
| No VPC flow logs | log storage is billed and this stand handles no real data | enabled, with retention set by policy |

Scanner findings that are accepted on purpose are listed in `.trivyignore.yaml`,
each with a reason and an expiry date. Three findings were fixed in code instead:
IAM database authentication, Performance Insights and a seven-day backup window.

## Cost

Roughly $3.00 a day: the NAT gateway (about $1.25 and the largest single item),
the load balancer, one Fargate task, and a `db.t4g.micro` instance with its
storage.

```bash
terraform destroy
```
