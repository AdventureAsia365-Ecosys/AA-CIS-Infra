# =============================================================================
# AA-59 — WAF Module
# Rules: AWSManagedRulesCommonRuleSet + VpcLinkInternalAllow + RateLimit + GeoBlock (S235 order)
# Imported from existing manually-created WAF: aa-cis-dev-waf
# Country list matches AWS state at import time; priority order changed in S235 (see below).
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
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

  # S235 Phase 0 (AA-678) — rule order. Rules are evaluated by priority and the first terminating
  # action wins, so ORDER IS THE FIX:
  #
  #   1 AWSManagedRulesCommonRuleSet  content inspection, valid for every caller
  #   2 VpcLinkInternalAllow          (ALB only) VPC-link traffic stops here
  #   3 RateLimit1000                 per source IP
  #   4 GeoBlockNonAllowed            per source IP
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
    priority = 1

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
        # matches HTML in tour content edits). Review the WAF log (label
        # awswaf:managed:aws:core-rule-set:*) after a week and tighten.
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

  # Rule 2 — Allow internal VPC Link traffic (proxied requests + NLB health checks) past the
  # IP-based rules below. Optional, count-gated via var.vpc_allow_cidr (AA-272).
  dynamic "rule" {
    for_each = var.vpc_allow_cidr != null ? [1] : []

    content {
      name     = "VpcLinkInternalAllow"
      priority = 2

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

  # Rule 3 — Rate limit (per real client IP on the REST API stages)
  rule {
    name     = "RateLimit1000"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit1000"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4 — Geo Block (allow major markets only)
  # Country list matches AWS state at import — do not change without checking console
  rule {
    name     = "GeoBlockNonAllowed"
    priority = 4

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
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}
