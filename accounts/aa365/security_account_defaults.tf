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
#   5. NAT instance swap (S297 follow-up of 4): the first patch run (27/11/2026 13:47Z) ran dnf for 3 h 22 min on the
#      512 MB t4g.nano with no swap and was killed at the document's default step timeout (10,800 s; PatchLinux
#      TimedOut, response code 137, no patch state recorded). A second association runs a small Command document that
#      makes a persistent 1 GB /swapfile (fstab, nofail) if it is absent, at creation and every Sunday 15 minutes
#      before the patch run; the patch run now has an explicit 3,600 s step timeout. No instance change: user_data
#      and the instance type stay as they are (a NAT replacement cuts Dev egress). Runbook (manual run, read-back,
#      failure cases): docs/runbooks/nat-instance-patching.md.
#
# Cost: 0 USD. EBS default encryption, snapshot BPA, AWS Health events on EventBridge, State Manager associations and
# custom Command documents have no charge; the swapfile takes 1 GB of the NAT root volume already paid for; the
# us-east-1 forward is billed as custom events (1 USD per million; a handful a month); SNS e-mail stays in the free tier.
#
# Apply: the apply role needs the AA-1185 statements of cicd_sec.tf (EBS account settings, the SSM associations, the
# aa-ecosys-* Command documents). That
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
    # S297: explicit step timeout (the document default is 10,800 s; the first run thrashed that long without swap).
    StepTimeoutSeconds = tostring(local.nat_patch_timeout_seconds)
  }

  targets {
    key    = "InstanceIds"
    values = [module.vpc.nat_instance_id]
  }

  tags = merge(local.shared_tags, { App = "shared", Component = "network", Issue = "AA-1185" })
}

# ── 5. NAT instance swap (runs before the patch) ─────────────────────────────
# Values of this section: Terraform locals, reviewed in the PR (the Infra repo has no admin settings page; the apps'
# settings mechanism does not reach an SSM document).
locals {
  nat_swap_size_mb          = 1024 # 512 MB of RAM + 1 GB swap: dnf metadata and the patch run fit
  nat_swap_min_free_mb      = 512  # root volume space left free after the swapfile, or the step fails without one
  nat_swap_timeout_seconds  = 600  # the dd of 1 GB takes seconds on gp3
  nat_patch_timeout_seconds = 3600 # was 10,800 s by document default; with swap a run takes minutes

  # Idempotent: an active /swapfile is left alone; a file that does not activate is rebuilt; a new one is written as
  # /swapfile.new and renamed only after mkswap, so an interrupted run never leaves a half file under the real name.
  # SWAPFILE / FSTAB are overridable only for the offline test (tools/terraform/tests/test_aa1185_nat_swap.py).
  nat_swap_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    SWAPFILE="$${SWAPFILE:-/swapfile}"
    FSTAB="$${FSTAB:-/etc/fstab}"
    SIZE_MB=${local.nat_swap_size_mb}
    MIN_FREE_MB=${local.nat_swap_min_free_mb}
    swap_active() { swapon --show=NAME --noheadings | grep -x "$SWAPFILE" >/dev/null; }
    if swap_active; then
      echo "swap: $SWAPFILE already active"
    else
      if [ -f "$SWAPFILE" ] && ! swapon "$SWAPFILE" 2>/dev/null; then
        echo "swap: $SWAPFILE exists but does not activate, rebuilding it"
        rm -f "$SWAPFILE"
      fi
      if ! swap_active; then
        rm -f "$SWAPFILE.new"
        AVAIL_MB=$(df --output=avail -m "$(dirname "$SWAPFILE")" | tail -n 1 | tr -d ' ')
        if [ "$AVAIL_MB" -lt $((SIZE_MB + MIN_FREE_MB)) ]; then
          echo "swap: only $AVAIL_MB MB free, need $((SIZE_MB + MIN_FREE_MB)) MB; no swapfile made" >&2
          exit 1
        fi
        dd if=/dev/zero of="$SWAPFILE.new" bs=1M count="$SIZE_MB" status=none
        chmod 600 "$SWAPFILE.new"
        mkswap "$SWAPFILE.new" >/dev/null
        mv "$SWAPFILE.new" "$SWAPFILE"
        swapon "$SWAPFILE"
        echo "swap: $SWAPFILE created ($SIZE_MB MB) and active"
      fi
    fi
    if ! grep -E "^$SWAPFILE[[:space:]]" "$FSTAB" >/dev/null; then
      echo "$SWAPFILE none swap defaults,nofail 0 0" >> "$FSTAB"
      echo "swap: fstab entry added"
    fi
    swapon --show
    free -m
  EOT
}

resource "aws_ssm_document" "nat_swap" {
  name            = "aa-ecosys-${var.environment}-nat-swap"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Make a persistent swapfile on the NAT instance if it has none, before the weekly patch run. AA-1185."
    mainSteps = [{
      action       = "aws:runShellScript"
      name         = "EnsureSwapfile"
      precondition = { StringEquals = ["platformType", "Linux"] }
      inputs = {
        timeoutSeconds = tostring(local.nat_swap_timeout_seconds)
        runCommand     = split("\n", trimspace(local.nat_swap_script))
      }
    }]
  })

  tags = merge(local.shared_tags, { App = "shared", Component = "network", Issue = "AA-1185" })
}

resource "aws_ssm_association" "nat_swap" {
  name             = aws_ssm_document.nat_swap.name
  association_name = "aa-ecosys-${var.environment}-nat-swap"

  # Sunday 20:45 UTC, 15 minutes before nat_patch. It also runs once when created or when its target changes (a new NAT
  # instance gets its swap at once); the fstab entry keeps the swap across the patch reboot.
  schedule_expression         = "cron(45 20 ? * SUN *)"
  apply_only_at_cron_interval = false
  max_concurrency             = "1"
  max_errors                  = "0"
  compliance_severity         = "MEDIUM"

  targets {
    key    = "InstanceIds"
    values = [module.vpc.nat_instance_id]
  }

  tags = merge(local.shared_tags, { App = "shared", Component = "network", Issue = "AA-1185" })
}
