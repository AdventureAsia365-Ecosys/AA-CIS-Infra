# =============================================================================
# AA-1105 (root ADR 0022, decision D17) — the AA Academy host academy.<zone>, served by the AA-Partner CRM web.
#
#   viewer -> CloudFront (the AGENCY distribution of crm_agency_edge.tf, which carries academy.<zone> as a second alias)
#          + X-AA-Origin: <the crm_edge.tf secret>
#          -> the same VPC origin on the internal NLB -> ALB :80 (alb_rules.tf order)
#             crm_academy_default (Host academy + secret, any path) -> AA-Partner web
#             crm_origin_deny     (crm_edge.tf)                     -> 403 for anything else
#
# There is NO /crm/* rule on this host: the academy pages talk to the CIS learning API (/learn/v1) through the web's own
# server-side BFF, never to the CRM API, so /crm/health on academy.<zone> reaches the web and answers its 404 page. The
# web itself refuses the agency and staff-console routes on this host and the academy routes on the other hosts
# (AA-Partner web/lib/hosts.ts, WEB_ACADEMY_HOSTS from modules/environment crm_web.tf).
#
# Certificate: the agency distribution's WILDCARD *.<zone> (us-east-1) already covers academy.<zone>, so no new
# certificate and no validation record. A second alias on the same distribution, not a new distribution: the origin,
# the cache policy (CachingDisabled) and the origin secret are the same, and a new distribution would add a second
# VPC-origin attachment for no gain.
#
# DNS: Route 53 ALIAS records (A and AAAA) to the distribution. The distribution must list the alias before the record
# can point at it (CloudFront refuses a CNAME/alias it does not carry), so the records depend on the distribution.
#
# Cost (est.): $0. The distribution, the VPC origin and the wildcard certificate exist; alias queries to CloudFront are
# free; one ALB rule inside the LCU rule allowance.
# =============================================================================

variable "academy_subdomain" {
  description = "AA-1105: label under dns_zone_name of the AA Academy host (root ADR 0022, D17), served by the CRM web."
  type        = string
  default     = "academy"
}

locals {
  academy_host = "${var.academy_subdomain}.${var.dns_zone_name}"
  academy_tags = merge(local.crm_tags, { Component = "edge", Issue = "AA-1105" })
}

resource "aws_route53_record" "academy" {
  for_each = local.crm_edge_on == 1 && var.custom_domains_enabled ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.academy_host
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.crm_agency[0].domain_name
    zone_id                = aws_cloudfront_distribution.crm_agency[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Below crm_origin_deny (alb_rules.tf), with the host and the secret like every CloudFront host rule.
resource "aws_lb_listener_rule" "crm_academy_default" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_academy_default

  action {
    type             = "forward"
    target_group_arn = module.environment.crm_web_target_group_arn
  }

  condition {
    host_header {
      values = [local.academy_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  tags = local.academy_tags
}

output "academy_edge" {
  description = "AA-1105: the AA Academy host and the distribution that serves it (the agency distribution; no secret values)."
  value = local.crm_edge_on == 1 ? {
    academy_host        = local.academy_host
    distribution_id     = aws_cloudfront_distribution.crm_agency[0].id
    distribution_domain = aws_cloudfront_distribution.crm_agency[0].domain_name
  } : null
}
