# =============================================================================
# AA-1185 (S296; S295 security audit SA-36 and the Well-Architected review, free controls approved by the tech lead on
# 27/11/2026) — account defaults and the NAT instance patching.
#
#   1. EBS encryption by default (this region): every NEW volume and snapshot copy is encrypted with the AWS managed
#      key aws/ebs. Existing volumes do not change (the NAT root volume is encrypted at its next deliberate
#      replacement, modules/vpc). Live 27/11/2026: off.
#   2. EBS snapshot Block Public Access, block-all: no snapshot of this region can be shared publicly. Live 27/11/2026:
#      unblocked. No snapshot is public today (none is meant to be).
#   3. AWS Health -> EventBridge -> the alerts topic: issues, scheduled changes (RDS maintenance, EC2 retirement, ACM
#      renewals that need action) and account notifications for this account. Regional events arrive on this
#      region's bus; global ones and those of us-east-1 (the CloudFront certificates) through the us-east-1 forwarder
#      of security_baseline.tf (its pattern gains source aws.health). Ticket severity: a person reads it in working
#      hours (alert_severity.tf).
#   4. NAT instance patching (SA-36): an SSM State Manager association runs AWS-RunPatchBaseline (Install, reboot
#      only if a patch needs it) on the NAT instance once a week, in the quietest hour (Sunday 21:00 UTC = Monday
#      04:00 in Vietnam). A reboot stops private egress for about a minute; ip forwarding (/etc/sysctl.conf) and the
#      MASQUERADE rule (iptables-services, saved) come back at boot. apply_only_at_cron_interval: creating the
#      association does not patch at once; the first run is a watched, manual one (PR live steps).
#
# Cost: 0 USD. EBS default encryption, snapshot BPA, AWS Health events on EventBridge and State Manager associations
# have no charge; the us-east-1 forward is billed as custom events (1 USD per million; a handful a month); SNS e-mail
# stays in the free tier.
#
# Apply: the apply role needs the AA-1185 statements of cicd_sec.tf (EBS account settings, the SSM association). That
# policy is a bootstrap object: apply it locally with the MFA admin profile first (targeted apply of
# aws_iam_policy.tf_apply_sec), then let CI apply the rest.
# =============================================================================

# ── 1 + 2. EBS account defaults ──────────────────────────────────────────────
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_snapshot_block_public_access" "this" {
  state = "block-all-sharing"
}

# ── 3. AWS Health events ─────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "sec_aws_health" {
  name        = "${local.sec_prefix}-aws-health"
  description = "AWS Health issue, scheduled change or account notification for this account (local, or forwarded from us-east-1). AA-1185.${local.runbook_suffix.incident}"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
    detail = {
      eventTypeCategory = ["issue", "scheduledChange", "accountNotification"]
    }
  })
  # Ticket: AWS announces these hours or days ahead (maintenance, retirement, renewal); nobody is woken up. Locked:
  # an EventBridge rule cannot be muted.
  tags = merge(local.sec_tags, { Issue = "AA-1185" }, local.alert_tags.ticket_locked)
}

resource "aws_cloudwatch_event_target" "sec_aws_health" {
  rule      = aws_cloudwatch_event_rule.sec_aws_health.name
  target_id = "alerts-sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      service  = "$.detail.service"
      type     = "$.detail.eventTypeCode"
      category = "$.detail.eventTypeCategory"
      region   = "$.region"
      start    = "$.detail.startTime"
      status   = "$.detail.statusCode"
    }
    input_template = "\"[aa-sec] aws_health: <service> <type> (<category>, <status>) in <region>, starting <start>. Read the event in the AWS Health Dashboard (Your account health) and act before the start time if it names a resource of this account.${local.runbook_suffix.incident}\""
  }
}

# ── 4. NAT instance patching ─────────────────────────────────────────────────
resource "aws_ssm_association" "nat_patch" {
  name             = "AWS-RunPatchBaseline"
  association_name = "aa-ecosys-${var.environment}-nat-patch"

  # Sunday 21:00 UTC (Monday 04:00 ICT): no wave, no staff on Dev at that hour.
  schedule_expression         = "cron(0 21 ? * SUN *)"
  apply_only_at_cron_interval = true
  max_concurrency             = "1"
  max_errors                  = "0"
  compliance_severity         = "HIGH"

  parameters = {
    Operation    = "Install"
    RebootOption = "RebootIfNeeded"
  }

  targets {
    key    = "InstanceIds"
    values = [module.vpc.nat_instance_id]
  }

  tags = merge(local.shared_tags, { App = "shared", Component = "network", Issue = "AA-1185" })
}
