################################################
#                Load balancer                 #
################################################
# The only way in. The task's security group accepts traffic from here only.

resource "aws_lb" "main" {
  name_prefix        = "hc-"
  load_balancer_type = "application"
  internal           = false
  subnets            = local.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # Drops malformed headers instead of passing them to the app.
  drop_invalid_header_fields = true

  tags = { Name = "${local.name_prefix}-alb" }
}

################################################
#                 Target group                 #
################################################
# target_type = "ip": a Fargate task registers its network interface, not an instance.

resource "aws_lb_target_group" "app" {
  name_prefix = "hc-"
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # Drain quickly: no point holding connections during a rollout.
  deregistration_delay = 30

  health_check {
    enabled             = true
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

  tags = { Name = "${local.name_prefix}-tg" }
}

################################################
#                   Listener                   #
################################################
# Plain HTTP: no domain, so no ACM certificate.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
