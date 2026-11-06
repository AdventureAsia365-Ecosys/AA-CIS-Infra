# =============================================================================
# AA-911 (root ADR 0019 d23) — the edge of the staff frontends on ECS (modules/environment/staff_web.tf): the hosts,
# their certificate on the shared ALB's HTTPS listener, and the DNS cut-over switch.
#
# No CDN and no new web ACL (ADR 0019 d23): browsers reach the ALB's :443 directly (modules/vpc ALB group, CIDRs
# below), behind the ALB's existing REGIONAL web ACL (modules/waf: CommonRuleSet, VPC allow, rate per real client IP,
# geo). The listener answers 404 to any host without a host rule (modules/alb); the two host rules are in
# alb_rules.tf (alb_https_rule_priorities).
#
# Hosts: the SAME names the staff use today on Vercel (aa-cis. and booking.), so no Cognito callback, app link, CRM
# link or bookmark changes at the cut-over. Before the cut-over the ECS hosts are verified by resolving the name to
# the ALB on the test client only (curl --resolve, Chromium --host-resolver-rules): sign-in works there because the
# callback URLs are the same names.
#
# Cut-over (a later live step, root docs/ops/runbooks/staff-web-ecs-cutover.md): var.staff_web_dns_on_ecs = true
# re-points the two CNAMEs (dns.tf "aa-cis|CNAME", custom_domains.tf vercel_frontend["booking"]) from Vercel to the
# ALB, in place (same record, new value). Rollback: false again. The Vercel projects keep running until the bridge
# retirement PR.
#
# Cost: the ACM certificate is free (public, DNS-validated); 2 validation records in the existing zone ~0 USD; one
# listener certificate and two listener rules on the existing ALB: no extra LCU at Dev volume.
# =============================================================================

variable "staff_web_dns_on_ecs" {
  description = "AA-911 cut-over: true points aa-cis.<zone> and booking.<zone> at the shared ALB (staff frontends on ECS); false keeps them on Vercel. Flip only after the ECS hosts are verified (runbook staff-web-ecs-cutover.md)."
  type        = bool
  default     = false
}

locals {
  staff_web_tags = merge(local.ecosys_tags, { App = "shared", Issue = "AA-911" })

  # App key (modules/environment staff_web.tf local.staff_web_apps) -> public host.
  staff_web_hosts = {
    cis     = "aa-cis.${var.dns_zone_name}"
    booking = "booking.${var.dns_zone_name}"
  }

  # The ALB admits :443 from anywhere: the staff sign in from home and on the road (the web ACL's geo rule keeps the
  # allowed countries). The apps authenticate every page (Cognito WORKFORCE).
  staff_web_public_https_cidrs = ["0.0.0.0/0"]

  # DNS cut-over: the CNAME target of the two staff hosts once var.staff_web_dns_on_ecs is on.
  staff_web_alb_dns_name = module.alb.alb_dns_name
}

# -----------------------------------------------------------------------------
# Certificate (us-west-1, the ALB's region) for the two hosts, DNS-validated in the account zone.
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "staff_web" {
  domain_name               = local.staff_web_hosts.cis
  subject_alternative_names = [local.staff_web_hosts.booking]
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  tags = merge(local.staff_web_tags, { Name = "aa-ecosys-dev-staff-web" })

  # A listener keeps serving the certificate it holds: a SAN change makes the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

# The validation names are _<token>.aa-cis. / _<token>.booking., never the live CNAMEs themselves.
resource "aws_route53_record" "staff_web_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.staff_web.domain_validation_options : dvo.domain_name => dvo }

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "staff_web" {
  certificate_arn         = aws_acm_certificate.staff_web.arn
  validation_record_fqdns = [for host in values(local.staff_web_hosts) : aws_route53_record.staff_web_acm_validation[host].fqdn]
}

# SNI: the listener's default certificate stays as it is; this one answers the two staff hosts.
resource "aws_lb_listener_certificate" "staff_web" {
  listener_arn    = module.alb.https_listener_arn
  certificate_arn = aws_acm_certificate_validation.staff_web.certificate_arn
}

# -----------------------------------------------------------------------------
# Outputs (names only).
# -----------------------------------------------------------------------------
output "staff_web_hosts" {
  description = "AA-911: public base URL per staff app (served by ECS once staff_web_dns_on_ecs = true)."
  value       = { for k, h in local.staff_web_hosts : k => "https://${h}" }
}

output "staff_web_ecs_service_name" {
  value = module.environment.staff_web_ecs_service_name
}

output "staff_web_task_definition_family" {
  value = module.environment.staff_web_task_definition_family
}

output "staff_web_container_names" {
  value = module.environment.staff_web_container_names
}

output "staff_web_ecr_repository_urls" {
  value = module.environment.staff_web_ecr_repository_urls
}

output "staff_web_secret_names" {
  description = "AA-911: the secrets tools/identity/staff_web_secret.py writes."
  value       = module.environment.staff_web_secret_names
}
