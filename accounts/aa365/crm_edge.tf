# =============================================================================
# AA-931 (CRM-03) — AA-Partner CloudFront edge (design-v3 §6.3, v2.1 T1, v2.2 V3). Proven by the AA-931 spike;
# the spike's hello service was removed in AA-933 (S248, Nghiệp decision d16).
#
#   viewer -> CloudFront partner-dev.lumiguides.it.com  (+ X-AA-Origin: <secret>)
#          -> VPC origin -> internal NLB aa-cis-dev-nlb (the existing API Gateway VPC-link NLB)
#          -> ALB :80 rule crm_api             (Host + secret + /crm, /crm/*) -> AA-Partner API (crm_app.tf)
#             ALB :80 rule crm_partner_default (Host + secret, any other path) -> fixed 404 JSON
#             ALB :80 rule crm_origin_deny     (any X-AA-Origin)              -> 403, never CIS or Booking
#
# crm_partner_default holds the partner host's other paths until the CRM web (AA-935) exists; AA-935 turns it into
# a forward to the web target group. It also lets the edge be checked at $0 with no task running
# (tools/terraform/crm_edge_live_check.py: partner / -> this 404, raw *.cloudfront.net -> the deny 403).
#
# Pieces outside this file: alb_rules.tf (priorities), modules/alb (NLB prefix-list ingress + the
# second ALB group, gated by cloudfront_vpc_origin_enabled), modules/waf (CloudFrontOriginAllow,
# gated by origin_verify_header), cicd_crm.tf (the apply-role grants this needs: VPC origin, origin
# request policy lookup, SetSecurityGroups). Reasons for each choice: docs/implementation-notes/AA-931.md
# (edge) and AA-933.md (spike removal, default rule).
#
# Cost (est., us-west-1, D-19): the NLB is the existing one, so no new NLB hours (a dedicated NLB would
# be ~$18/month + LCU); Dev traffic adds well under one NLB/ALB LCU (< $0.10/month). CloudFront:
# VPC origins have no extra charge, traffic sits inside the always-free tier (1 TB, 10M requests).
# ACM, Route 53 alias queries: $0. Fixed-response ALB rules: $0 (inside the ALB's LCU rule allowance).
# =============================================================================

variable "crm_edge_enabled" {
  description = "AA-931: create the AA-Partner CloudFront edge (VPC origin on the NLB, distribution, partner host default + deny ALB rules, WAF allow rule). Also needs custom_domains_enabled (certificate validation)."
  type        = bool
  default     = true
}

variable "crm_partner_subdomain" {
  description = "AA-931: label under dns_zone_name for the AA-Partner Dev host (design-v3 §2.1: partner-dev.)."
  type        = string
  default     = "partner-dev"
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
  crm_edge_tags    = merge(local.crm_tags, { Issue = "AA-931" })
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

  tags = merge(local.crm_edge_tags, { Name = "${local.crm_name_prefix}-partner-cdn" })

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

  tags = merge(local.crm_edge_tags, { Name = "${local.crm_name_prefix}-nlb-origin" })

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

  tags = merge(local.crm_edge_tags, { Name = "${local.crm_name_prefix}-partner-cdn" })
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
# ALB: the two CloudFront-path rules owned here (priorities: alb_rules.tf). The partner host's /crm/* rule is
# crm_app.tf (crm_api).
# -----------------------------------------------------------------------------

# AA-933 (d16): the hello spike rule became the partner host's default. Same address history: the rule is
# modified in place (ModifyRule, same priority and ARN), never deleted and re-created at a used priority.
moved {
  from = aws_lb_listener_rule.crm_spike_partner
  to   = aws_lb_listener_rule.crm_partner_default
}

resource "aws_lb_listener_rule" "crm_partner_default" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_partner_default

  # Until the CRM web (AA-935): every partner-host path that is not /crm or /crm/* (crm_api, above) gets a JSON
  # 404 in the shape FastAPI uses. AA-935 changes this action to a forward to the web target group.
  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ detail = "Not Found" })
      status_code  = "404"
    }
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

  tags = local.crm_edge_tags
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

  tags = local.crm_edge_tags
}

output "crm_edge" {
  description = "AA-931: partner host, CloudFront domain and VPC origin (no secret values)."
  value = local.crm_edge_on == 1 ? {
    partner_host        = local.crm_partner_host
    distribution_id     = aws_cloudfront_distribution.crm_partner[0].id
    distribution_domain = aws_cloudfront_distribution.crm_partner[0].domain_name
    vpc_origin_id       = aws_cloudfront_vpc_origin.crm[0].id
  } : null
}
