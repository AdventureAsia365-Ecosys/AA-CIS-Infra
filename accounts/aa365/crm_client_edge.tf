# =============================================================================
# AA-936 (CRM-08) — the AA-Partner CLIENT host (travellers and prospects, design v3 §2.1): Dev go-dev.<zone>.
#
#   viewer -> CloudFront go-dev.<zone>  (+ X-AA-Origin: <the crm_edge.tf secret>)
#          -> the same VPC origin on the internal NLB (crm_edge.tf) -> ALB :80
#             rule crm_client_public (Host + secret + /crm/public/*) -> AA-Partner API (the public inquiry form)
#             rule crm_client_default (Host + secret, any other path) -> AA-Partner web (it serves /c/* only there)
#             rule crm_origin_deny (crm_edge.tf)                     -> 403 for anything else from CloudFront
#
# Why a second distribution, not an alias on the partner one: the partner distribution's certificate would have to
# be replaced to add a name (a live host's certificate swap), and the two hosts never share cookies anyway (host-only,
# CONTEXT.md). The VPC origin, the origin-verify secret and the managed policies are shared.
#
# Why /crm/public/* goes straight to the API on this host: the form page posts to its own origin, so the API's
# per-visitor limits key on CloudFront-Viewer-Address (a relay through the web would make every visitor the web's
# NAT address). Nothing else of the API is reachable on this host: /crm/v1, /crm/ops/v1, ... fall to the web, which
# answers 404 for every non-/c path of the client host.
#
# Env wiring: WEB_CLIENT_HOSTS of the web (crm_web.tf) and INTAKE_PAGE_ORIGINS of the API (crm_app.tf) come from
# local.crm_client_host below.
#
# Cost (est., D-19): CloudFront distribution and VPC origin reuse $0 (free tier traffic), ACM $0, Route 53 alias
# queries $0, two more ALB rules inside the rule allowance. ≈ $0/month on Dev.
# =============================================================================

variable "crm_client_subdomain" {
  description = "AA-936: label under dns_zone_name for the AA-Partner client host (design v3 §2.1: go-dev.)."
  type        = string
  default     = "go-dev"
}

locals {
  crm_client_host   = "${var.crm_client_subdomain}.${var.dns_zone_name}"
  crm_client_tags   = merge(local.crm_tags, { Issue = "AA-936" })
  crm_client_hosts  = local.crm_edge_on == 1 ? [local.crm_client_host] : []
  crm_intake_origin = local.crm_edge_on == 1 ? "https://${local.crm_client_host}" : ""
}

resource "aws_acm_certificate" "crm_client" {
  provider = aws.us_east_1

  domain_name       = local.crm_client_host
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = merge(local.crm_client_tags, { Name = "${local.crm_name_prefix}-client-cdn" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "crm_client_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.crm_client.domain_validation_options : dvo.domain_name => dvo }

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "crm_client" {
  count    = local.crm_edge_on
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.crm_client.arn
  validation_record_fqdns = [aws_route53_record.crm_client_acm_validation[local.crm_client_host].fqdn]
}

resource "aws_cloudfront_distribution" "crm_client" {
  count = local.crm_edge_on

  enabled         = true
  comment         = "AA-936 AA-Partner Dev client host (travellers; same VPC origin as the partner host)"
  aliases         = [local.crm_client_host]
  price_class     = var.crm_cdn_price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = local.crm_origin_id
    domain_name = module.alb.nlb_dns_name

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.crm[0].id
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
    compress                 = false
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf_headers[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.crm_client[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.crm_client_tags, { Name = "${local.crm_name_prefix}-client-cdn" })
}

resource "aws_route53_record" "crm_client" {
  for_each = local.crm_edge_on == 1 ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.crm_client_host
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.crm_client[0].domain_name
    zone_id                = aws_cloudfront_distribution.crm_client[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# The public inquiry form API on the client host (priority below the default rule of the same host).
resource "aws_lb_listener_rule" "crm_client_public" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_client_public

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_api.arn
  }

  condition {
    host_header {
      values = [local.crm_client_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  condition {
    path_pattern {
      values = ["/crm/public/*"]
    }
  }

  tags = local.crm_client_tags
}

resource "aws_lb_listener_rule" "crm_client_default" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_client_default

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_web.arn
  }

  condition {
    host_header {
      values = [local.crm_client_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  tags = local.crm_client_tags
}

output "crm_client_edge" {
  description = "AA-936: client host and its CloudFront domain (no secret values)."
  value = local.crm_edge_on == 1 ? {
    client_host         = local.crm_client_host
    distribution_id     = aws_cloudfront_distribution.crm_client[0].id
    distribution_domain = aws_cloudfront_distribution.crm_client[0].domain_name
  } : null
}
