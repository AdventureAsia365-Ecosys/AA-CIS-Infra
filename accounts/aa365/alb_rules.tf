# =============================================================================
# AA-931 (CRM-03, v2.2 V3) — the ONE place that sets priorities on the shared ALB's HTTP listener.
#
# The ALB :80 listener is reached by two paths, both through the internal NLB:
#   - API Gateway REST (CIS, Booking) -> VPC link -> NLB -> ALB   (Host = the NLB name, set by API GW)
#   - CloudFront (AA-Partner)         -> VPC origin -> NLB -> ALB (Host = the viewer's host; CloudFront
#                                                                   always adds the X-AA-Origin header)
# A lower number is evaluated first and the first match wins, so ORDER IS THE CONTROL:
#
#   < 20   CloudFront host rules: Host = a partner host AND X-AA-Origin = the secret -> forward, or a fixed
#          response (crm_partner_default forwards the partner host's other paths to the CRM web since AA-935)
#   20     crm_origin_deny: ANY X-AA-Origin -> fixed 403. Everything that came through CloudFront and
#          matched no host rule above (raw *.cloudfront.net name, another Host) stops here, before any
#          CIS / Booking rule and before the default action (CIS api).
#   > 20   API Gateway path rules (Booking /booking/*), then the default action.
#
# tools/terraform/alb_rule_order.py checks these invariants on the source in CI (alb-rule-order.yml)
# and on `aws elbv2 describe-rules` output after an apply: every aws_lb_listener_rule takes its
# priority from this map (no literal), priorities are unique, every rule carrying the exact origin
# header forwards or answers a fixed response, also has a host condition and sits below the deny rule,
# and every rule without the header sits above it.
# =============================================================================

locals {
  alb_origin_header_name = "X-AA-Origin"

  alb_http_rule_priorities = {
    crm_api             = 5   # below (was crm_app.tf): partner-dev. host + /crm, /crm/* -> AA-Partner API (AA-933)
    crm_client_public   = 6   # crm_client_edge.tf: go-dev. host + /crm/public/* -> AA-Partner API (AA-936)
    crm_agency_api      = 7   # crm_agency_edge.tf: portal. host + /crm, /crm/* -> AA-Partner API (AA-979)
    crm_agency_studio   = 8   # crm_agency_edge.tf: portal. host + /portal*, /api/*, /tenant-login* -> Content studio (AA-979)
    crm_agency_studio_x = 9   # crm_agency_edge.tf: portal. host + /terms, /privacy, /assets/* -> Content studio (AA-979)
    crm_partner_default = 10  # crm_edge.tf: partner-dev. host, any other path -> AA-Partner web (AA-935; was a fixed 404, AA-933)
    crm_client_default  = 11  # crm_client_edge.tf: go-dev. host, any other path -> AA-Partner web (AA-936)
    crm_agency_default  = 12  # crm_agency_edge.tf: portal. host, any other path -> AA-Partner web (AA-979)
    crm_origin_deny     = 20  # crm_edge.tf: any X-AA-Origin -> 403 (AA-931)
    booking             = 100 # below: /booking, /booking/* (AA-678)
  }
}

# AA-678: the Booking API path rule. Its target group belongs to the Booking stack in modules/environment (AA-1004 P0
# slice 1); the rule itself stays here, on the shared listener, so this file keeps every priority of that listener and
# alb_rule_order.py keeps checking it in source mode. Same address as before the split (no moved block).
resource "aws_lb_listener_rule" "booking" {
  # API Gateway reaches the ALB on :80 through the VPC-link NLB, so the rule goes on the HTTP
  # listener (modules/alb output http_listener_arn, phase 1). The HTTPS listener is untouched.
  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.booking # 100 (AA-931)

  action {
    type             = "forward"
    target_group_arn = module.environment.booking_target_group_arn
  }

  condition {
    path_pattern {
      values = ["/booking", "/booking/*"]
    }
  }

  tags = local.bk_tags

  # CreateRule is granted by cicd.tf BookingAlbListenerRuleManage (phase 1).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

# AA-933: the AA-Partner API's CloudFront-path rule (was crm_app.tf; AA-1004 slice 2 moved the CRM stack into
# modules/environment and kept the rule here with the shared listener's order). Host = the partner host AND
# X-AA-Origin = the CloudFront secret AND path /crm or /crm/*, above crm_partner_default. The CRM ECS service waits for
# it through module input crm_api_listener_rule_gate.
resource "aws_lb_listener_rule" "crm_api" {
  count = local.crm_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.crm_api

  action {
    type             = "forward"
    target_group_arn = module.environment.crm_api_target_group_arn
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

  condition {
    path_pattern {
      values = ["/crm", "/crm/*"]
    }
  }

  tags = local.crm_app_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}
