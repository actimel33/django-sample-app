################################################
#                    Выходы                    #
################################################

#######################
# output.alb_dns_name #
#######################
output "alb_dns_name" {
  description = "Адрес приложения. Открывать по http:// — сертификата нет"
  value       = aws_lb.public.dns_name
}

###########################
# output.app_instance_ids #
###########################
output "app_instance_ids" {
  description = "ID инстансов приложения — цели для SSM и хосты инвентаря"
  value       = aws_instance.app[*].id
}

##########################
# output.app_private_ips #
##########################
output "app_private_ips" {
  description = "Приватные адреса инстансов приложения"
  value       = aws_instance.app[*].private_ip
}

#########################
# output.db_instance_id #
#########################
output "db_instance_id" {
  description = "ID инстанса базы"
  value       = aws_instance.db.id
}

########################
# output.db_private_ip #
########################
output "db_private_ip" {
  description = "Приватный адрес базы — пойдёт в DB_HOST"
  value       = aws_instance.db.private_ip
}

########################
# output.nat_public_ip #
########################
output "nat_public_ip" {
  description = "Внешний адрес NAT, с него инстансы ходят в интернет. Пригодится, если GitHub или PyPI начнут ограничивать по IP"
  value       = aws_eip.nat.public_ip
}

#########################
# output.ansible_bucket #
#########################
output "ansible_bucket" {
  description = "Бакет с плейбуками, файлами плагина aws_ssm и логами ассоциаций"
  value       = aws_s3_bucket.ansible.id
}

###########################
# output.ssm_param_prefix #
###########################
output "ssm_param_prefix" {
  description = "Префикс реквизитов базы в Parameter Store"
  value       = local.ssm_param_prefix
}

##############################
# output.ssm_association_ids #
##############################
output "ssm_association_ids" {
  description = "ID ассоциаций State Manager — для запуска вне Terraform, например из CI"
  value = merge(
    { for k, a in aws_ssm_association.base : k => a.association_id },
    { for a in aws_ssm_association.deploy : "deploy" => a.association_id },
  )
}

################################################
#         Инвентарь Ansible из Terraform       #
################################################
# Требование задания: «Producing an output file in inventory format for Ansible».
#
# ИМЯ ХОСТА — ЭТО instance_id, А НЕ IP. Плагин подключения amazon.aws.aws_ssm
# ходит через API Systems Manager и адресует машину идентификатором инстанса.
# Проверено по исходнику плагина: если не задан ansible_aws_ssm_instance_id,
# целью становится хост подключения — ansible_host или имя в инвентаре.
# Если поставить ansible_host=<IP> — плагин попробует открыть сессию к «инстансу»
# 10.60.11.x и упадёт. Приватный IP лежит в отдельной переменной private_ip.
#
# Плагин переехал из community.aws в amazon.aws, поэтому полное имя
# amazon.aws.aws_ssm. Нужны коллекция amazon.aws, boto3 и session-manager-plugin.
#
# Пароля базы в инвентаре НЕТ: файл коммитится. Роли читают пароль из Parameter
# Store, при ручном запуске его можно передать через -e db_password=...
#
# Хосты через join, а не %{for}: внутри директивы <<- не срезает отступ,
# и строки хостов уезжали бы на 4 пробела (проверено рендером на тестовых данных).
#
# Проверка, что инвентарь живой, а не декоративный:
#   cd ../ansible && ansible -i inventory.ini all -m ping

########################
# local_file.inventory #
########################
resource "local_file" "inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"

  content = <<-EOT
    # Сгенерировано Terraform (terraform/outputs.tf). Не править руками —
    # перезапишется при следующем apply.

    [webservers]
    ${join("\n", [for i in aws_instance.app : "${i.id} private_ip=${i.private_ip}"])}

    [db]
    ${aws_instance.db.id} private_ip=${aws_instance.db.private_ip}

    [all:vars]
    ansible_connection=amazon.aws.aws_ssm
    ansible_aws_ssm_region=${var.region}
    ansible_aws_ssm_bucket_name=${aws_s3_bucket.ansible.id}
    ansible_python_interpreter=/usr/bin/python3
    # Те же переменные, что ExtraVariables ассоциаций в ssm.tf: роли одинаково
    # работают и через State Manager, и при запуске с машины.
    aws_region=${var.region}
    app_version=${var.app_version}
    deployment_environment=${var.deployment_environment}
    ssm_param_prefix=${local.ssm_param_prefix}
    db_host=${aws_instance.db.private_ip}
    db_name=${var.db_name}
    db_user=${var.db_user}
  EOT
}
