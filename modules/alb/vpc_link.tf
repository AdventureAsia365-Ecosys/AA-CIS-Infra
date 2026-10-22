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

  # AA-931 (CRM-03): CloudFront VPC origin -> this NLB. VPC-origin traffic arrives from CloudFront's
  # origin-facing addresses through a service-managed ENI in the private subnets (AWS guide "Restrict
  # access with VPC origins", option 1: the managed prefix list). The NLB is internal, so only a VPC
  # origin can deliver traffic from those addresses here.
  dynamic "ingress" {
    for_each = var.cloudfront_vpc_origin_enabled ? [1] : []
    content {
      description     = "HTTP from CloudFront VPC origins (AA-931)"
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sg-nlb"
  })
}

resource "aws_lb" "vpc_link_nlb" {
  name               = "${local.name_prefix}-nlb"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  subnets            = var.private_subnet_ids

  enable_deletion_protection = false

  # AA-272 cutover attempt #3: the SG's ingress rule below only allows
  # 10.2.0.0/16 (this VPC's own CIDR, correct for the NLB's own health
  # checks to the ALB). Real client traffic from the API Gateway VPC Link
  # arrives via AWS PrivateLink, not from this VPC — AWS docs confirm that
  # source range is intentionally undocumented/unstable ("you do not know
  # the IP address range... making traditional IP-based security group
  # rules impractical"), so it can never be safely allow-listed by CIDR.
  # This flag is AWS's purpose-built alternative: skip SG evaluation only
  # for PrivateLink-sourced traffic, leaving the 10.2.0.0/16 rule fully
  # enforced for everything else.
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nlb"
  })
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

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nlb-tg"
  })
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

  tags = var.tags
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${local.name_prefix}-vpc-link"
  target_arns = [aws_lb.vpc_link_nlb.arn]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-vpc-link"
  })
}

# AA-931 (CRM-03) — CloudFront VPC origin support, gated by var.cloudfront_vpc_origin_enabled.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.cloudfront_vpc_origin_enabled ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# An NLB with an `alb` target group always preserves the client IP towards the ALB (ELB guide, "Edit
# target group attributes"), so CloudFront VPC-origin traffic reaches the ALB with a CloudFront source
# address that the ALB group's VPC-CIDR rule does not match. AWS's rule for targets of an NLB that has a
# security group: reference the NLB's group. This second ALB group does exactly that and nothing else.
# The ALB group itself is deliberately NOT opened to the CloudFront prefix list: the ALB is still
# internet-facing, so that would let any third-party CloudFront distribution call it and skip API
# Gateway. API Gateway VPC-link traffic is unaffected (PrivateLink is always source-NATed to the NLB).
resource "aws_security_group" "alb_from_nlb" {
  count = var.cloudfront_vpc_origin_enabled ? 1 : 0

  name        = "${local.name_prefix}-sg-alb-from-nlb"
  description = "ALB: HTTP from the VPC-link NLB group (CloudFront VPC origin, AA-931)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from the NLB security group (client IP preserved)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  # No egress block: the ALB's main group keeps the egress to the targets.

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sg-alb-from-nlb"
  })
}
