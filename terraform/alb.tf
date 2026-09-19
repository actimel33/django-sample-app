################################################
#            Балансировщик нагрузки            #
################################################

#################
# aws_lb.public #
#################
resource "aws_lb" "public" {
  name               = "${local.name_prefix}-public-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = local.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # У ресурса по умолчанию и так false, но у модуля terraform-aws-modules/alb — true.
  # Явно, чтобы destroy не упёрся в защиту, если перейду на модуль.
  enable_deletion_protection = false

  # Отбрасывать запросы с некорректными заголовками — защита от HTTP request smuggling.
  drop_invalid_header_fields = true

  tags = { Name = "${local.name_prefix}-public-alb" }
}

###########################
# aws_lb_target_group.app #
###########################
resource "aws_lb_target_group" "app" {
  # name_prefix до 6 символов; name_prefix вместо name — пересоздание
  # не упрётся в конфликт имён.
  name_prefix = "app-"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  # Сколько ждать завершения запросов при выводе цели. По умолчанию 300 секунд
  deregistration_delay = 30

  health_check {
    enabled = true

    # ВАЖНО: не "/". У healthchecks главная для анонима отдаёт 302 на логин
    # (hc/front/views.py, функция index), и с matcher = "200" цели остались бы
    # unhealthy навсегда.
    #
    # /api/v3/status/ — встроенный эндпоинт статуса (hc/api/views.py, функция
    # status): выполняет SELECT 1 в базе и отвечает "OK" без авторизации. Это
    # «глубокая» проверка — зелёная, только если живы nginx, Django И база.
    # Обратная сторона: упала база — unhealthy сразу все цели. ALB в этом случае
    # шлёт трафик на все цели подряд (fail open), так что сайт не пропадёт
    # молча, а начнёт отдавать 500.
    # Нужна «мелкая» проверка, не зависящая от базы, — поставить "/accounts/login/"
    # (тоже 200 без авторизации, но и она ходит в базу за сессией).
    #
    # Health check приходит с заголовком Host = приватный IP инстанса. Django
    # ответит 400, если этого адреса нет в ALLOWED_HOSTS, — app.env.j2
    # в роли deploy.
    path                = "/api/v3/status/"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-app-tg" }
}

######################################
# aws_lb_target_group_attachment.app #
######################################
# Регистрация целей ручная: инстансы создаются явно, а не группой автомасштабирования.
resource "aws_lb_target_group_attachment" "app" {
  count = var.app_instance_count

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = 80
}

########################
# aws_lb_listener.http #
########################
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ЧЕГО ЖДАТЬ ПОСЛЕ APPLY: цели unhealthy — это нормально, nginx и Django ещё
# не установлены. Healthy они станут после ролей webserver-setup и deploy.
#
# HTTPS нет: сертификата нет, слушатель только на 80.
