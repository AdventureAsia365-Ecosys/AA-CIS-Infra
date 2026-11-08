# =============================================================================
# AA-59 — WAF Module
# Rules: AWSManagedRulesCommonRuleSet + the TripPlanner web rules + VpcLinkInternalAllow + CloudFrontOriginAllow +
# RateLimit + GeoBlock (+ StaffWebRateLimit). Order: local.rule_priorities (S235 order; CloudFrontOriginAllow inserted
# by AA-931; the three TripPlanner web rules by AA-1038, S272)
# Imported from existing manually-created WAF: aa-cis-dev-waf
# Country list matches AWS state at import time; priority order changed in S235 (see below).
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  # AA-911: one anchored, case-insensitive regex for the staff hosts (Host header, optional :443). Empty list = no
  # staff rule and no scope-down on RateLimit1000 (the ACL as before AA-911).
  staff_host_regex = length(var.staff_web_hosts) > 0 ? "^(${join("|", [for h in var.staff_web_hosts : replace(lower(h), ".", "\\.")])})(:443)?$" : null

  # AA-1038 (S272 tech-lead decision, cost): the TripPlanner web rules live here instead of a CLOUDFRONT-scope web ACL
  # of their own. They need the origin secret: every one of them is scoped to "TripPlanner host AND came through our
  # CloudFront", so no other host and no request that skipped CloudFront is ever counted or challenged.
  tp            = var.tripplanner_web
  tp_on         = var.tripplanner_web != null && nonsensitive(var.origin_verify_header != null)
  tp_host_regex = local.tp_on ? "^${replace(lower(local.tp.host), ".", "\\.")}(:443)?$" : null

  # One regex per path set, so no rule nests a logical statement deeper than 3 levels (the provider schema refuses a
  # fourth: and > or > and > or failed the plan, S272; tools/terraform/tests/test_waf_statement_depth.py). Both run on
  # uri_path after local.tp.path_transformations, like the byte matches they replaced, and use no group, no
  # lookaround and no backreference (AWS WAF regex subset).
  #   planner: the old ENDS_WITH "/plan" OR CONTAINS "/plan/" (/plan, /{tenant}/plan and anything below them).
  #     PCRE's $ also matches before a final newline, so a decoded "/plan\n" is challenged too (more, never less).
  #   protected: the old CONTAINS of each protected path, unanchored, every regex metacharacter escaped.
  tp_planner_path_regex = "/plan/|/plan$"
  tp_protected_path_regex = local.tp_on ? join("|", [
    for p in local.tp.protected_paths : replace(p, "/([.^$*+?()\\[\\]{}|\\\\])/", "\\$1")
  ]) : null

  # Rule order (first terminating action wins). The numbers only order the rules; a rule that is off leaves a gap.
  #   1   CommonRuleSet first, for every caller (content inspection, S235).
  #   2-4 TripPlanner web (AA-1038): after the content rules, BEFORE both allow rules. CloudFrontOriginAllow would end
  #       the evaluation for every CloudFront request, and VpcLinkInternalAllow would if VPC-origin traffic were ever
  #       NATed to a VPC address (AA-931 notes: the spike allowed for both cases).
  #   5-9 the S235 / AA-931 / AA-911 rules in their old relative order (were 2-6 before AA-1038).
  rule_priorities = {
    common_rule_set         = 1
    tp_rate_per_ip          = 2
    tp_rate_model_paths     = 3
    tp_challenge_planner    = 4
    vpc_link_internal_allow = 5
    cloudfront_origin_allow = 6
    rate_limit              = 7
    geo_block               = 8
    staff_web_rate_limit    = 9
  }
}

# Optional ip_set for internal VPC Link traffic (AA-272) — only created when
# var.vpc_allow_cidr is set. Left null on the account-1 root, which still
# references this shared module post-decommission, so no ip_set/rule is
# created there.
resource "aws_wafv2_ip_set" "vpc_allow" {
  count = var.vpc_allow_cidr != null ? 1 : 0

  name               = "${local.name_prefix}-vpc-allow"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = [var.vpc_allow_cidr]

  tags = merge(var.tags, {
    Module = "waf"
    Issue  = "AA-272"
  })
}

resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name_prefix}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # AA-1038: the JSON body of the TripPlanner rate rules' 429 (only while those rules exist).
  dynamic "custom_response_body" {
    for_each = local.tp_on ? [1] : []
    content {
      key          = "rate_limited"
      content      = jsonencode({ error = "rate_limited" })
      content_type = "APPLICATION_JSON"
    }
  }

  # S235 Phase 0 (AA-678) — rule order. Rules are evaluated by priority and the first terminating
  # action wins, so ORDER IS THE FIX (numbers: local.rule_priorities):
  #
  #   1 AWSManagedRulesCommonRuleSet    content inspection, valid for every caller
  #   2 TripPlannerRateLimitPerIp       (AA-1038, only with var.tripplanner_web) TripPlanner host via CloudFront
  #   3 TripPlannerRateLimitModelPaths  (AA-1038) the protected paths of the TripPlanner host (model calls + send)
  #   4 TripPlannerChallengePlanner     (AA-1038) Challenge on the planner documents and the protected paths
  #   5 VpcLinkInternalAllow            (ALB only) VPC-link traffic stops here (was 2 before AA-1038)
  #   6 CloudFrontOriginAllow           (ALB only, AA-931) CloudFront VPC-origin traffic stops here (was 3)
  #   7 RateLimit1000                   per source IP (was 4)
  #   8 GeoBlockNonAllowed              per source IP (was 5)
  #   9 StaffWebRateLimit               (AA-911, only with var.staff_web_hosts) per client IP on the staff hosts (was 6)
  #
  # Before S235 the VPC allow rule was priority 0, so every request that came through API Gateway
  # (it reaches the ALB from the NLB's private IPs, i.e. inside the VPC CIDR) skipped ALL rules.
  # The allow rule cannot simply be removed while this ACL is on the ALB: there the source IP is
  # always an NLB private IP, so the rate rule would count all users as two IPs and the geo rule
  # would block every request (private IPs have no allowed country). Rate + geo are therefore
  # meaningful only where the real client IP is visible: the REST API stages (see the
  # rest_api_stage associations below). On a REST API stage the VPC allow rule never matches.

  # Rule 1 — AWS Managed Common Rule Set (moved ahead of the VPC allow rule, S235).
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = local.rule_priorities.common_rule_set

    # Observe mode (S235 rollout): with var.common_rules_count_only = true the WHOLE group runs in
    # COUNT (matches are logged and labelled, nothing is blocked). Set it to false (enforce,
    # override_action none) only after reviewing the counted matches; the per-sub-rule overrides
    # below then still keep their sub-rules in COUNT.
    override_action {
      dynamic "count" {
        for_each = var.common_rules_count_only ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.common_rules_count_only ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Sub-rules kept in COUNT once the group is enforced. These requests never reached the
        # managed rules before S235; the defaults are known to break this API (SizeRestrictions_BODY
        # blocks any body > 8 KB: Excel/file uploads and large admin JSON; CrossSiteScripting_BODY
        # matches HTML in tour content edits). S239 (AA-806) pre-flip test: GenericLFI_BODY matches any
        # content save whose first 8 KB holds a relative "../" link (HTML href/src or markdown), on CIS
        # admin + tenant edits and Booking notes/terms, so it is in COUNT too. Review the WAF log
        # (label awswaf:managed:aws:core-rule-set:*) and tighten.
        dynamic "rule_action_override" {
          for_each = var.managed_rule_count_overrides

          content {
            name = rule_action_override.value

            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rules 2-4 — AA-1038: the TripPlanner web (tripplanner.<zone> on CloudFront -> VPC origin -> NLB -> ALB :80). They
  # replaced the CLOUDFRONT-scope web ACL aa-tripplanner-<env>-web (S272 tech-lead decision: its fixed 5 USD a month,
  # and AWS WAF gives the JavaScript integration URL only to a web ACL with a paid Bot Control / ATP / ACFP group, so
  # the planner never had one). Every rule is scoped to the TripPlanner host AND the exact origin secret, so no other
  # host (CIS, Booking, CRM, portal, staff, the API Gateway path) is counted or challenged.
  #
  # Viewer address: at the ALB the source IP is a CloudFront address, not the viewer. The two rate rules key on
  # var.tripplanner_web.viewer_ip_header, which the distribution's viewer-request function writes from the viewer's
  # own address on every request, over any value the viewer sent (accounts/aa365 tripplanner_web_edge.tf). Not
  # X-Forwarded-For: AWS WAF takes its FIRST address, which the viewer writes. The rules see only the requests that
  # reach the ALB: CloudFront serves cached build chunks and photos without them.
  #
  # Every path match runs var.tripplanner_web.path_transformations (URL_DECODE, NORMALIZE_PATH): the app resolves a
  # dot-segment spelling such as /api/browse/%2e/search to the model route, so the rules must see the same path.
  # A protected path matches unanchored (CONTAINS semantics, local.tp_protected_path_regex), never EXACTLY:
  # NORMALIZE_PATH keeps a back-reference at the start of the path (AWS: "not at the beginning of the input"), so
  # /%2e%2e/api/trip/send stays /../api/trip/send for WAF while the app (WHATWG new URL) resolves it to /api/trip/send; a resolver may also drop a raw #fragment suffix. Matching
  # more is harmless: the rules are scoped to the TripPlanner host and the origin secret, and the app answers any other
  # path 404 (AA-TripPlanner-Web lib/edgeGate.ts compares the resolved path exactly). Review S272.
  dynamic "rule" {
    for_each = local.tp_on ? [1] : []

    content {
      name     = "TripPlannerRateLimitPerIp"
      priority = local.rule_priorities.tp_rate_per_ip

      action {
        block {
          custom_response {
            response_code            = 429
            custom_response_body_key = "rate_limited"
          }
        }
      }

      statement {
        rate_based_statement {
          limit              = local.tp.rate_limit
          aggregate_key_type = "FORWARDED_IP"

          forwarded_ip_config {
            header_name       = local.tp.viewer_ip_header
            fallback_behavior = "MATCH"
          }

          scope_down_statement {
            and_statement {
              statement {
                regex_match_statement {
                  regex_string = local.tp_host_regex
                  field_to_match {
                    single_header {
                      name = "host"
                    }
                  }
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
              statement {
                byte_match_statement {
                  search_string         = var.origin_verify_header.value
                  positional_constraint = "EXACTLY"
                  field_to_match {
                    single_header {
                      name = lower(var.origin_verify_header.name)
                    }
                  }
                  text_transformation {
                    priority = 0
                    type     = "NONE"
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "TripPlannerRateLimitPerIp"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = local.tp_on ? [1] : []

    content {
      name     = "TripPlannerRateLimitModelPaths"
      priority = local.rule_priorities.tp_rate_model_paths

      action {
        block {
          custom_response {
            response_code            = 429
            custom_response_body_key = "rate_limited"
          }
        }
      }

      statement {
        rate_based_statement {
          limit              = local.tp.model_rate_limit
          aggregate_key_type = "FORWARDED_IP"

          forwarded_ip_config {
            header_name       = local.tp.viewer_ip_header
            fallback_behavior = "MATCH"
          }

          scope_down_statement {
            and_statement {
              statement {
                regex_match_statement {
                  regex_string = local.tp_host_regex
                  field_to_match {
                    single_header {
                      name = "host"
                    }
                  }
                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
              statement {
                byte_match_statement {
                  search_string         = var.origin_verify_header.value
                  positional_constraint = "EXACTLY"
                  field_to_match {
                    single_header {
                      name = lower(var.origin_verify_header.name)
                    }
                  }
                  text_transformation {
                    priority = 0
                    type     = "NONE"
                  }
                }
              }
              # The protected paths: CONTAINS any of them (one regex, see local.tp_protected_path_regex).
              statement {
                regex_match_statement {
                  regex_string = local.tp_protected_path_regex
                  field_to_match {
                    uri_path {}
                  }
                  dynamic "text_transformation" {
                    for_each = local.tp.path_transformations
                    content {
                      priority = text_transformation.key
                      type     = text_transformation.value
                    }
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "TripPlannerRateLimitModelPaths"
        sampled_requests_enabled   = true
      }
    }
  }

  # Challenge (silent JavaScript proof, no puzzle) on a document navigation of a planner page (GET with
  # sec-fetch-dest: document on /plan, /{tenant}/plan and below) and on the protected paths (the two model calls and
  # Send to advisor, var.tripplanner_web.protected_paths). The app opens the planner
  # with a full page load from every in-site link (AA-TripPlanner-Web), so this rule hands the browser its
  # aws-waf-token before the planner calls a protected path; a script without the token gets HTTP 202 +
  # x-amzn-waf-action: challenge and never reaches the app. Catalog pages never see an interstitial. The token lifetime
  # is this rule's own (challenge_config below), so the ACL default stays as it is for every other host.
  dynamic "rule" {
    for_each = local.tp_on ? [1] : []

    content {
      name     = "TripPlannerChallengePlanner"
      priority = local.rule_priorities.tp_challenge_planner

      action {
        challenge {}
      }

      challenge_config {
        immunity_time_property {
          immunity_time = local.tp.challenge_immunity_s
        }
      }

      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.tp_host_regex
              field_to_match {
                single_header {
                  name = "host"
                }
              }
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
          statement {
            byte_match_statement {
              search_string         = var.origin_verify_header.value
              positional_constraint = "EXACTLY"
              field_to_match {
                single_header {
                  name = lower(var.origin_verify_header.name)
                }
              }
              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
          statement {
            or_statement {
              # A document navigation of a planner page.
              statement {
                and_statement {
                  statement {
                    byte_match_statement {
                      search_string         = "GET"
                      positional_constraint = "EXACTLY"
                      field_to_match {
                        method {}
                      }
                      text_transformation {
                        priority = 0
                        type     = "NONE"
                      }
                    }
                  }
                  statement {
                    byte_match_statement {
                      search_string         = "document"
                      positional_constraint = "EXACTLY"
                      field_to_match {
                        single_header {
                          name = "sec-fetch-dest"
                        }
                      }
                      text_transformation {
                        priority = 0
                        type     = "LOWERCASE"
                      }
                    }
                  }
                  # The planner pages only (/plan, /{tenant}/plan and below; local.tp_planner_path_regex).
                  statement {
                    regex_match_statement {
                      regex_string = local.tp_planner_path_regex
                      field_to_match {
                        uri_path {}
                      }
                      dynamic "text_transformation" {
                        for_each = local.tp.path_transformations
                        content {
                          priority = text_transformation.key
                          type     = text_transformation.value
                        }
                      }
                    }
                  }
                }
              }
              # The protected paths: no valid token, no model call and no lead (CONTAINS, see the note above rule 2).
              statement {
                regex_match_statement {
                  regex_string = local.tp_protected_path_regex
                  field_to_match {
                    uri_path {}
                  }
                  dynamic "text_transformation" {
                    for_each = local.tp.path_transformations
                    content {
                      priority = text_transformation.key
                      type     = text_transformation.value
                    }
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "TripPlannerChallengePlanner"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rule 5 — Allow internal VPC Link traffic (proxied requests + NLB health checks) past the
  # IP-based rules below. Optional, count-gated via var.vpc_allow_cidr (AA-272).
  dynamic "rule" {
    for_each = var.vpc_allow_cidr != null ? [1] : []

    content {
      name     = "VpcLinkInternalAllow"
      priority = local.rule_priorities.vpc_link_internal_allow

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.vpc_allow[0].arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "VpcLinkInternalAllow"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rule 6 — AA-931 (CRM-03): allow CloudFront VPC-origin traffic past the IP-based rules below.
  # An NLB with an `alb` target group preserves the source IP, so these requests reach the ALB from
  # CloudFront's origin-facing addresses: the geo rule would judge the EDGE's country (a viewer
  # outside the allowed list could be blocked) and the rate rule would count a whole edge as one
  # client. CloudFront adds the secret header to every origin request; the exact value is required
  # (a guessed or empty header falls through to rate + geo, and the ALB then answers 403 anyway).
  # Content inspection (rule 1) has already run. Optional, gated via var.origin_verify_header.
  dynamic "rule" {
    # nonsensitive: only whether the header is set decides the rule count, never its value.
    for_each = nonsensitive(var.origin_verify_header != null) ? [1] : []

    content {
      name     = "CloudFrontOriginAllow"
      priority = local.rule_priorities.cloudfront_origin_allow

      action {
        allow {}
      }

      statement {
        byte_match_statement {
          search_string         = var.origin_verify_header.value
          positional_constraint = "EXACTLY"

          field_to_match {
            single_header {
              name = lower(var.origin_verify_header.name)
            }
          }

          text_transformation {
            priority = 0
            type     = "NONE"
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "CloudFrontOriginAllow"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rule 7 — Rate limit (per real client IP on the REST API stages, and on the ALB :443 for any host that is not a
  # staff host). AA-911: the staff hosts (browsers on the ALB :443 directly) are scoped out and counted by rule 9 with
  # their own limit: a Next.js page with its static chunks, RSC navigations and prefetches is many requests.
  rule {
    name     = "RateLimit1000"
    priority = local.rule_priorities.rate_limit

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"

        dynamic "scope_down_statement" {
          for_each = local.staff_host_regex != null ? [1] : []
          content {
            not_statement {
              statement {
                regex_match_statement {
                  regex_string = local.staff_host_regex

                  field_to_match {
                    single_header {
                      name = "host"
                    }
                  }

                  text_transformation {
                    priority = 0
                    type     = "LOWERCASE"
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit1000"
      sampled_requests_enabled   = true
    }
  }

  # Rule 8 — Geo Block (allow major markets only)
  # Country list matches AWS state at import — do not change without checking console
  rule {
    name     = "GeoBlockNonAllowed"
    priority = local.rule_priorities.geo_block

    action {
      block {}
    }

    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = var.geo_allowed_countries
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoBlockNonAllowed"
      sampled_requests_enabled   = true
    }
  }

  # Rule 9 — AA-911: rate limit of the staff hosts (CIS admin, Booking admin on the ALB :443), per real client IP.
  # After the geo rule, which applies to the staff hosts as to everyone.
  dynamic "rule" {
    for_each = local.staff_host_regex != null ? [1] : []

    content {
      name     = "StaffWebRateLimit"
      priority = local.rule_priorities.staff_web_rate_limit

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.staff_web_rate_limit
          aggregate_key_type = "IP"

          scope_down_statement {
            regex_match_statement {
              regex_string = local.staff_host_regex

              field_to_match {
                single_header {
                  name = "host"
                }
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "StaffWebRateLimit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Module = "waf"
    Issue  = "AA-59"
  })
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# S235 Phase 0 (AA-678) — the same REGIONAL web ACL on REST API stages, where WAF sees the real
# client IP (so rate + geo work). Keys are static labels ("cis", "booking") so for_each is known at
# plan time even when the stage ARNs are not. Empty map (default) = no association.
# Note: HTTP APIs (API Gateway v2, e.g. TripPlanner) cannot be associated with WAF.
resource "aws_wafv2_web_acl_association" "rest_api_stage" {
  for_each = var.rest_api_stage_arns

  resource_arn = each.value
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# CloudWatch Log Group for WAF
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name_prefix}"
  retention_in_days = var.log_retention_days # AA-872 (S241 D-09): 365 by default; Dev 30 since S263 (AA-1025)
  tags              = var.tags
}

# AA-806 (S239): WAF logs every request header. Without redaction the log group kept, in plain text,
# the tenant/staff bearer JWTs (Authorization) and the static BFF -> API service secret
# (X-Admin-Secret), readable by any principal with logs read in the account (e.g. the PR plan role's
# ReadOnlyAccess). Header names are matched case-insensitively.
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  # S263 (AA-1025): with log_only_acted_on, keep the records whose action is BLOCK / COUNT (a COUNT-mode rule matched,
  # e.g. the observe-mode managed rules) / CAPTCHA / CHALLENGE / EXCLUDED_AS_COUNT and drop plain allowed traffic.
  dynamic "logging_filter" {
    for_each = var.log_only_acted_on ? [1] : []

    content {
      default_behavior = "DROP"

      filter {
        behavior    = "KEEP"
        requirement = "MEETS_ANY"

        dynamic "condition" {
          for_each = ["BLOCK", "COUNT", "CAPTCHA", "CHALLENGE", "EXCLUDED_AS_COUNT"]

          content {
            action_condition {
              action = condition.value
            }
          }
        }
      }
    }
  }

  dynamic "redacted_fields" {
    for_each = var.log_redacted_headers

    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }
}
