################################################
#                 Image registry               #
################################################

resource "aws_ecr_repository" "app" {
  name                 = local.name_prefix
  image_tag_mutability = "MUTABLE"

  # Scan on push: findings appear without a separate pipeline step.
  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true

  tags = { Name = "${local.name_prefix}-ecr" }
}

# Images pile up and registry storage is billed.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

################################################
#                     Logs                     #
################################################
# Application errors land here, not in the service events.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name_prefix}-logs" }
}

################################################
#                     Roles                    #
################################################
# Two roles, easy to confuse.
#
# Execution role belongs to the ECS platform: pulls the image, reads secrets,
# writes logs — all before the container starts.
#
# Task role belongs to the application. This one needs no AWS access, so it is
# created empty but created explicitly.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${local.name_prefix}-exec-"
  description        = "ECS platform: pull image, read secrets, write logs"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = { Name = "${local.name_prefix}-exec-role" }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy grants no secret access; these two are granted explicitly.
resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_db_instance.main.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.app.arn,
    ]
  }
}

resource "aws_iam_role" "task" {
  name_prefix        = "${local.name_prefix}-task-"
  description        = "The application itself: no AWS access needed"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = { Name = "${local.name_prefix}-task-role" }
}

################################################
#                    Cluster                   #
################################################

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = "${local.name_prefix}-cluster" }
}

################################################
#                Task definition               #
################################################
# Fargate requires awsvpc: the task gets its own interface, address and group.

resource "aws_ecs_task_definition" "app" {
  family                   = local.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Read-only root with a scratch volume: nothing can be written into the container.
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.app_port
      protocol      = "tcp"
    }]

    readonlyRootFilesystem = true

    # ECS ignores the image's HEALTHCHECK and reads this field only. Without it
    # a hung application holding its port would never be replaced.
    healthCheck = {
      command = [
        "CMD-SHELL",
        "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.app_port}/api/v3/status/', timeout=3).status == 200 else 1)\""
      ]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]

    # Non-secret settings.
    environment = [
      { name = "DB", value = "postgres" },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_PORT", value = tostring(aws_db_instance.main.port) },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_USER", value = aws_db_instance.main.username },
      { name = "DB_SSLMODE", value = "require" },
      { name = "DEBUG", value = "False" },
      { name = "ALLOWED_HOSTS", value = "*" },
      { name = "SITE_ROOT", value = "http://${aws_lb.main.dns_name}" },
    ]

    # ECS resolves these before start, so values appear neither in the task
    # definition nor in the Terraform state. The ":key::" suffix picks one JSON field.
    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
      },
      {
        name      = "SECRET_KEY"
        valueFrom = "${aws_secretsmanager_secret.app.arn}:SECRET_KEY::"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])

  tags = { Name = "${local.name_prefix}-task" }
}

################################################
#                    Service                   #
################################################
# Keeps the desired number of copies running and replaces failed ones.

resource "aws_ecs_service" "app" {
  name            = local.name_prefix
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.task.id]

    # No public address at all. Outbound traffic to ECR, CloudWatch Logs and
    # Secrets Manager goes through the NAT gateway; inbound traffic arrives
    # only from the load balancer, which lives in the public subnets.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_port
  }

  # Django needs time for migrations; without this the ALB kills it first.
  health_check_grace_period_seconds = 120

  # Without the NAT gateway in place the first task cannot pull its image.
  depends_on = [aws_lb_listener.http, aws_nat_gateway.main]

  tags = { Name = "${local.name_prefix}-service" }
}
