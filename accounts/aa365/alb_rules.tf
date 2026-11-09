# =============================================================================
# AA-931 (CRM-03, v2.2 V3) — the ONE place that sets priorities on the shared ALB's HTTP listener.
#
# The ALB :80 listener is reached by two paths, both through the internal NLB:
#   - API Gateway REST (CIS, Booking) -> VPC link -> NLB -> ALB   (Host = the NLB name, set by API GW)
#   - CloudFront (AA-Partner, TripPlanner web) -> VPC origin -> NLB -> ALB (Host = the viewer's host; CloudFront
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
    crm_partner_default = 10  # crm_edge.tf: partner-dev. host, any other path -> AA-Partner web (AA-935; was a fixed 404, AA-933)
    crm_client_default  = 11  # crm_client_edge.tf: go-dev. host, any other path -> AA-Partner web (AA-936)
    crm_agency_default  = 12  # crm_agency_edge.tf: portal. host, any other path -> AA-Partner web (AA-979)
    tripplanner_web     = 13  # tripplanner_web_edge.tf: tripplanner. host, any path -> TripPlanner web (AA-1038)
    crm_origin_deny     = 20  # crm_edge.tf: any X-AA-Origin -> 403 (AA-931)
    booking             = 100 # below: /booking, /booking/* (AA-678)
  }

  # AA-911 (root ADR 0019 d23): the HTTPS (:443) listener, reached by browsers directly (staff_web_edge.tf). Host rules
  # only; the listener's default answers 404 (modules/alb), so no other host reaches any target group. No origin
  # header is involved on this listener (no CloudFront), so alb_rule_order.py's HTTP invariants do not apply to it.
  alb_https_rule_priorities = {
    staff_cis_admin     = 10 # aa-cis. host -> CIS admin service (modules/environment staff_web.tf)
    staff_booking_admin = 11 # booking. host -> Booking admin service
    staff_apex_redirect = 12 # the apex -> 301 https://aa-cis.<zone>/ (dns.tf apex alias)
    test_wp_block       = 13 # test-wp. host + sign-in / admin / XML-RPC paths -> 403 (AA-1060, test_wp_edge.tf)
    test_wp             = 14 # test-wp. host, any other path -> the WordPress test site sidecar (AA-1060)
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

# AA-911: the staff frontends on the HTTPS listener, one host rule per app. The ECS service waits for both through
# module input staff_web_listener_rule_gate. CreateRule on this listener is granted by cicd.tf
# BookingAlbListenerRuleManage (every listener of the aa-cis-<env>-alb load balancer).
resource "aws_lb_listener_rule" "staff_cis_admin" {
  listener_arn = module.alb.https_listener_arn
  priority     = local.alb_https_rule_priorities.staff_cis_admin

  action {
    type             = "forward"
    target_group_arn = module.environment.staff_web_target_group_arns["cis"]
  }

  condition {
    host_header {
      values = [local.staff_web_hosts.cis]
    }
  }

  tags = local.staff_web_tags

  depends_on = [aws_lb_listener_certificate.staff_web]
}

resource "aws_lb_listener_rule" "staff_booking_admin" {
  listener_arn = module.alb.https_listener_arn
  priority     = local.alb_https_rule_priorities.staff_booking_admin

  action {
    type             = "forward"
    target_group_arn = module.environment.staff_web_target_group_arns["booking"]
  }

  condition {
    host_header {
      values = [local.staff_web_hosts.booking]
    }
  }

  tags = local.staff_web_tags

  depends_on = [aws_lb_listener_certificate.staff_web]
}

# AA-911: the apex redirect (dns.tf apex, an alias to the ALB since the Vercel retirement). Replaces the Vercel domain
# redirect of the retired aa-cis-frontend project.
resource "aws_lb_listener_rule" "staff_apex_redirect" {
  listener_arn = module.alb.https_listener_arn
  priority     = local.alb_https_rule_priorities.staff_apex_redirect

  action {
    type = "redirect"

    redirect {
      host        = local.staff_web_hosts.cis
      path        = "/"
      query       = ""
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = [var.dns_zone_name]
    }
  }

  tags = local.staff_web_tags

  depends_on = [aws_lb_listener_certificate.staff_web]
}

# AA-1060: the WordPress test site (test_wp_edge.tf). The block rule sits above the forward rule: no browser sign-in,
# no dashboard, no XML-RPC from outside (the mu-plugin of modules/environment test_wp/start.sh refuses sign-in too).
resource "aws_lb_listener_rule" "test_wp_block" {
  count = local.test_wp_on

  listener_arn = module.alb.https_listener_arn
  priority     = local.alb_https_rule_priorities.test_wp_block

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not available on this test site."
      status_code  = "403"
    }
  }

  condition {
    host_header {
      values = [local.test_wp_host]
    }
  }

  condition {
    path_pattern {
      values = local.test_wp_blocked_paths
    }
  }

  tags = local.test_wp_tags

  depends_on = [aws_lb_listener_certificate.staff_web]
}

resource "aws_lb_listener_rule" "test_wp" {
  count = local.test_wp_on

  listener_arn = module.alb.https_listener_arn
  priority     = local.alb_https_rule_priorities.test_wp

  action {
    type             = "forward"
    target_group_arn = module.environment.test_wp_target_group_arn
  }

  condition {
    host_header {
      values = [local.test_wp_host]
    }
  }

  tags = local.test_wp_tags

  depends_on = [aws_lb_listener_certificate.staff_web]
}
