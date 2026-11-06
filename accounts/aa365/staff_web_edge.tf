# =============================================================================
# AA-911 (root ADR 0019 d23 + S271 amendment) — the edge of the staff frontends on ECS (modules/environment/staff_web.tf,
# one service per app): the hosts, their certificate on the shared ALB's HTTPS listener, the DNS cut-over switch, the
# switch-window TTL and the apex redirect.
#
# No CDN and no new web ACL (ADR 0019 d23): browsers reach the ALB's :443 directly (modules/vpc ALB group, CIDRs
# below), behind the ALB's existing REGIONAL web ACL (modules/waf: CommonRuleSet, VPC allow, rate per real client IP,
# geo). The staff hosts are scoped out of the API-sized RateLimit1000 rule and get their own rate rule
# (StaffWebRateLimit, var.staff_web_rate_limit, main.tf module "waf"): a Next.js page load, its RSC navigations and
# Link prefetches are many requests, and staff behind one office NAT IP share one budget. The geo rule applies to the
# staff hosts as to every viewer (root runbook staff-web-ecs-cutover.md: a VPN exit outside the list is blocked). The
# listener answers 404 to any host without a host rule (modules/alb); the host rules are in alb_rules.tf
# (alb_https_rule_priorities).
#
# Hosts: the SAME names the staff use today on Vercel (aa-cis. and booking.), so no Cognito callback, app link, CRM
# link or bookmark changes at the cut-over. Before the cut-over the ECS hosts are verified by resolving the name to
# the ALB on the test client only (curl --resolve, Chromium --host-resolver-rules): sign-in works there because the
# callback URLs are the same names.
#
# Certificate: a WILDCARD *.<zone> (+ the apex), not aa-cis. + booking. Both names CNAME to Vercel until the flip and
# the CAA lookup follows the CNAME to a Vercel set that does not list Amazon, so a certificate naming them fails with
# CAA_ERROR (same trap as crm_agency_edge.tf, critic C1). The wildcard and the apex are CAA-checked at the zone apex
# (no CAA record). ACM gives *.<zone> and <zone> ONE validation record (_<token>.<zone>), and the same one for every
# certificate of that name in this account: it already exists as crm_agency_edge.tf
# aws_route53_record.crm_agency_acm_validation (the us-east-1 wildcard), so this certificate validates through it
# and creates no record of its own (a second record of the same name fails "already exists"). If ACM ever handed a
# different token, aws_acm_certificate_validation fails at once ("missing ... DNS validation record"), not after the
# timeout.
#
# Cut-over (root runbook staff-web-ecs-cutover.md): var.staff_web_dns_on_ecs = true re-points the two CNAMEs (dns.tf
# "aa-cis|CNAME", custom_domains.tf vercel_frontend["booking"]) from Vercel to the ALB, in place (same record, new
# value). var.staff_web_dns_switch_window (on from the first apply, terraform.tfvars) drops both records to a 60 s
# TTL so the flip and a rollback reach every resolver within a minute; it goes back off at the Vercel retirement.
# var.staff_web_apex_on_alb points the apex A record at the ALB (alias) where a :443 host rule redirects to aa-cis.;
# it must be on before the aa-cis-frontend Vercel project, which claims the apex today, is removed.
#
# Cost: the ACM certificate is free (public, DNS-validated), no new record; one listener certificate and three
# listener rules on the existing ALB: no extra LCU at Dev volume; one more WAF rule 1 USD/month.
# =============================================================================

variable "staff_web_dns_on_ecs" {
  description = "AA-911 cut-over: true points aa-cis.<zone> and booking.<zone> at the shared ALB (staff frontends on ECS); false keeps them on Vercel. Flip only after the ECS hosts are verified (runbook staff-web-ecs-cutover.md)."
  type        = bool
  default     = false
}

variable "staff_web_dns_switch_window" {
  description = "AA-911: true sets a 60 s TTL on aa-cis.<zone> and booking.<zone> (normally 1800 s and 300 s) while the cut-over and its rollback are possible. Must be applied at least 30 minutes before staff_web_dns_on_ecs flips; back to false at the Vercel retirement."
  type        = bool
  default     = false
}

variable "staff_web_apex_on_alb" {
  description = "AA-911: true makes the apex A record an alias to the shared ALB (a :443 host rule redirects to aa-cis.<zone>) instead of var.dns_apex_a_records (Vercel). Must be true before the aa-cis-frontend Vercel project is retired (dns.tf: an unclaimed Vercel A record is a takeover risk; Cognito custom domains need the apex A record)."
  type        = bool
  default     = false
}

variable "staff_web_rate_limit" {
  description = "AA-911: requests per 5 minutes per client IP on the two staff hosts (WAF rule StaffWebRateLimit). The staff hosts are scoped out of RateLimit1000."
  type        = number
  default     = 5000
}

locals {
  staff_web_tags = merge(local.ecosys_tags, { App = "shared", Component = "admin", Issue = "AA-911" })

  # App key (modules/environment staff_web.tf local.staff_web_apps) -> public host.
  staff_web_hosts = {
    cis     = "aa-cis.${var.dns_zone_name}"
    booking = "booking.${var.dns_zone_name}"
  }

  # The ALB will admit :443 from anywhere: the staff sign in from home and on the road (the web ACL's geo rule keeps the
  # allowed countries). The apps authenticate every page (Cognito WORKFORCE).
  # S271 two-step apply (independent review M1): module.alb depends on module.vpc, so the SG would open :443 before the
  # listener default turns into the fixed 404. First apply keeps :443 closed ([]); after describe-listeners shows the
  # 404 default, a one-line follow-up sets ["0.0.0.0/0"].
  staff_web_public_https_cidrs = ["0.0.0.0/0"]

  # DNS cut-over: the CNAME target of the two staff hosts once var.staff_web_dns_on_ecs is on.
  staff_web_alb_dns_name = module.alb.alb_dns_name

  # TTL of the two staff host records during the switch window (null = each record keeps its normal TTL).
  staff_web_switch_ttl = var.staff_web_dns_switch_window ? 60 : null

  # The certificate names: never a host that CNAMEs off-zone (test_aa911_staff_web.py).
  staff_web_cert_domain = "*.${var.dns_zone_name}"
  staff_web_cert_sans   = [var.dns_zone_name]
}

# -----------------------------------------------------------------------------
# Certificate (us-west-1, the ALB's region): *.<zone> + <zone>, validated through the existing wildcard validation
# record of crm_agency_edge.tf (header).
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "staff_web" {
  domain_name               = local.staff_web_cert_domain
  subject_alternative_names = local.staff_web_cert_sans
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  tags = merge(local.staff_web_tags, { Name = "aa-ecosys-dev-staff-web" })

  # A listener keeps serving the certificate it holds: a SAN change makes the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "staff_web" {
  certificate_arn         = aws_acm_certificate.staff_web.arn
  validation_record_fqdns = [aws_route53_record.crm_agency_acm_validation[local.crm_agency_wildcard].fqdn]
}

# SNI: the listener's default certificate stays as it is; this one answers the staff hosts and the apex.
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

output "staff_web_ecs_service_names" {
  description = "AA-911: ECS service per app key (= its task definition family)."
  value       = module.environment.staff_web_ecs_service_names
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
