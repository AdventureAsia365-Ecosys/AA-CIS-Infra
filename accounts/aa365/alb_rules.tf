# =============================================================================
# AA-931 (CRM-03, v2.2 V3) — the ONE place that sets priorities on the shared ALB's HTTP listener.
#
# The ALB :80 listener is reached by two paths, both through the internal NLB:
#   - API Gateway REST (CIS, Booking) -> VPC link -> NLB -> ALB   (Host = the NLB name, set by API GW)
#   - CloudFront (AA-Partner)         -> VPC origin -> NLB -> ALB (Host = the viewer's host; CloudFront
#                                                                   always adds the X-AA-Origin header)
# A lower number is evaluated first and the first match wins, so ORDER IS THE CONTROL:
#
#   < 20   CloudFront host rules: Host = a partner host AND X-AA-Origin = the secret -> forward
#   20     crm_origin_deny: ANY X-AA-Origin -> fixed 403. Everything that came through CloudFront and
#          matched no host rule above (raw *.cloudfront.net name, another Host) stops here, before any
#          CIS / Booking rule and before the default action (CIS api).
#   > 20   API Gateway path rules (Booking /booking/*), then the default action.
#
# tools/terraform/alb_rule_order.py checks these invariants on the source in CI (alb-rule-order.yml)
# and on `aws elbv2 describe-rules` output after an apply: every aws_lb_listener_rule takes its
# priority from this map (no literal), priorities are unique, every forward rule carrying the origin
# header also has a host condition and sits below the deny rule, and every rule without the header
# sits above it.
# =============================================================================

locals {
  alb_origin_header_name = "X-AA-Origin"

  alb_http_rule_priorities = {
    crm_spike_partner = 10  # crm_edge_spike.tf: partner-dev. host -> hello target group (AA-931)
    crm_origin_deny   = 20  # crm_edge_spike.tf: any X-AA-Origin -> 403 (AA-931)
    booking           = 100 # booking.tf: /booking, /booking/* (AA-678)
  }
}
