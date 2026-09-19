################################################
#               Security groups                #
################################################
#   интернет ──80──> ALB ──80──> приложение ──5432──> база
#
# Каждое правило ссылается на ДРУГУЮ группу, а не на диапазон адресов:
# новый инстанс попадает под правило автоматически.
#
# Правила — отдельными ресурсами aws_vpc_security_group_*_rule, а НЕ inline-блоками:
# смешивать нельзя, inline-блоки при следующем apply удаляют «чужие» правила.
# name_prefix + create_before_destroy: имена групп уникальны в VPC.
# Префикс sg- зарезервирован AWS.

##########################
# aws_security_group.alb #
##########################
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Public ALB: HTTP from the internet"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

################################################
# aws_vpc_security_group_ingress_rule.alb_http #
################################################
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

#################################################
# aws_vpc_security_group_egress_rule.alb_to_app #
#################################################
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to the app tier"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

##########################
# aws_security_group.app #
##########################
resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "App tier: HTTP from the ALB only"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-app-sg" }
}

####################################################
# aws_vpc_security_group_ingress_rule.app_from_alb #
####################################################
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from the public ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

################################################
# aws_vpc_security_group_egress_rule.app_https #
################################################
# Наружу только HTTPS: репозитории dnf в AL2023, pip, GitHub, SSM, S3 — всё по https.
# Порт 80 не открыт намеренно. Если какой-то пакет полезет на 80 и повиснет —
# вот где искать.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS: dnf, pip, GitHub, SSM, S3"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

################################################
# aws_vpc_security_group_egress_rule.app_to_db #
################################################
resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the db tier"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

#########################
# aws_security_group.db #
#########################
resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-db-"
  description = "DB tier: PostgreSQL from the app tier only"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-db-sg" }
}

###################################################
# aws_vpc_security_group_ingress_rule.db_from_app #
###################################################
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the app tier only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

###############################################
# aws_vpc_security_group_egress_rule.db_https #
###############################################
resource "aws_vpc_security_group_egress_rule" "db_https" {
  security_group_id = aws_security_group.db.id
  description       = "HTTPS: dnf, pip, SSM, S3"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

################################################
#             Инстансы приложения              #
################################################
# user_data НЕТ намеренно: всю настройку делает Ansible.
# Агент SSM в AL2023 предустановлен.

####################
# aws_instance.app #
####################
resource "aws_instance" "app" {
  count = var.app_instance_count

  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  # Раскидываем по зонам: нулевой инстанс в первую приватную подсеть, первый — во вторую.
  subnet_id              = local.private_subnet_ids[count.index % length(local.private_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # IMDSv2 обязателен: без токена метаданные не отдаются. Закрывает атаки,
  # где SSRF в приложении читает учётные данные роли через 169.254.169.254.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
  }

  # Параметр SSM с AMI меняется с каждым новым образом. Без этой строки очередной
  # plan захочет пересоздать инстанс. Обновление образа — осознанное действие,
  # а не побочный эффект plan.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-app-${count.index + 1}"
    # По этому тегу ассоциации SSM находят цели: ID при пересоздании меняются, теги нет.
    Role = "app"
  }
}

################################################
#                 Инстанс базы                 #
################################################
# EC2, а не RDS: задание требует поставить PostgreSQL ролью postgres-setup.
# В production здесь была бы RDS.

###################
# aws_instance.db #
###################
resource "aws_instance" "db" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  subnet_id              = local.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
  }

  # Для базы ignore_changes = [ami] особенно важен: пересоздание инстанса
  # уничтожит данные — отдельного диска под PostgreSQL здесь нет.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-db"
    Role = "db"
  }
}
