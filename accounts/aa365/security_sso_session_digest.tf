# =============================================================================
# AA-873 (S263, tech lead ask) — a SECOND e-mail after every Identity Center administrator session: what it did.
#
# security_sso_signin.tf e-mails when a session on an administrator permission set (local.sec_sso_admin_permission_sets)
# STARTS. This file adds the follow-up: EventBridge Scheduler (hourly) -> Lambda aa-sec-<env>-admin-session-digest ->
# one e-mail per session on the same alerts topic, once the session is over (credentials expired, or no call for
# var.sec_admin_digest_idle_minutes). The full rule is in the handler docstring
# (lambda_src/sec_admin_session_digest/handler.py; tests in lambda_src/sec_admin_session_digest_tests/).
#
# How the function finds a session and its calls (read-only, CloudTrail Event history, 90 days, free):
#   - AssumeRoleWithSAML on an AWSReservedSSO_<set>_* role, <set> an alerted permission set, looked up in us-east-1
#     (Identity Center calls the global STS endpoint; all 10 sessions of the last 90 days landed there), in this
#     region and in the activity regions (regional STS endpoints), over the last var.sec_admin_digest_lookback_hours.
#   - The calls of that session: LookupEvents by user name (the role session name) in var.sec_admin_digest_activity_regions
#     (default: the organization region SCP allow-list, accounts/management var.allowed_regions; us-east-1 also holds
#     the global services: IAM, STS, Organizations, CloudFront, Route 53), plus by the session's access key when the
#     user-name lookup finds none of its CLI calls. A call counts when its identity is the same permission-set role.
#     Calls in any other region (the SCP allows them only for the services it exempts) are not read; the mail says so.
#   - The window is read in 1 h slices, oldest first, with the run time checked before every page: a long session is
#     never cut at its start (LookupEvents pages newest first); when time runs short the mail covers the slices read
#     and the next hourly run sends the rest as a continued digest.
#
# The e-mail: session name masked to the user's local part, permission set, start / end, source IPs (last octet
# masked), counts per service, every DELETE then every other WRITE call (time, service:eventName, resource NAME,
# errorCode), then read-only calls by count. The handler masks every line: no account id, ARN or full e-mail address.
# The same text is logged, one JSON line per digest, so the log group shows the mail shape (365 days, security log).
#
# State (no duplicate mail): one JSON object, s3://<bronze>/sec-digest/admin-sessions.json: CloudTrail eventID of each
# reported session -> start, expiry, reported-through time, closed flag. No user name, IP or key. Written only after a
# digest is sent (a few times a month), pruned after lookback + 1 day. An S3 object in the existing bronze bucket
# rather than a DynamoDB table: no new resource, no new CI apply grant (the apply role has no dynamodb:CreateTable),
# and the bucket is already versioned, encrypted and TLS-only.
#
# Preview (the live check, read-only): invoke with {"preview": true, "since": "<ISO>", "until": "<ISO>"}: the digests
# of the sessions started in that window are built, logged and returned; nothing is published, no state is read or
# written. tools/terraform/sec_alert_check.py --digest-preview runs it.
#
# Cost: ~0 USD/month. 730 invocations/month of a few seconds at 256 MB (Lambda free tier), Scheduler free tier,
# LookupEvents free (management events), a handful of S3 GET/PUT, SNS e-mail free tier, logs a few MB; the Errors
# alarm is the only billed item (0.10 USD/month, like every alarm on the topic).
#
# Apply: CI (role aa-sec-<env>-* matches aa-*-<env>-* with the workload boundary; Lambda, logs, alarm and the schedule in
# the module.eventbridge group are already in the apply role's grants, same as rds_snapshot_expiry.tf). No bootstrap.
# =============================================================================

variable "sec_admin_digest_schedule_expression" {
  description = "AA-873 — how often the admin session digest looks for ended Identity Center administrator sessions"
  type        = string
  default     = "rate(1 hour)"
}

variable "sec_admin_digest_activity_regions" {
  description = "AA-873 — regions whose CloudTrail Event history the digest reads for a session's calls: the organization region SCP allow-list (accounts/management var.allowed_regions; us-east-1 holds the global services)"
  type        = list(string)
  # Keep equal to accounts/management var.allowed_regions (tools/terraform/tests/test_sec_admin_digest.py checks it).
  default = ["us-east-1", "us-west-1", "us-west-2"]

  validation {
    condition     = contains(var.sec_admin_digest_activity_regions, "us-east-1")
    error_message = "sec_admin_digest_activity_regions must include us-east-1 (global service events land there)."
  }
}

variable "sec_admin_digest_lookback_hours" {
  description = "AA-873 — how far back the digest looks for administrator sessions (> 12 h, the longest session)"
  type        = number
  default     = 36

  validation {
    condition     = var.sec_admin_digest_lookback_hours >= 13 && var.sec_admin_digest_lookback_hours <= 24 * 80
    error_message = "sec_admin_digest_lookback_hours must be between 13 and 1920 (CloudTrail keeps 90 days)."
  }
}

variable "sec_admin_digest_idle_minutes" {
  description = "AA-873 — a session with no call for this many minutes counts as over (later calls send a continued digest)"
  type        = number
  default     = 60

  validation {
    condition     = var.sec_admin_digest_idle_minutes >= 15
    error_message = "sec_admin_digest_idle_minutes must be at least 15 (CloudTrail delivery lag)."
  }
}

locals {
  sec_digest_fn_name   = "${local.sec_prefix}-admin-session-digest"
  sec_digest_state_key = "sec-digest/admin-sessions.json"
  sec_digest_tags      = merge(local.sec_tags, { Issue = "AA-873" })
  # AssumeRoleWithSAML lands in us-east-1 (global STS) or in a regional STS endpoint (this region, an activity region).
  sec_digest_saml_regions = distinct(concat(["us-east-1", var.aws_region], var.sec_admin_digest_activity_regions))
}

# ── Package the zero-dependency handler ──────────────────────────────────────
data "archive_file" "sec_admin_session_digest" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/sec_admin_session_digest"
  output_path = "${path.module}/lambda_src/sec_admin_session_digest.zip"
  # Same two guards as dfs_balance.tf (S240 bytecode drift, AA-806 file-mode drift).
  excludes         = ["__pycache__", "__pycache__/**", "**/*.pyc"]
  output_file_mode = "0666"
}

# ── Lambda execution role ────────────────────────────────────────────────────
data "aws_iam_policy_document" "sec_admin_session_digest_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sec_admin_session_digest_exec" {
  name                 = "${local.sec_digest_fn_name}-exec"
  description          = "AA-873: reads CloudTrail Event history, mails the admin session digest"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.sec_admin_session_digest_assume.json
  tags                 = local.sec_digest_tags
}

resource "aws_iam_role_policy" "sec_admin_session_digest_perms" {
  name = "${local.sec_digest_fn_name}-perms"
  role = aws_iam_role.sec_admin_session_digest_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sec_admin_session_digest.arn}:log-stream:*"
      },
      {
        # LookupEvents has no resource-level permission (Service Authorization Reference): "*" is the only form.
        Sid      = "ReadEventHistory"
        Effect   = "Allow"
        Action   = ["cloudtrail:LookupEvents"]
        Resource = "*"
      },
      {
        Sid      = "PublishDigest"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid      = "ReadWriteState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${module.s3.bronze_bucket_arn}/${local.sec_digest_state_key}"
      },
      {
        # Without ListBucket a missing object answers 403 instead of 404 (first run).
        Sid       = "ListStateKey"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = module.s3.bronze_bucket_arn
        Condition = { StringEquals = { "s3:prefix" = [local.sec_digest_state_key] } }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sec_admin_session_digest" {
  name              = "/aws/lambda/${local.sec_digest_fn_name}"
  retention_in_days = 365 # AA-872 (S241 D-09): security/audit logs 365 days
  tags              = local.sec_digest_tags
}

# ── Lambda function ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "sec_admin_session_digest" {
  function_name = local.sec_digest_fn_name
  description   = "AA-873: e-mail what each Identity Center administrator session did, once it is over"
  role          = aws_iam_role.sec_admin_session_digest_exec.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  # LookupEvents allows 2 calls/s per region and 50 rows per call: a session of a local terraform plan (a few thousand
  # read calls) takes about a minute per region. The handler starts no session group under 90 s left and stops
  # reading under 30 s left (checked before every page); the next hourly run carries on from the last complete slice.
  timeout     = 600
  memory_size = 256

  filename         = data.archive_file.sec_admin_session_digest.output_path
  source_code_hash = data.archive_file.sec_admin_session_digest.output_base64sha256

  environment {
    variables = {
      ADMIN_PERMISSION_SETS = join(",", sort(values(local.sec_sso_admin_permission_sets)))
      SAML_REGIONS          = join(",", local.sec_digest_saml_regions)
      ACTIVITY_REGIONS      = join(",", var.sec_admin_digest_activity_regions)
      LOOKBACK_HOURS        = tostring(var.sec_admin_digest_lookback_hours)
      IDLE_MINUTES          = tostring(var.sec_admin_digest_idle_minutes)
      DELIVERY_LAG_MINUTES  = "15"
      MAX_PAGES             = "100"
      ALERT_TOPIC_ARN       = aws_sns_topic.alerts.arn
      STATE_BUCKET          = module.s3.bronze_bucket_name
      STATE_KEY             = local.sec_digest_state_key
      ENV_NAME              = var.environment
      RUNBOOK_URL           = local.runbook_url.incident
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.sec_admin_session_digest,
    aws_iam_role_policy.sec_admin_session_digest_perms,
  ]

  tags = merge(local.sec_digest_tags, { Function = "admin-session-digest" })
}

# A failed run sends nothing and writes no state for the sessions it did not finish; the next hourly run picks them up,
# so Lambda's own async retries add nothing (and could mail twice if a publish succeeded before the error).
resource "aws_lambda_function_event_invoke_config" "sec_admin_session_digest" {
  function_name                = aws_lambda_function.sec_admin_session_digest.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 3600
}

# Event alarm: ALARM e-mail only (S263 alert diet, AA-1025: Lambda errors stay in CloudWatch, without the OK mail).
resource "aws_cloudwatch_metric_alarm" "sec_admin_session_digest_errors" {
  alarm_name          = "${local.sec_digest_fn_name}-errors"
  alarm_description   = "AA-873: the Identity Center admin session digest Lambda failed, so an administrator session may have no activity e-mail yet. Check its log group; the next hourly run retries.${local.runbook_suffix.incident}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.sec_admin_session_digest.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = local.sec_digest_tags
}

# ── EventBridge Scheduler → Lambda (dedicated invoke role) ───────────────────
data "aws_iam_policy_document" "sec_admin_session_digest_scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "sec_admin_session_digest_scheduler" {
  name                 = "${local.sec_digest_fn_name}-scheduler"
  description          = "AA-873: EventBridge Scheduler invokes the admin session digest Lambda"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.sec_admin_session_digest_scheduler_assume.json
  tags                 = local.sec_digest_tags
}

resource "aws_iam_role_policy" "sec_admin_session_digest_scheduler_invoke" {
  name = "invoke-admin-session-digest-lambda"
  role = aws_iam_role.sec_admin_session_digest_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.sec_admin_session_digest.arn
    }]
  })
}

resource "aws_scheduler_schedule" "sec_admin_session_digest" {
  name        = "${local.sec_digest_fn_name}-hourly"
  description = "AA-873 — hourly digest of ended Identity Center administrator sessions"
  # The CI role's scheduler grants are scoped to the module.eventbridge group (see dfs_balance.tf).
  group_name = module.eventbridge.schedule_group_name

  schedule_expression          = var.sec_admin_digest_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  target {
    arn      = aws_lambda_function.sec_admin_session_digest.arn
    role_arn = aws_iam_role.sec_admin_session_digest_scheduler.arn
    input    = jsonencode({ source = "aa-873-hourly" })

    # Delivery retries only (throttled / failed Invoke). A function error is not retried (invoke config above).
    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
