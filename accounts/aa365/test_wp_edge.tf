# =============================================================================
# AA-1060 — the edge of the WordPress test site (the sidecar of the Booking admin task, modules/environment
# test_wp.tf: read its header for the design, the two switches and the cost).
#
#   viewer / CIS publish path -> https://test-wp.<zone> -> ALB :443 (the wildcard *.<zone> certificate of
#   staff_web_edge.tf already covers the name: no new certificate) -> alb_rules.tf test_wp_block (403 on the sign-in
#   and admin paths) / test_wp (forward) -> the sidecar's target group.
#
# The host is behind the ALB's REGIONAL web ACL like every :443 host (CommonRuleSet, RateLimit1000 per client IP, geo);
# it is not a staff host, so the staff rate rule does not apply to it.
#
# Switches (terraform.tfvars):
#   test_wp_enabled           container in the Booking admin task definition, target group, the two ALB rules, this
#                             DNS record, the staff web security group port 80 from the ALB.
#   test_wp_service_attached  the Booking admin service registers the container in the target group. Turn it on in a
#                             second apply, after a Booking admin deploy has put a revision with the container on the
#                             service (ECS refuses a load balancer naming a container the current revision lacks).
#
# Cost: one Route 53 record (no per-record charge), two listener rules and a target group on the existing ALB.
# =============================================================================

variable "test_wp_enabled" {
  description = "AA-1060: the WordPress test site sidecar on the Booking admin task, with its target group, ALB rules, DNS record and security group port."
  type        = bool
  default     = false
}

variable "test_wp_service_attached" {
  description = "AA-1060: the Booking admin service registers the sidecar in its target group. Second apply only, after a Booking admin deploy has put a revision with the container on the service."
  type        = bool
  default     = false
}

locals {
  test_wp_on   = var.test_wp_enabled ? 1 : 0
  test_wp_host = "test-wp.${var.dns_zone_name}"
  test_wp_tags = merge(local.ecosys_tags, { App = "cis", Component = "web", Issue = "AA-1060" })

  # Paths of a browser sign-in, the dashboard and XML-RPC: the ALB answers 403 (the REST API with the application
  # password is the only way in). At most 5 condition values per rule: 1 host + these 4.
  test_wp_blocked_paths = ["/wp-login.php", "/wp-admin", "/wp-admin/*", "/xmlrpc.php"]
}

resource "aws_route53_record" "test_wp" {
  count = local.test_wp_on

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.test_wp_host
  type    = "CNAME"
  ttl     = 300
  records = [module.alb.alb_dns_name]
}

output "test_wp_url" {
  description = "AA-1060: base URL of the WordPress test site (empty while test_wp_enabled is false)."
  value       = var.test_wp_enabled ? "https://${local.test_wp_host}" : ""
}
