# =============================================================================
# AA-931 (CRM-03) — CloudFront VPC-origin spike for AA-Partner (design-v3 §6.3, v2.1 T1, v2.2 V3).
#
#   viewer -> CloudFront partner-dev.lumiguides.it.com  (+ X-AA-Origin: <secret>)
#          -> VPC origin -> internal NLB aa-cis-dev-nlb (the existing API Gateway VPC-link NLB)
#          -> ALB :80 rule crm_spike_partner (Host + secret)  -> hello task (Fargate ARM64, Spot)
#             ALB :80 rule crm_origin_deny  (any X-AA-Origin) -> 403, never CIS or Booking
#
# What it proves before CRM-04 builds on it: CloudFront can reach the private NLB through a VPC origin;
# a non-partner Host (or the raw *.cloudfront.net name) gets 403; a streamed 30 s SSR response is not
# cut; a viewer outside the shared WAF's country list still loads the page.
#
# Pieces outside this file: alb_rules.tf (priorities), modules/alb (NLB prefix-list ingress + the
# second ALB group, gated by cloudfront_vpc_origin_enabled), modules/waf (CloudFrontOriginAllow,
# gated by origin_verify_header), cicd_crm.tf (the apply-role grants this needs: VPC origin, origin
# request policy lookup, SetSecurityGroups). Reasons for each choice: docs/implementation-notes/AA-931.md.
#
# The hello task needs no image build: the public python:3.12-slim image runs
# assets/crm_spike/server.py through `python3 -c`. No task role, no ECS exec, read-only root file
# system, user nobody. The service is created at desired_count 0 and scaled by hand for the live check.
#
# Cost (est., us-west-1, D-19): the NLB is the existing one, so no new NLB hours (a dedicated NLB would
# be ~$18/month + LCU); spike traffic adds well under one NLB/ALB LCU (< $0.10/month). CloudFront:
# VPC origins have no extra charge, traffic sits inside the always-free tier (1 TB, 10M requests;
# PAYG worst case for a spike < $0.10). ACM, Route 53 alias queries: $0. Hello task 0.25 vCPU / 0.5 GB
# ARM64: $0 at desired 0; ~$2.5-3/month on Spot if left at 1 around the clock (~$8.3 on-demand).
# Logs: cents.
# =============================================================================

variable "crm_edge_enabled" {
  description = "AA-931: create the AA-Partner CloudFront edge (VPC origin on the NLB, distribution, partner host + deny ALB rules, WAF allow rule) and the hello spike service. Also needs custom_domains_enabled (certificate validation)."
  type        = bool
  default     = true
}

variable "crm_partner_subdomain" {
  description = "AA-931: label under dns_zone_name for the AA-Partner Dev host (design-v3 §2.1: partner-dev.)."
  type        = string
  default     = "partner-dev"
}

variable "crm_spike_image" {
  description = "AA-931: image of the hello spike task. Public multi-arch Python image; the server code is passed as `python3 -c` (assets/crm_spike/server.py), so nothing is built or pushed."
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim"
}

variable "crm_cdn_price_class" {
  description = "AA-931: CloudFront price class of the partner distribution. PriceClass_200 includes the Asia edges the agencies are near."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.crm_cdn_price_class)
    error_message = "crm_cdn_price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

locals {
  crm_edge_on      = var.crm_edge_enabled && var.custom_domains_enabled ? 1 : 0
  crm_partner_host = "${var.crm_partner_subdomain}.${var.dns_zone_name}"
  crm_spike_name   = "${local.crm_name_prefix}-spike"
  crm_spike_port   = 8080
  crm_spike_tags   = merge(local.crm_tags, { Issue = "AA-931" })
  crm_origin_id    = "crm-vpc-origin"
}

# -----------------------------------------------------------------------------
# Origin-verify secret. CloudFront adds it to every origin request; the ALB partner rule and the WAF
# allow rule require the exact value. Defence in depth on top of the network path (internal NLB, ALB
# groups) and the Host rule. random_password is a plan-guard type: the first CI apply needs
# allow_guarded=true. Rotate with -replace=random_password.crm_origin_verify[0] (same opt-in).
# -----------------------------------------------------------------------------
resource "random_password" "crm_origin_verify" {
  count   = local.crm_edge_on
  length  = 48
  special = false # ALB http-header condition values: printable ASCII, no wildcard characters
}

# -----------------------------------------------------------------------------
# Certificate (us-east-1, CloudFront) + DNS-validation CNAME (unconditional, like photos_cdn.tf)
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "crm_partner" {
  provider = aws.us_east_1

  domain_name       = local.crm_partner_host
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = merge(local.crm_spike_tags, { Name = "${local.crm_name_prefix}-partner-cdn" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "crm_partner_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.crm_partner.domain_validation_options : dvo.domain_name => dvo }

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "crm_partner" {
  count    = local.crm_edge_on
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.crm_partner.arn
  validation_record_fqdns = [aws_route53_record.crm_partner_acm_validation[local.crm_partner_host].fqdn]
}

# -----------------------------------------------------------------------------
# CloudFront: VPC origin on the existing internal NLB + distribution
# -----------------------------------------------------------------------------
resource "aws_cloudfront_vpc_origin" "crm" {
  count = local.crm_edge_on

  vpc_origin_endpoint_config {
    name                   = "${local.crm_name_prefix}-nlb-origin"
    arn                    = module.alb.nlb_arn
    http_port              = 80
    https_port             = 443 # required field; the NLB has no :443 listener and the policy is http-only
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = merge(local.crm_spike_tags, { Name = "${local.crm_name_prefix}-nlb-origin" })

  # The NLB group's CloudFront prefix-list rule and the second ALB group (module.alb) come first.
  depends_on = [module.alb, time_sleep.wait_for_iam_propagation]
}

# AWS managed policies, looked up by name (stable names, no IDs pasted here).
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = local.crm_edge_on
  name  = "Managed-CachingDisabled"
}

# Forwards every viewer header (the Host the ALB rule matches, cookies for SSR sessions) plus the
# CloudFront-Viewer-* headers (CloudFront-Viewer-Address feeds the app-level rate limits, AA-933).
data "aws_cloudfront_origin_request_policy" "all_viewer_and_cf_headers" {
  count = local.crm_edge_on
  name  = "Managed-AllViewerAndCloudFrontHeaders-2022-06"
}

resource "aws_cloudfront_distribution" "crm_partner" {
  count = local.crm_edge_on

  enabled         = true
  comment         = "AA-931 AA-Partner Dev edge (VPC origin on the NLB, ALB host rule)"
  aliases         = [local.crm_partner_host]
  price_class     = var.crm_cdn_price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = local.crm_origin_id
    domain_name = module.alb.nlb_dns_name

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.crm[0].id
      # 60 s = the maximum without a quota increase. The default 30 s would cut an SSR response whose
      # first byte (or the gap between two chunks) takes 30 s. ALB idle 100 s, NLB TCP idle 350 s.
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }

    custom_header {
      name  = local.alb_origin_header_name
      value = random_password.crm_origin_verify[0].result
    }
  }

  default_cache_behavior {
    target_origin_id         = local.crm_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false # nothing is cached; keep streamed SSR chunks unbuffered
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf_headers[0].id
  }

  # No geo restriction and no WAF on Dev (the CloudFront WAF comes at Go-real, W8, without geo block).
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.crm_partner[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.crm_spike_tags, { Name = "${local.crm_name_prefix}-partner-cdn" })
}

resource "aws_route53_record" "crm_partner" {
  for_each = local.crm_edge_on == 1 ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.crm_partner_host
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.crm_partner[0].domain_name
    zone_id                = aws_cloudfront_distribution.crm_partner[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# ALB: hello target group + the two CloudFront-path rules (priorities: alb_rules.tf)
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "crm_spike" {
  count = local.crm_edge_on

  name                 = "${local.crm_spike_name}-tg"
  port                 = local.crm_spike_port
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  target_type          = "ip" # Fargate
  deregistration_delay = 30

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

  tags = local.crm_spike_tags
}

resource "aws_lb_listener_rule" "crm_spike_partner" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_spike_partner

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_spike[0].arn
  }

  condition {
    host_header {
      values = [local.crm_partner_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  tags = local.crm_spike_tags
}

resource "aws_lb_listener_rule" "crm_origin_deny" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_origin_deny

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden\n"
      status_code  = "403"
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = ["*"]
    }
  }

  tags = local.crm_spike_tags
}

# -----------------------------------------------------------------------------
# Hello task: logs, execution role (logs only), security group, task definition, service
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "crm_spike" {
  count = local.crm_edge_on

  name              = "/ecs/${local.crm_spike_name}"
  retention_in_days = 30 # AA-872 (S241 D-09): application logs 30 days
  tags              = local.crm_spike_tags
}

resource "aws_iam_role" "crm_spike_ecs_execution" {
  count = local.crm_edge_on

  name                 = "${local.crm_spike_name}-ecs-execution-role"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.booking_ecs_tasks_assume.json # ecs-tasks, this account only
  tags                 = local.crm_spike_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

# The image is public (no ECR pull grant needed) and there is no secret: only the log stream writes.
resource "aws_iam_role_policy" "crm_spike_ecs_execution" {
  count = local.crm_edge_on

  name = "${local.crm_spike_name}-ecs-execution"
  role = aws_iam_role.crm_spike_ecs_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteSpikeLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.crm_spike[0].arn}:log-stream:*"
    }]
  })
}

resource "aws_security_group" "crm_spike" {
  count = local.crm_edge_on

  name        = "${local.crm_spike_name}-sg"
  description = "AA-931 AA-Partner hello spike (ADR 0004b: own group)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "App port from the ALB"
    from_port       = local.crm_spike_port
    to_port         = local.crm_spike_port
    protocol        = "tcp"
    security_groups = [module.vpc.sg_alb_id]
  }

  egress {
    description = "All outbound (NAT: image pull from ECR Public, CloudWatch Logs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.crm_spike_tags, { Name = "${local.crm_spike_name}-sg" })
}

resource "aws_ecs_task_definition" "crm_spike" {
  count = local.crm_edge_on

  family                   = local.crm_spike_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.crm_spike_ecs_execution[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name                   = "web"
    image                  = var.crm_spike_image
    essential              = true
    command                = ["python3", "-c", file("${path.module}/assets/crm_spike/server.py")]
    user                   = "65534" # nobody; port 8080 needs no privilege
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = local.crm_spike_port, protocol = "tcp" }]
    environment            = [{ name = "PORT", value = tostring(local.crm_spike_port) }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.crm_spike[0].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "web"
      }
    }
    stopTimeout = 10
  }])

  tags = local.crm_spike_tags
}

resource "aws_ecs_service" "crm_spike" {
  count = local.crm_edge_on

  name            = local.crm_spike_name
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.crm_spike[0].arn
  desired_count   = 0 # scaled to 1 by hand for the live check, back to 0 after

  # Fargate Spot on ARM64 (supported since 09/2024). An interruption only means re-running the check.
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 30

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.crm_spike[0].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.crm_spike[0].arn
    container_name   = "web"
    container_port   = local.crm_spike_port
  }

  enable_execute_command = false
  propagate_tags         = "SERVICE" # App = crm on the tasks (cost allocation)

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = local.crm_spike_tags

  # ECS rejects a service whose target group is not attached to a load balancer yet.
  depends_on = [aws_lb_listener_rule.crm_spike_partner, aws_iam_role_policy.crm_spike_ecs_execution]
}

output "crm_edge_spike" {
  description = "AA-931: partner host, CloudFront domain and the spike service (no secret values)."
  value = local.crm_edge_on == 1 ? {
    partner_host        = local.crm_partner_host
    distribution_id     = aws_cloudfront_distribution.crm_partner[0].id
    distribution_domain = aws_cloudfront_distribution.crm_partner[0].domain_name
    vpc_origin_id       = aws_cloudfront_vpc_origin.crm[0].id
    ecs_service         = aws_ecs_service.crm_spike[0].name
  } : null
}
