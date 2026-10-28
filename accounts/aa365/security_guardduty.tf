# =============================================================================
# AA-873 PR 3 of 3 (S255) — GuardDuty, behind var.guardduty_enabled (default false).
#
# GuardDuty is the only paid part of the AA-873 baseline (root audit docs/audits/2026-10-28-S255-finops-security/ §7,
# decisions D3 step 3 and D4). This PR ships the code switched OFF: merging it creates nothing. The orchestrator turns
# it on (var.guardduty_enabled = true in a one-line follow-up PR) once Nghiệp has accepted the monthly cost.
#
# Quote for our volume (us-west-1 price list via the Pricing API, read 28/10/2026), per month:
#   Foundational (always on with a detector):
#     CloudTrail management events ~2.0-2.4 M x 4.40 USD/M     = 9-10.5
#     VPC flow + DNS logs          ~3-6 GB   x 1.10 USD/GB     = 3.3-6.6
#   RDS_LOGIN_EVENTS  ON   2 vCPU (db.t4g.small) x 1.34        = 2.68
#   S3_DATA_EVENTS    ON   ~0.25 M events x 1.20 USD/M         = 0.30 (CRM documents bucket, D4)
#   RUNTIME_MONITORING OFF (Fargate 2 vCPU + NAT 2 vCPU x 1.85 = 7.40, and it needs a sidecar memory budget)
#   EBS_MALWARE_PROTECTION, EKS_AUDIT_LOGS, LAMBDA_NETWORK_LOGS OFF (no EKS, no EBS workload; Lambda logs later)
#   => ~15-20 USD/month. The first 30 days are a free trial: read `aws guardduty get-usage-statistics` after ~7 days
#      and record actual vs quote in Linear AA-873 (Done-when).
# Lower: the NAT instance's ECS agent loop (RegisterContainerInstance ~3.6k events/day) goes away with the NAT AMI fix
# (modules/vpc, separate PR + SSM command), ~0.5 USD/month of management events.
#
# Every optional feature is managed explicitly: a detector created through the API turns several of them on by
# default (S3, EBS malware, RDS, Lambda), and those would bill from day 31 if left to the default.
#
# Findings of severity >= 4 (medium, high, critical) -> the alerts SNS topic through rule aa-sec-<env>-guardduty-finding
# (topic policy statement AllowSecurityEventBridgeRules, AA-873 PR 1). Low findings stay in the console.
#
# Apply: the GuardDuty and service-linked-role grants are in cicd_sec.tf (bootstrap, AA-873 PR 1): PR 1's local MFA
# apply must be done first. With the flag on, expected CI plan: 1 detector + 6 features + 1 rule + 1 target = 9 add.
# Turning it off later (flag false) deletes the detector and its findings.
# =============================================================================

variable "guardduty_enabled" {
  description = "AA-873: create the GuardDuty detector (paid, ~15-20 USD/month at Dev volume; root audit S255 §7)"
  type        = bool
  default     = false
}

locals {
  # Feature name -> enabled. RUNTIME_MONITORING covers EKS/ECS/EC2 runtime; EKS_RUNTIME_MONITORING is not managed
  # next to it (the provider documents drift when both are set).
  guardduty_features = {
    RDS_LOGIN_EVENTS       = true
    S3_DATA_EVENTS         = true
    EBS_MALWARE_PROTECTION = false
    EKS_AUDIT_LOGS         = false
    LAMBDA_NETWORK_LOGS    = false
    RUNTIME_MONITORING     = false
  }
}

resource "aws_guardduty_detector" "main" {
  count                        = var.guardduty_enabled ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = local.sec_tags
}

resource "aws_guardduty_detector_feature" "this" {
  for_each    = var.guardduty_enabled ? local.guardduty_features : {}
  detector_id = aws_guardduty_detector.main[0].id
  name        = each.key
  status      = each.value ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_rule" "sec_guardduty_finding" {
  count       = var.guardduty_enabled ? 1 : 0
  name        = "${local.sec_prefix}-guardduty-finding"
  description = "GuardDuty finding of severity 4 or more (medium and up). AA-873.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
  tags = local.sec_tags
}

resource "aws_cloudwatch_event_target" "sec_guardduty_finding" {
  count     = var.guardduty_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.sec_guardduty_finding[0].name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      sev    = "$.detail.severity"
      type   = "$.detail.type"
      title  = "$.detail.title"
      id     = "$.detail.id"
      region = "$.detail.region"
    }
    input_template = "\"[aa-sec] guardduty severity <sev> in <region>: <type> - <title> (finding <id>). Triage in the GuardDuty console; archive with a reason if benign (AA-873).${local.runbook_suffix.incident}\""
  }
}
