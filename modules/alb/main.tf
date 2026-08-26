# ============================================================
# ALB Module — AA-CIS
# Application Load Balancer + Target Group + Listeners
# ============================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ── Application Load Balancer ─────────────────────────────────
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  # AA-465 (26/08/2026): the request path is API Gateway -> VPC Link -> NLB -> this ALB -> ECS.
  # AA-465 raised the API Gateway integration timeout 29000ms -> 90000ms, but this ALB's
  # idle_timeout was never set explicitly and sat at the AWS default (60s) the whole time --
  # live-confirmed as the ACTUAL blocker post-apply: a real /write worst-case request still 504'd,
  # now at ~60.7s instead of ~29s, because this ALB cut the connection before API Gateway's new
  # 90s ceiling ever mattered. 100 (seconds) keeps this >= the API Gateway integration timeout so
  # the ALB is never the tighter constraint again -- same margin logic as AA-465's own 90000ms
  # choice, not a coincidence.
  idle_timeout = 100

  dynamic "access_logs" {
    for_each = var.access_logs_bucket != null ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# ── Target Group ──────────────────────────────────────────────
resource "aws_lb_target_group" "api" {
  name        = "${local.name_prefix}-api-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate requires ip, not instance

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${local.name_prefix}-api-tg"
  }
}

# ── HTTP Listener (forward — API Gateway HTTP_PROXY backend) ──
# API Gateway HTTP_PROXY cannot follow 301 redirects, and TLS verification
# would fail on HTTPS because the ALB cert only covers the custom domain, not
# the ELB hostname. Forwarding on HTTP allows API Gateway to reach the backend.
# Auth is enforced by the Lambda Authorizer before any request reaches the ALB.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ── HTTPS Listener ────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
