################################################
#                   Базовые                    #
################################################

####################
# variable.project #
####################
variable "project" {
  description = "Префикс имени всех ресурсов"
  type        = string
  default     = "week4"
}

########################
# variable.environment #
########################
variable "environment" {
  description = "Имя окружения, попадает в имена и теги"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "production"], var.environment)
    error_message = "environment должен быть dev или production."
  }
}

###################
# variable.region #
###################
variable "region" {
  description = "Регион AWS"
  type        = string
  default     = "eu-central-1"
}

################################################
#                     Сеть                     #
################################################

#####################
# variable.vpc_cidr #
#####################
variable "vpc_cidr" {
  description = "CIDR всей VPC. Не пересекается с неделей 3 (10.30, 10.40, 10.50)"
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr должен быть валидным CIDR, например 10.60.0.0/16."
  }
}

################################
# variable.public_subnet_cidrs #
################################
variable "public_subnet_cidrs" {
  description = "Публичные подсети — ровно две, в разных зонах. Здесь только ALB и NAT"
  type        = list(string)
  default     = ["10.60.1.0/24", "10.60.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Нужно ровно две публичные подсети: ALB требует минимум две AZ."
  }
}

#################################
# variable.private_subnet_cidrs #
#################################
variable "private_subnet_cidrs" {
  description = "Приватные подсети — ровно две. Здесь живут все три инстанса"
  type        = list(string)
  default     = ["10.60.11.0/24", "10.60.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Нужно ровно две приватные подсети."
  }
}

################################################
#                   Инстансы                   #
################################################

##########################
# variable.instance_type #
##########################
variable "instance_type" {
  description = "Тип всех трёх инстансов"
  type        = string
  default     = "t3.micro"
}

###############################
# variable.app_instance_count #
###############################
variable "app_instance_count" {
  description = "Число инстансов приложения. Задание требует два"
  type        = number
  default     = 2

  validation {
    condition     = var.app_instance_count >= 1 && var.app_instance_count <= 4
    error_message = "app_instance_count должен быть от 1 до 4."
  }
}

################################################
#              Приложение и база               #
################################################
# Пароля базы среди переменных НЕТ намеренно. Его генерирует random_password
# в ssm.tf и кладёт в Parameter Store как SecureString. Так пароль не живёт
# в tfvars, не попадает в инвентарь и не передаётся параметром SSM-документа,
# где его видно в консоли.

####################
# variable.db_name #
####################
variable "db_name" {
  description = "Имя базы PostgreSQL"
  type        = string
  default     = "hc"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name: строчные латинские буквы, цифры и подчёркивание, не с цифры."
  }
}

####################
# variable.db_user #
####################
variable "db_user" {
  description = "Пользователь PostgreSQL, от которого работает приложение"
  type        = string
  default     = "hc"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]{0,62}$", var.db_user))
    error_message = "db_user: строчные латинские буквы, цифры и подчёркивание, не с цифры."
  }
}

#####################
# variable.app_repo #
#####################
variable "app_repo" {
  description = "Репозиторий приложения, откуда роль deploy тянет код"
  type        = string
  default     = "https://github.com/actimel33/django-sample-app.git"
}

########################
# variable.app_version #
########################
variable "app_version" {
  description = "Ветка, тег или коммит для деплоя. В production — тег, а не ветка"
  type        = string
  # main, а не master: основная ветка форка — main (git branch -a).
  # Уйдёт в ExtraVariables, поэтому никаких пробелов и символов | : ( ) ; &.
  default = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.app_version))
    error_message = "app_version: только буквы, цифры и . _ / - — ограничение ExtraVariables документа SSM."
  }
}

###################################
# variable.deployment_environment #
###################################
variable "deployment_environment" {
  description = "Окружение для Django: production выключает DEBUG"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "production"], var.deployment_environment)
    error_message = "deployment_environment должен быть development или production."
  }
}

################################################
#           Запуск Ansible через SSM           #
################################################

####################################
# variable.enable_ssm_associations #
####################################
variable "enable_ssm_associations" {
  description = <<-EOT
    Создавать ассоциации State Manager, которые запускают плейбуки.
    ПО УМОЛЧАНИЮ false: роли ещё не написаны, а ассоциация запускается сразу
    при создании — и упадёт на пустом плейбуке. Порядок: apply с false
    (инфраструктура), пишешь роли, затем apply -var enable_ssm_associations=true.
  EOT
  type        = bool
  default     = false
}
