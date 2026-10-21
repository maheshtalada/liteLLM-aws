# Created only when acm_certificate_arn is set: HTTPS ALB in front of the instance.

resource "aws_security_group" "alb" {
  count       = local.https_enabled ? 1 : 0
  name        = "${var.name}-alb"
  description = "LiteLLM ALB"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  count                      = local.https_enabled ? 1 : 0
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb[0].id]
  subnets                    = local.alb_subnet_ids
  idle_timeout               = 300 # long streaming / agentic completions
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "litellm" {
  count       = local.https_enabled ? 1 : 0
  name        = "${var.name}-tg"
  port        = 4000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.selected.id

  health_check {
    path                = "/health/liveliness"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "litellm" {
  count            = local.https_enabled ? 1 : 0
  target_group_arn = aws_lb_target_group.litellm[0].arn
  target_id        = aws_instance.litellm.id
  port             = 4000
}

resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm[0].arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
