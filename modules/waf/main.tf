# =============================================================================
# AA-59 — WAF Module
# Rules: RateLimit + GeoBlock + AWSManagedRulesCommonRuleSet
# Imported from existing manually-created WAF: aa-cis-dev-waf
# Priority order and country list match AWS state at import time.
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Optional ip_set for internal VPC Link traffic (AA-272) — only created when
# var.vpc_allow_cidr is set. Left null on the account-1 root, which still
# references this shared module since account-1's compute/network root was
# torn down (2026-07-09, AA-271) — so no ip_set/rule is created there.
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

  # Rule 0 — Allow internal VPC Link traffic (health checks + proxied
  # requests) to bypass GeoBlock/RateLimit. Optional, count-gated via
  # var.vpc_allow_cidr (AA-272).
  dynamic "rule" {
    for_each = var.vpc_allow_cidr != null ? [1] : []

    content {
      name     = "VpcLinkInternalAllow"
      priority = 0

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

  # Rule 1 — Rate limit
  rule {
    name     = "RateLimit1000"
    priority = 1

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

  # Rule 2 — Geo Block (allow major markets only)
  # Country list matches AWS state at import — do not change without checking console
  rule {
    name     = "GeoBlockNonAllowed"
    priority = 2

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

  # Rule 3 — AWS Managed Common Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
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
