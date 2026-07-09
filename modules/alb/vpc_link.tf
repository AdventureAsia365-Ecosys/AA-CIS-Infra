# ============================================================
# VPC Link V1 — Network Load Balancer fronting the existing ALB
# AA-272: API Gateway integrations move from connectionType=INTERNET
# (public ALB DNS) to VPC_LINK via this internal NLB. Separate target
# group from aws_lb_target_group.api — that one belongs to the ALB
# (ECS targets on :8000); this one's sole target is the ALB itself.
# ============================================================

resource "aws_security_group" "nlb" {
  name        = "${local.name_prefix}-sg-nlb"
  description = "NLB security group for VPC Link (AA-272)"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from VPC CIDR"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg-nlb"
  }
}

resource "aws_lb" "vpc_link_nlb" {
  name               = "${local.name_prefix}-nlb"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  subnets            = var.private_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${local.name_prefix}-nlb"
  }
}

resource "aws_lb_target_group" "vpc_link_nlb" {
  name        = "${local.name_prefix}-nlb-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "alb"

  health_check {
    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"
  }

  tags = {
    Name = "${local.name_prefix}-nlb-tg"
  }
}

resource "aws_lb_target_group_attachment" "vpc_link_nlb_to_alb" {
  target_group_arn = aws_lb_target_group.vpc_link_nlb.arn
  target_id        = aws_lb.main.arn
  port             = 80
}

resource "aws_lb_listener" "vpc_link_nlb" {
  load_balancer_arn = aws_lb.vpc_link_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vpc_link_nlb.arn
  }
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${local.name_prefix}-vpc-link"
  target_arns = [aws_lb.vpc_link_nlb.arn]

  tags = {
    Name = "${local.name_prefix}-vpc-link"
  }
}
