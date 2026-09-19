################################################
#              Версии и провайдер              #
################################################
#
# Версии провайдеров проверены по реестру 2026-09-14:
#   hashicorp/aws 6.64.0, hashicorp/local 2.9.1, hashicorp/random 3.9.1
#
# "~>" закрепляет мажорную версию: любые 6.x, но не 7.x. Без этого код однажды
# сломается сам, без единого коммита, — просто выйдет новая мажорная версия.

#############
# terraform #
#############
terraform {
  # 1.10, а не ниже: с этой версии в бэкенде S3 работает use_lockfile —
  # блокировка состояния без отдельной таблицы DynamoDB.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # local — пишет файл инвентаря Ansible (outputs.tf)
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    # random — генерирует пароль базы (ssm.tf), чтобы он не жил в tfvars
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  ################################################
  #               Состояние в S3                 #
  ################################################
  # Бакет общий с неделей 3, ключ свой. Имя бакета не секрет: без учётных данных
  # к нему не подступиться, Block Public Access включён.
  backend "s3" {
    bucket       = "itsyndicate-tfstate-andrew"
    key          = "week4/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

################
# provider.aws #
################
provider "aws" {
  region = var.region

  # Теги на всех ресурсах сразу: по ним ищут забытую инфраструктуру и разбирают счёт.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "andrew"
    }
  }
}

################################################
#                Данные из AWS                 #
################################################

#########################################
# data.aws_availability_zones.available #
#########################################
# Зоны из API, а не строкой "eu-central-1a": конфигурация переедет в другой регион.
data "aws_availability_zones" "available" {
  state = "available"
}

#################################
# data.aws_ssm_parameter.al2023 #
#################################
# Свежая AMI Amazon Linux 2023 из публичного параметра SSM.
# В этой AMI агент SSM предустановлен — задание прямо на это указывает,
# поэтому ставить агента через user_data не нужно.
#
# !!! Значение параметра меняется с выходом каждой новой AMI. Инстансы
# в ec2.tf поэтому игнорируют изменения ami — иначе очередной plan захочет
# пересоздать сервер базы вместе с данными.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

####################################
# data.aws_caller_identity.current #
####################################
data "aws_caller_identity" "current" {}

##########
# locals #
##########
locals {
  name_prefix = "${var.project}-${var.environment}"

  # Ровно две зоны: ALB требует минимум две подсети в разных AZ.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Префикс реквизитов базы в Parameter Store: /week4/dev/db_password ...
  # Его получает Ansible, чтобы прочитать реквизиты.
  ssm_param_prefix = "/${var.project}/${var.environment}"

  # Подсети списком в стабильном порядке: for_each даёт map, а инстансам нужен индекс.
  public_subnet_ids  = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
  private_subnet_ids = [for k in sort(keys(aws_subnet.private)) : aws_subnet.private[k].id]
}
