################################################
#          Бакет для плейбуков Ansible         #
################################################
# Один бакет на три задачи:
#   ansible/   — плейбуки, отсюда их скачивает AWS-ApplyAnsiblePlaybooks
#   корень     — временные файлы плагина amazon.aws.aws_ssm при запуске с машины
#   ssm-logs/  — вывод ассоциаций State Manager: нужен при отладке

#########################
# aws_s3_bucket.ansible #
#########################
resource "aws_s3_bucket" "ansible" {
  bucket_prefix = "${local.name_prefix}-ansible-"

  # Учебный стенд: destroy удалит бакет вместе с содержимым.
  # В production — false и версионирование.
  force_destroy = true

  tags = { Name = "${local.name_prefix}-ansible" }
}

#############################################
# aws_s3_bucket_public_access_block.ansible #
#############################################
resource "aws_s3_bucket_public_access_block" "ansible" {
  bucket = aws_s3_bucket.ansible.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##############################################################
# aws_s3_bucket_server_side_encryption_configuration.ansible #
##############################################################
resource "aws_s3_bucket_server_side_encryption_configuration" "ansible" {
  bucket = aws_s3_bucket.ansible.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

#########################
# aws_s3_object.ansible #
#########################
# Заливка каталога ansible/ в бакет.
# etag = md5 файла: Terraform перезальёт только изменённые файлы.
# inventory.ini исключён: его генерирует outputs.tf, а на инстансах он не нужен —
# документ SSM запускает плейбук с инвентарём "localhost,".
resource "aws_s3_object" "ansible" {
  for_each = toset([
    for f in fileset("${path.module}/../ansible", "**") : f
    if f != "inventory.ini"
  ])

  bucket = aws_s3_bucket.ansible.id
  key    = "ansible/${each.value}"
  source = "${path.module}/../ansible/${each.value}"
  etag   = filemd5("${path.module}/../ansible/${each.value}")
}

################################################
#       Реквизиты базы в Parameter Store       #
################################################
# Пароль генерирует Terraform и сразу кладёт в SecureString. Так он не живёт
# в tfvars, не попадает в инвентарь и не передаётся параметром SSM-документа —
# параметры видны в консоли Systems Manager.
#
# result у random_password хранится в состоянии Terraform открытым
# текстом. Состояние в S3 зашифровано (encrypt = true), доступ по IAM.
#
# special = false — урок недели 3: сгенерированный пароль с символом # сломал
# строку подключения DocumentDB. Здесь пароль попадёт в .env и в local_settings.py —
# без спецсимволов не нужно думать об экранировании. Длина 32 компенсирует
# меньший алфавит.

######################
# random_password.db #
######################
resource "random_password" "db" {
  length  = 32
  special = false
}

#################################
# aws_ssm_parameter.db_password #
#################################
resource "aws_ssm_parameter" "db_password" {
  name        = "${local.ssm_param_prefix}/db_password"
  description = "PostgreSQL password for the application user"
  type        = "SecureString"
  value       = random_password.db.result
}

#############################
# aws_ssm_parameter.db_host #
#############################
resource "aws_ssm_parameter" "db_host" {
  name        = "${local.ssm_param_prefix}/db_host"
  description = "Private IP of the PostgreSQL instance"
  type        = "String"
  value       = aws_instance.db.private_ip
}

#############################
# aws_ssm_parameter.db_name #
#############################
resource "aws_ssm_parameter" "db_name" {
  name        = "${local.ssm_param_prefix}/db_name"
  description = "PostgreSQL database name"
  type        = "String"
  value       = var.db_name
}

#############################
# aws_ssm_parameter.db_user #
#############################
resource "aws_ssm_parameter" "db_user" {
  name        = "${local.ssm_param_prefix}/db_user"
  description = "PostgreSQL application user"
  type        = "String"
  value       = var.db_user
}

##############################
# aws_ssm_parameter.app_repo #
##############################
# URL репозитория — здесь, а не в ExtraVariables: двоеточие в https:// не проходит
# allowedPattern документа.
resource "aws_ssm_parameter" "app_repo" {
  name        = "${local.ssm_param_prefix}/app_repo"
  description = "Git repository the deploy role clones"
  type        = "String"
  value       = var.app_repo
}

######################################
# aws_ssm_parameter.app_subnet_cidrs #
######################################
# Подсети приложения — для pg_hba.conf: роль postgres-setup пускает к базе
# только оттуда. Это второй рубеж после security group, а не замена ей.
# StringList — значения через запятую; в Ansible: value.split(',').
resource "aws_ssm_parameter" "app_subnet_cidrs" {
  name        = "${local.ssm_param_prefix}/app_subnet_cidrs"
  description = "App tier subnets allowed in pg_hba.conf"
  type        = "StringList"
  value       = join(",", var.private_subnet_cidrs)
}

#####################################
# random_password.django_secret_key #
#####################################
# SECRET_KEY Django подписывает сессии и CSRF-токены. Он ОДИН на все инстансы:
# балансировщик раскидывает запросы по кругу, и с разными ключами пользователь,
# вошедший через app-1, на app-2 оказался бы разлогинен.
# По умолчанию в settings.py приложения SECRET_KEY = "---" — в production нельзя.
resource "random_password" "django_secret_key" {
  length  = 50
  special = false
}

#######################################
# aws_ssm_parameter.django_secret_key #
#######################################
resource "aws_ssm_parameter" "django_secret_key" {
  name        = "${local.ssm_param_prefix}/django_secret_key"
  description = "Django SECRET_KEY shared by all app instances"
  type        = "SecureString"
  value       = random_password.django_secret_key.result
}

##################################
# aws_ssm_parameter.alb_dns_name #
##################################
# Адрес балансировщика для SITE_ROOT и ALLOWED_HOSTS. Все настройки приложения
# роль deploy берёт из одного места — Parameter Store.
resource "aws_ssm_parameter" "alb_dns_name" {
  name        = "${local.ssm_param_prefix}/alb_dns_name"
  description = "Public ALB DNS name for SITE_ROOT and ALLOWED_HOSTS"
  type        = "String"
  value       = aws_lb.public.dns_name
}

################################################
#    State Manager: запуск плейбуков через SSM #
################################################
#   AWS-ApplyAnsiblePlaybooks скачивает каталог из S3 на инстанс и выполняет
#     ansible-playbook -i "localhost," -c local -e "<ExtraVariables>" <PlaybookFile>
#   Каждая машина настраивает САМА СЕБЯ. Отсюда hosts: all в плейбуках —
#   групп db и webservers в таком инвентаре нет.
#
# Run Command против State Manager:
#   Run Command   — запустить один раз, здесь и сейчас (aws ssm send-command)
#   State Manager — держать в заданном состоянии, повторять по расписанию
#
# ExtraVariables — строка key=value через пробел. Пароля здесь нет: роль читает
# его из Parameter Store по ssm_param_prefix.
#
# ЛОВУШКА (проверено: aws ssm get-document --name AWS-ApplyAnsiblePlaybooks):
# у ExtraVariables есть allowedPattern, который запрещает пробелы внутри значения
# и символы | : ( ) ; & — даже в кавычках. URL репозитория содержит двоеточие,
# поэтому app_repo сюда не передать: ассоциация упадёт на валидации ещё при apply.
# Поэтому он лежит в Parameter Store рядом с реквизитами базы.

##########
# locals #
##########
locals {
  ansible_source_info = jsonencode({
    # Для S3 документ принимает одно поле path — URL каталога с плейбуками.
    path = "https://s3.${var.region}.amazonaws.com/${aws_s3_bucket.ansible.id}/ansible/"
  })

  ansible_extra_vars = join(" ", [
    "SSM=True",
    "aws_region=${var.region}",
    "ssm_param_prefix=${local.ssm_param_prefix}",
    "app_version=${var.app_version}",
    "deployment_environment=${var.deployment_environment}",
  ])

  # Базовые плейбуки: PostgreSQL на базе, nginx и Python на приложении.
  # Друг от друга не зависят, поэтому идут параллельно.
  ansible_base_associations = {
    db = {
      playbook        = "db.yml"
      role            = "db"
      max_concurrency = "1"
    }
    webservers = {
      playbook        = "webservers.yml"
      role            = "app"
      max_concurrency = "2"
    }
  }

  # Сколько секунд даётся одному плейбуку на одном инстансе. Первый запуск
  # самый долгий: pip ставит Ansible, dnf — пакеты. Не хватит — увеличить.
  ansible_playbook_timeout = 1200

  # Параметры, общие для всех трёх ассоциаций. PlaybookFile добавляется в каждой.
  ansible_parameters = {
    SourceType     = "S3"
    SourceInfo     = local.ansible_source_info
    ExtraVariables = local.ansible_extra_vars
    # True = документ сам ставит Ansible. На AL2023 он идёт по ветке
    # "Amazon Linux release 2" (строка "release 2023" под неё подходит) и делает
    #   sudo yum -y install python3-pip && sudo pip3 install ansible --upgrade
    # Если pip упадёт — поставить "False"
    InstallDependencies = "True"
    Check               = "False"
    Verbose             = "-v"
    TimeoutSeconds      = tostring(local.ansible_playbook_timeout)
  }

  ##############################################
  #   Ревизия плейбука: что считается изменением
  ##############################################
  ansible_dir = "${path.module}/../ansible"

  # Всё из ansible/, кроме инвентаря (генерируется, на серверах не нужен)
  # и документации: правка README не должна перезапускать настройку серверов.
  ansible_files = [
    for f in sort(fileset(local.ansible_dir, "**")) : f
    if f != "inventory.ini" && !endswith(f, ".md")
  ]

  # Какие файлы принадлежат какому плейбуку — по префиксу пути.
  # ПРИ ДОБАВИЛЕНИИ В ПЛЕЙБУК НОВОЙ РОЛИ — ДОПИСАТЬ ЕЁ СЮДА, иначе её правки не
  # перезапустят этот плейбук.
  ansible_playbook_paths = {
    db         = ["db.yml", "roles/postgres-setup/"]
    webservers = ["webservers.yml", "roles/webserver-setup/"]
    deploy     = ["deploy.yml", "roles/deploy/", "library/"]
  }

  # Файлы, которые не принадлежат ни одному плейбуку (ansible.cfg, group_vars/),
  # влияют на все три.
  ansible_owned_paths  = flatten(values(local.ansible_playbook_paths))
  ansible_shared_files = [for f in local.ansible_files : f if !anytrue([for p in local.ansible_owned_paths : startswith(f, p)])]

  # Хеш файлов каждого плейбука. Имя файла входит в хеш: переименование — тоже изменение.
  ansible_files_digest = {
    for name, paths in local.ansible_playbook_paths : name => sha1(join("\n", [
      for f in local.ansible_files : "${f} ${filesha1("${local.ansible_dir}/${f}")}"
      if contains(local.ansible_shared_files, f) || anytrue([for p in paths : startswith(f, p)])
    ]))
  }

  # Полная ревизия = файлы + всё остальное, от чего зависит результат плейбука:
  #   parameters — app_version, ExtraVariables, таймауты;
  #   id инстансов — пересоздали сервер, его нужно настроить заново;
  #   version параметров SSM — растёт при каждой смене значения. Так новый
  #     пароль или новый IP базы перезапускают deploy, который прописывает
  #     реквизиты в конфиг приложения (прямое требование задания).
  ansible_revisions = {
    db = sha1(jsonencode([
      local.ansible_files_digest["db"],
      local.ansible_parameters,
      aws_instance.db.id,
      [for p in [aws_ssm_parameter.db_name, aws_ssm_parameter.db_user, aws_ssm_parameter.db_password, aws_ssm_parameter.app_subnet_cidrs] : p.version],
    ]))
    webservers = sha1(jsonencode([
      local.ansible_files_digest["webservers"],
      local.ansible_parameters,
      aws_instance.app[*].id,
    ]))
    deploy = sha1(jsonencode([
      local.ansible_files_digest["deploy"],
      local.ansible_parameters,
      aws_instance.app[*].id,
      [for p in [aws_ssm_parameter.db_host, aws_ssm_parameter.db_name, aws_ssm_parameter.db_user, aws_ssm_parameter.db_password, aws_ssm_parameter.app_repo, aws_ssm_parameter.django_secret_key, aws_ssm_parameter.alb_dns_name] : p.version],
    ]))
  }
}

###################################
# terraform_data.ansible_revision #
###################################
# Датчик изменений: по одному на плейбук. Сам ничего не создаёт в AWS — хранит
# ревизию в состоянии. Поменялась ревизия — ассоциации ниже пересоздаются
# через replace_triggered_by.
resource "terraform_data" "ansible_revision" {
  for_each = var.enable_ssm_associations ? local.ansible_revisions : {}

  input = each.value
}

################################################
#        Порядок: сначала db и webservers,     #
#                  потом deploy                #
################################################
# Проблема: ассоциация запускает плейбук сразу при создании, а Terraform считает
# ресурс готовым, как только AWS ответил «создано» — это доля секунды, плейбук
# ещё работает. Обычный depends_on поэтому НЕ ждёт окончания плейбука, и deploy
# мог стартовать раньше, чем появятся PostgreSQL и nginx.
#
# Решение: wait_for_success_timeout_seconds. С ним Terraform не считает ассоциацию
# созданной, пока плейбук не отработает со статусом Success на всех целях
# (документация провайдера: не дождался за это время — create падает).
# deploy вынесен в отдельный ресурс с depends_on на базовые и поэтому стартует
# только после их успеха. Упал db.yml или webservers.yml — apply остановится
# с ошибкой, deploy создан не будет. Причину смотреть в ssm-logs/ бакета.
#
# ПОВТОРНЫЕ ЗАПУСКИ. Ожидание работает только при СОЗДАНИИ ассоциации, а при
# обновлении SSM перезапустил бы плейбук без ожидания и без порядка. Поэтому
# ассоциации не обновляются, а ПЕРЕСОЗДАЮТСЯ: lifecycle.replace_triggered_by
# следит за terraform_data.ansible_revision своего плейбука. Результат:
#   поправил роль / сменил app_version / пересоздал сервер → terraform apply →
#   перезапускается только затронутый плейбук, с ожиданием и в правильном
#   порядке. Если затронуты и базовые, и deploy, Terraform сначала удаляет deploy,
#   пересоздаёт базовые, дожидается их Success и только потом создаёт deploy.
# Удаление ассоциации ничего не откатывает на серверах — это лишь запись в SSM,
# а роли идемпотентны, поэтому повторный прогон безопасен.
#
# Цена решения:
#   - в плане это выглядит как "will be replaced due to changes in
#     replace_triggered_by" плюс "terraform_data.ansible_revision[...] will be
#     updated in-place";
#   - история запусков в консоли State Manager начинается заново с каждым
#     пересозданием; полные логи всех прогонов остаются в ssm-logs/ бакета;
#   - apply ждёт реальную настройку серверов, поэтому идёт минутами.
#
# В production запуск деплоя обычно отдают CI (GitHub Actions вызывает
# aws ssm start-associations-once), а Terraform оставляют инфраструктуру.

############################
# aws_ssm_association.base #
############################
resource "aws_ssm_association" "base" {
  for_each = var.enable_ssm_associations ? local.ansible_base_associations : {}

  name             = "AWS-ApplyAnsiblePlaybooks"
  association_name = "${local.name_prefix}-${each.key}"

  # Цель по тегу, а не по ID: ID меняются при пересоздании инстанса.
  # Тег Role одинаков во всех окружениях — если в аккаунте появится второе
  # окружение с тем же Role, ассоциация зацепит и его. Лечится уникальным
  # значением тега, например "${local.name_prefix}-app".
  targets {
    key    = "tag:Role"
    values = [each.value.role]
  }

  parameters = merge(local.ansible_parameters, { PlaybookFile = each.value.playbook })

  max_concurrency = each.value.max_concurrency
  # Остановиться на первой ошибке, а не прокатывать сломанную настройку дальше.
  max_errors = "0"

  # Вывод плейбуков — в бакет. Первое место, куда смотреть, если ассоциация Failed.
  output_location {
    s3_bucket_name = aws_s3_bucket.ansible.id
    s3_key_prefix  = "ssm-logs/${each.key}"
  }

  # Инстансы внутри одной ассоциации идут параллельно (db — один, webservers —
  # max_concurrency 2), поэтому хватает одного таймаута плейбука плюс запас.
  wait_for_success_timeout_seconds = local.ansible_playbook_timeout + 300

  # Без расписания ассоциация выполняется один раз при создании и дальше только
  # по start-associations-once. Для непрерывного приведения к состоянию можно
  # добавить schedule_expression = "rate(30 minutes)".

  # Изменилась ревизия своего плейбука — пересоздать ассоциацию.
  lifecycle {
    replace_triggered_by = [terraform_data.ansible_revision[each.key]]
  }

  # Плейбуки должны лежать в бакете раньше, чем ассоциация попробует их скачать.
  # Это же гарантирует, что при пересоздании в бакете уже новая версия файлов.
  depends_on = [aws_s3_object.ansible, aws_iam_role_policy.ansible]
}

##############################
# aws_ssm_association.deploy #
##############################
resource "aws_ssm_association" "deploy" {
  count = var.enable_ssm_associations ? 1 : 0

  name             = "AWS-ApplyAnsiblePlaybooks"
  association_name = "${local.name_prefix}-deploy"

  targets {
    key    = "tag:Role"
    values = ["app"]
  }

  parameters = merge(local.ansible_parameters, { PlaybookFile = "deploy.yml" })

  # max_concurrency = "1" — решение проблемы миграций на двух инстансах.
  # Через SSM каждый инстанс изолирован и про соседа не знает, run_once в плейбуке
  # не спасёт. State Manager, идущий по одному инстансу за раз, гарантирует:
  # второй увидит, что мигрировать нечего.
  max_concurrency = "1"
  max_errors      = "0"

  output_location {
    s3_bucket_name = aws_s3_bucket.ansible.id
    s3_key_prefix  = "ssm-logs/deploy"
  }

  # Инстансы идут строго по одному, поэтому таймаут умножается на их число.
  # Ждём и здесь: apply закончится зелёным, только если приложение реально
  # задеплоилось, а не просто «ассоциация создана».
  # Для deploy расписание обычно не нужно: миграции и перезапуск каждые полчаса.
  wait_for_success_timeout_seconds = local.ansible_playbook_timeout * var.app_instance_count + 300

  lifecycle {
    replace_triggered_by = [terraform_data.ansible_revision["deploy"]]
  }

  # Главная строка: deploy создаётся только после того, как db.yml и
  # webservers.yml отработали со статусом Success.
  depends_on = [aws_ssm_association.base, aws_s3_object.ansible, aws_iam_role_policy.ansible]
}
