################################################
#            Роль инстансов для SSM            #
################################################
# Без этой роли инстанс не появится в Systems Manager, и запустить на нём Ansible
# будет нечем. Самая частая причина «инстанс поднялся, а в SSM пусто».
#
# Здесь ДВА разных документа:
#   assume_role_policy — КТО может стать этой ролью (доверие)
#   policy             — ЧТО роль может делать (права)
#
# Роль общая для приложения и базы: обоим нужны одни и те же права.

####################
# aws_iam_role.ec2 #
####################
resource "aws_iam_role" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  description = "Instance role: SSM agent, Ansible playbooks from S3, DB credentials from Parameter Store"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

###########################################
# aws_iam_role_policy_attachment.ssm_core #
###########################################
# Даёт агенту право регистрироваться в SSM и принимать команды.
# Политика шире, чем строго нужно, но это стандарт AWS для SSM.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

################################################
#      Доступ к бакету Ansible и параметрам    #
################################################
# Четыре потребителя, все работают от имени роли инстанса:
#   1. AWS-ApplyAnsiblePlaybooks скачивает плейбуки из S3   → GetObject, ListBucket
#   2. плагин amazon.aws.aws_ssm гоняет файлы через S3      → PutObject, GetObject, DeleteObject
#   3. агент SSM пишет вывод ассоциаций (output_location)   → PutObject
#   4. роли Ansible читают реквизиты базы                   → ssm:GetParameter
#
# Resource везде конкретный — один бакет и один префикс параметров, а не "*".

###############################
# aws_iam_role_policy.ansible #
###############################
resource "aws_iam_role_policy" "ansible" {
  name = "ansible-bucket-and-db-params"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListAnsibleBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.ansible.arn
      },
      {
        Sid      = "ReadWriteAnsibleObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.ansible.arn}/*"
      },
      {
        # SecureString зашифрован AWS managed ключом alias/aws/ssm. Его политика
        # сама разрешает расшифровку принципалам аккаунта через SSM, поэтому
        # отдельный kms:Decrypt не нужен. Если буду использовать KMS —
        # понадобится kms:Decrypt на этот ключ.
        Sid      = "ReadDbParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_param_prefix}/*"
      },
    ]
  })
}

################################
# aws_iam_instance_profile.ec2 #
################################
# Обёртка, которая связывает роль с инстансом — её имя идёт в aws_instance.
resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  role        = aws_iam_role.ec2.name
}
