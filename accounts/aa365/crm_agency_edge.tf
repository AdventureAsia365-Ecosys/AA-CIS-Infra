# =============================================================================
# AA-979 (CRM-P2b) — the AGENCY host portal.<zone>: one host for the CRM and the Content studio (root ADR 0010 §2 / §6,
# ADR 0010a; design S252 §1 / §2.5). Pattern of crm_client_edge.tf.
#
#   viewer -> CloudFront portal.<zone>  (+ X-AA-Origin: <the crm_edge.tf secret>)
#          -> the same VPC origin on the internal NLB (crm_edge.tf) -> ALB :80 (alb_rules.tf order)
#             crm_agency_api       (Host + secret + /crm, /crm/*)                       -> AA-Partner API
#             crm_agency_studio    (Host + secret + /portal*, /api/*, /tenant-login*)   -> Content studio (crm_portal.tf)
#             crm_agency_studio_x  (Host + secret + /terms, /privacy, /assets/*)        -> Content studio
#             crm_agency_default   (Host + secret, any other path)                      -> AA-Partner web
#             crm_origin_deny      (crm_edge.tf)                                        -> 403 for anything else
#
# `/portal*` (no slash) also matches the studio's asset prefix `/portal-assets/...` (Next assetPrefix), so the
# studio needs two rules within the ALB limit of 5 condition values per rule (host 1 + header 1 + 3 paths).
#
# THE CUTOVER SWITCH is var.crm_agency_live and it changes ONE thing: the target of the portal. CNAME (Vercel before,
# this distribution after). The web answers both partner hosts with a per-host public origin (AA-Partner web), so no
# ECS deploy, no web / API env change and no crm.job / shared.job gate is part of the cutover or of its rollback
# (critic C4). Flip = in-place UPSERT of the same CNAME, no delete / create gap; the TTL is 60 s during the window.
#
# Certificate (critic C1): a WILDCARD *.<zone>, not portal.<zone>. portal. CNAMEs to Vercel today and the CAA lookup
# follows the CNAME to a set that does not list Amazon, so a portal.-only certificate fails (CAA_ERROR) until the
# flip; the wildcard is CAA-checked at the zone apex (no CAA record). Attached to this distribution only (Q11); the
# clean-up may swap it for a portal.-only certificate once the CNAME points here.
#
# Cost (est., D-19): distribution and VPC-origin reuse $0 (traffic inside the always-free 1 TB / 10M requests), ACM $0,
# Route 53 validation record + queries ~ $0, four ALB rules inside the LCU rule allowance (< $0.10/month).
# =============================================================================

variable "crm_agency_subdomain" {
  description = "AA-979: label under dns_zone_name of the agency host (CRM + Content studio), ADR 0010 §2."
  type        = string
  default     = "portal"
}

variable "crm_agency_live" {
  description = "AA-979 P2b CUTOVER SWITCH: true points the portal. CNAME at the crm_agency CloudFront distribution (Fargate), false at the Vercel project aa-cis-portal (rollback target). Changes the DNS target only (no ECS deploy, no env change)."
  type        = bool
  default     = false
}

variable "crm_agency_vercel_target" {
  description = "AA-979: the Vercel CNAME target of portal. (project aa-cis-portal; was custom_domain_vercel_hosts.portal). Kept as the rollback target until the P2b clean-up (P2b + 7 days)."
  type        = string
  default     = "22ba595c1afe124b.vercel-dns-017.com"
}

variable "crm_agency_dns_ttl" {
  description = "AA-979: TTL of the portal. CNAME. 60 s during the P2b window (lowered at least one old TTL, 300 s, before the flip); back to 300 at the clean-up."
  type        = number
  default     = 60
}

locals {
  crm_agency_host     = "${var.crm_agency_subdomain}.${var.dns_zone_name}"
  crm_agency_wildcard = "*.${var.dns_zone_name}"
  crm_agency_tags     = merge(local.crm_tags, { Issue = "AA-979" })
}

resource "aws_acm_certificate" "crm_agency" {
  provider = aws.us_east_1

  domain_name       = local.crm_agency_wildcard
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = merge(local.crm_agency_tags, { Name = "${local.crm_name_prefix}-agency-cdn" })

  lifecycle {
    create_before_destroy = true
  }
}

# The wildcard's validation record is _<token>.<zone> (never the live portal. CNAME).
resource "aws_route53_record" "crm_agency_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.crm_agency.domain_validation_options : dvo.domain_name => dvo }

  zone_id         = aws_route53_zone.lumiguides.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = false
}

resource "aws_acm_certificate_validation" "crm_agency" {
  count    = local.crm_edge_on
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.crm_agency.arn
  validation_record_fqdns = [aws_route53_record.crm_agency_acm_validation[local.crm_agency_wildcard].fqdn]
}

resource "aws_cloudfront_distribution" "crm_agency" {
  count = local.crm_edge_on

  enabled         = true
  comment         = "AA-979 AA-Partner Dev agency host (CRM + Content studio; same VPC origin as the partner host)"
  aliases         = [local.crm_agency_host]
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

  # CachingDisabled: authenticated pages and the BFF are never cached at the edge (design §8).
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
    acm_certificate_arn      = aws_acm_certificate_validation.crm_agency[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.crm_agency_tags, { Name = "${local.crm_name_prefix}-agency-cdn" })
}

# -----------------------------------------------------------------------------
# The portal. record. It was aws_route53_record.vercel_frontend["portal"] (custom_domains.tf); the moved block keeps
# the same Route 53 record (plan: update in place, TTL 300 -> 60, never destroy / create). It stays a CNAME on both
# sides of the switch (a subdomain may CNAME to CloudFront), so the cutover and its rollback are a one-value UPSERT.
# -----------------------------------------------------------------------------
moved {
  from = aws_route53_record.vercel_frontend["portal"]
  to   = aws_route53_record.crm_agency[0]
}

resource "aws_route53_record" "crm_agency" {
  count = var.custom_domains_enabled ? 1 : 0

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.crm_agency_host
  type    = "CNAME"
  ttl     = var.crm_agency_dns_ttl
  records = [var.crm_agency_live ? aws_cloudfront_distribution.crm_agency[0].domain_name : var.crm_agency_vercel_target]

  lifecycle {
    precondition {
      condition     = !var.crm_agency_live || local.crm_edge_on == 1
      error_message = "crm_agency_live = true needs the CRM edge (crm_edge_enabled and custom_domains_enabled)."
    }
  }
}

# -----------------------------------------------------------------------------
# ALB host rules (priorities in alb_rules.tf; all below crm_origin_deny 20, all with the host and the secret).
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "crm_agency_api" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_agency_api

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_api.arn
  }

  condition {
    host_header {
      values = [local.crm_agency_host]
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
      values = ["/crm", "/crm/*"]
    }
  }

  tags = local.crm_agency_tags
}

resource "aws_lb_listener_rule" "crm_agency_studio" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_agency_studio

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_portal.arn
  }

  condition {
    host_header {
      values = [local.crm_agency_host]
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
      # /portal* also covers the studio's Next assets under /portal-assets/ (assetPrefix).
      values = ["/portal*", "/api/*", "/tenant-login*"]
    }
  }

  tags = local.crm_agency_tags
}

resource "aws_lb_listener_rule" "crm_agency_studio_x" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_agency_studio_x

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_portal.arn
  }

  condition {
    host_header {
      values = [local.crm_agency_host]
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
      values = ["/terms", "/privacy", "/assets/*"]
    }
  }

  tags = local.crm_agency_tags
}

resource "aws_lb_listener_rule" "crm_agency_default" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_agency_default

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crm_web.arn
  }

  condition {
    host_header {
      values = [local.crm_agency_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  tags = local.crm_agency_tags
}

output "crm_agency_edge" {
  description = "AA-979: the agency host, its CloudFront domain (the --resolve target of the pre-cutover smoke) and where portal. points now (no secret values)."
  value = local.crm_edge_on == 1 ? {
    agency_host         = local.crm_agency_host
    distribution_id     = aws_cloudfront_distribution.crm_agency[0].id
    distribution_domain = aws_cloudfront_distribution.crm_agency[0].domain_name
    live                = var.crm_agency_live
    dns_target          = var.crm_agency_live ? aws_cloudfront_distribution.crm_agency[0].domain_name : var.crm_agency_vercel_target
  } : null
}
