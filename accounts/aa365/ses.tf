# =============================================================================
# AA-811 (S237) — SES transactional email on acc2 (us-west-1), shared by the ecosystem.
#
# ADR 0006 decision 10 + open item 5, S237 decision D5:
#   - domain identity = the apex lumiguides.it.com, sender no-reply@lumiguides.it.com (Dev);
#   - Easy DKIM (3 CNAMEs) + a custom MAIL FROM sub-domain (bounce.lumiguides.it.com, own MX + SPF)
#     so SPF aligns with the From domain without touching the apex SPF that Zoho mail uses;
#   - DMARC p=none on the apex (monitor only; Zoho DKIM "zmail" and SES DKIM both align);
#   - one configuration set per mail stream (ADR 0006: WORKFORCE vs EXTERNAL separated, so abuse of
#     the public traveller sign-up cannot hide staff mail problems) + one for app transactional mail;
#   - bounce/complaint events -> SNS topic (consumer: app suppression, AA-811 scope 3), and account
#     reputation alarms -> the existing alerts topic.
#
# Every DNS record lives in the Route 53 zone (dns.tf). Verification (DKIM SUCCESS, MAIL FROM
# SUCCESS) only completes after Nghiep switches the nameservers at Namecheap to that zone.
#
# Out of Terraform: the SES production-access request (sandbox exit, console / support case) and the
# app send helpers (AA-Booking staff inquiry e-mail first, AA-811 S238; Cognito / CIS later) in the app repos.
# =============================================================================

locals {
  ses_identity_arn    = "arn:aws:ses:${var.aws_region}:${var.account_id}:identity/${aws_sesv2_email_identity.lumiguides.email_identity}"
  ses_mail_from       = "${var.ses_mail_from_subdomain}.${var.dns_zone_name}"
  ses_config_set_name = "aa-email-${var.environment}"

  # workforce / external: Cognito user pools (AA-703, PR #105 identity_ses_configuration_set_*).
  # transactional: app mail (Booking quotes/OTP, TripPlanner advisor notifications, CIS).
  ses_streams = toset(["workforce", "external", "transactional"])

  ses_tags = merge(local.ecosys_tags, { App = "shared", Issue = "AA-811" })

  ses_dmarc = join("; ", compact([
    "v=DMARC1",
    "p=none",
    "adkim=r",
    "aspf=r",
    var.ses_dmarc_rua_email == "" ? "" : "rua=mailto:${var.ses_dmarc_rua_email}",
  ]))
}

# -----------------------------------------------------------------------------
# Configuration sets
# -----------------------------------------------------------------------------
resource "aws_sesv2_configuration_set" "stream" {
  for_each = local.ses_streams

  configuration_set_name = "${local.ses_config_set_name}-${each.key}"

  # Per-configuration-set reputation metrics (Reputation.BounceRate / ComplaintRate with the
  # configuration set dimension) next to the account-level ones the alarms below use.
  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  # Explicit (the account-level list is also on by default for new accounts): never resend to an
  # address that bounced hard or complained.
  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }

  tags = local.ses_tags
}

# Bounce / complaint / reject events. No subscription yet: the app send helpers subscribe when they
# implement suppression in their own tables (AA-811 scope 3). The rate alarms below cover alerting.
resource "aws_sns_topic" "ses_feedback" {
  name = "aa-email-${var.environment}-feedback"
  tags = local.ses_tags
}

data "aws_iam_policy_document" "ses_feedback_topic" {
  statement {
    sid       = "AllowSesEventPublishing"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.ses_feedback.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "ses_feedback" {
  arn    = aws_sns_topic.ses_feedback.arn
  policy = data.aws_iam_policy_document.ses_feedback_topic.json
}

resource "aws_sesv2_configuration_set_event_destination" "feedback" {
  for_each = aws_sesv2_configuration_set.stream

  configuration_set_name = each.value.configuration_set_name
  event_destination_name = "feedback-sns"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE", "COMPLAINT", "REJECT"]

    sns_destination {
      topic_arn = aws_sns_topic.ses_feedback.arn
    }
  }

  depends_on = [aws_sns_topic_policy.ses_feedback]
}

# -----------------------------------------------------------------------------
# Domain identity: Easy DKIM + custom MAIL FROM
# -----------------------------------------------------------------------------
resource "aws_sesv2_email_identity" "lumiguides" {
  email_identity = var.dns_zone_name

  # Mail sent without an explicit configuration set (app helpers) still gets events + metrics.
  configuration_set_name = aws_sesv2_configuration_set.stream["transactional"].configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = local.ses_tags
}

resource "aws_sesv2_email_identity_mail_from_attributes" "lumiguides" {
  email_identity = aws_sesv2_email_identity.lumiguides.email_identity

  mail_from_domain = local.ses_mail_from
  # If the MAIL FROM MX is ever missing, send with amazonses.com as MAIL FROM (SPF then aligns
  # nothing, DKIM still does) instead of rejecting the message.
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

# Easy DKIM always returns exactly 3 tokens; count (not for_each) because the tokens are only known
# after the identity is created.
resource "aws_route53_record" "ses_dkim" {
  count = 3

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = "${aws_sesv2_email_identity.lumiguides.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.lumiguides.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_mx" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.ses_mail_from
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${var.aws_region}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.ses_mail_from
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = "_dmarc.${var.dns_zone_name}"
  type    = "TXT"
  ttl     = 1800
  records = [local.ses_dmarc]
}

# -----------------------------------------------------------------------------
# Send permission for the app runtimes: only as var.ses_from_address, only through the
# transactional configuration set (not the Cognito streams). Standalone inline policies, not in
# modules/ecs, so they do not collide with the AA-806 step 4 boundary change on the same roles.
#
# Resource = every identity of this account, not only the apex: while the account is in the SES
# sandbox, SES also authorizes the request against each verified RECIPIENT identity
# (identity/<staff inbox>), so an apex-only grant is AccessDenied for the sandbox smoke test and
# for Cognito-adjacent test inboxes. The ses:FromAddress condition is what pins the sender; it is
# evaluated on every resource, so the wider resource list adds no new From address.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ses_send" {
  statement {
    sid     = "SesSendAsNoReply"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [
      "arn:aws:ses:${var.aws_region}:${var.account_id}:identity/*",
      aws_sesv2_configuration_set.stream["transactional"].arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.ses_from_address]
    }
  }
}

# CIS api + worker (both run with the module.ecs task role).
resource "aws_iam_role_policy" "cis_ecs_task_ses_send" {
  name   = "aa-cis-${var.environment}-ecs-ses-send"
  role   = module.ecs.task_role_name
  policy = data.aws_iam_policy_document.ses_send.json
}

resource "aws_iam_role_policy" "booking_ecs_task_ses_send" {
  name   = "${local.bk_name_prefix}-ecs-ses-send"
  role   = aws_iam_role.booking_ecs_task.id
  policy = data.aws_iam_policy_document.ses_send.json
}

# Shared by the browse and assembly Lambdas. Unused since S238 (AA-811): AA-Booking sends the staff
# inquiry e-mail, TripPlanner notify.py only logs. Kept for a future traveller e-mail from TripPlanner.
resource "aws_iam_role_policy" "tripplanner_lambda_ses_send" {
  name   = "${local.tp_name_prefix}-lambda-ses-send"
  role   = aws_iam_role.tripplanner_lambda_exec.id
  policy = data.aws_iam_policy_document.ses_send.json
}

# -----------------------------------------------------------------------------
# Alarms (account-level reputation; 2 standard alarms, about $0.20/month). AWS puts an account
# under review at a 5% bounce rate / 0.1% complaint rate and may pause sending at 10% / 0.5%; a
# pause would also stop the Cognito email codes. Alarm at half the review thresholds.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  alarm_name          = "aa-email-${var.environment}-bounce-rate"
  alarm_description   = "SES account bounce rate above 2.5% (AWS review at 5%, pause at 10%). Check the aa-email-${var.environment}-feedback events and who is sending to bad addresses (sign-up abuse?). AA-811."
  namespace           = "AWS/SES"
  metric_name         = "Reputation.BounceRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.025
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.ses_tags
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  alarm_name          = "aa-email-${var.environment}-complaint-rate"
  alarm_description   = "SES account complaint rate above 0.05% (AWS review at 0.1%, pause at 0.5%). AA-811."
  namespace           = "AWS/SES"
  metric_name         = "Reputation.ComplaintRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.0005
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.ses_tags
}

# -----------------------------------------------------------------------------
# Outputs (AA-703 PR #105 tfvars: identity_ses_identity_arn, identity_ses_from_address,
# identity_ses_configuration_set_workforce / _external; app env: SES from address + config set)
# -----------------------------------------------------------------------------
output "ses_identity_arn" {
  value = local.ses_identity_arn
}

output "ses_from_address" {
  value = var.ses_from_address
}

output "ses_configuration_sets" {
  value = { for k, v in aws_sesv2_configuration_set.stream : k => v.configuration_set_name }
}

output "ses_feedback_topic_arn" {
  value = aws_sns_topic.ses_feedback.arn
}

# The SES records as plain name/type/value, for the post-switch check (dig) or, if the NS switch is
# postponed, to enter them by hand at Namecheap.
output "ses_dns_records" {
  value = concat(
    [for r in aws_route53_record.ses_dkim : { name = r.name, type = r.type, value = one(r.records) }],
    [for r in [aws_route53_record.ses_mail_from_mx, aws_route53_record.ses_mail_from_spf, aws_route53_record.dmarc] : { name = r.name, type = r.type, value = one(r.records) }],
  )
}
