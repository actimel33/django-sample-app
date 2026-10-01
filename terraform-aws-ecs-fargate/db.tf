################################################
#                   Database                   #
################################################
# PostgreSQL for Django. RDS creates and stores the master password in Secrets Manager.

resource "aws_db_subnet_group" "main" {
  name_prefix = "${local.name_prefix}-db-"
  subnet_ids  = local.private_subnet_ids

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

resource "aws_db_instance" "main" {
  identifier_prefix = "${local.name_prefix}-"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_encrypted = true

  db_name  = var.db_name
  username = "hcadmin"

  # No password anywhere, only the secret ARN.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  # Private subnets, no public address, security group accepts the task only.
  publicly_accessible = false


  backup_retention_period    = 7
  auto_minor_version_upgrade = true

  # Short-lived IAM tokens; the secret stays as fallback.
  iam_database_authentication_enabled = true

  # Query-level metrics.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${local.name_prefix}-postgres" }
}

################################################
#            Application SECRET_KEY            #
################################################
# Django needs a stable key. Unlike the database password this value passes
# through Terraform and stays in the state file, so the state is local.

resource "random_password" "secret_key" {
  length  = 50
  special = true
  # Quotes and backslashes break .env and CLI syntax.
  override_special = "!@#%^&*()-_=+[]{}<>?"
}

resource "aws_secretsmanager_secret" "app" {
  name_prefix             = "${local.name_prefix}-app-"
  description             = "Django SECRET_KEY"
  recovery_window_in_days = 0

  tags = { Name = "${local.name_prefix}-app-secret" }
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ SECRET_KEY = random_password.secret_key.result })
}
