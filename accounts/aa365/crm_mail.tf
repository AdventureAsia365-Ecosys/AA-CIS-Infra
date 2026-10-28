# =============================================================================
# AA-945 (CRM-17, Module 5 e-mail) — the AA-Partner forward-in mailbox and the task-role grants behind it.
#
# Design: root docs/audits/2026-10-21-S246-crm-design-v3/design-v3.md §6.3 card CRM-17 and data lane §6.5 ("one SES
# receipt rule for the whole domain, per-agency addresses <slug>-<random>@in.<domain>; SES -> S3 under the ingest key
# with a 1-day lifecycle; job crm_mail_ingest re-encrypts under the tenant mail DEK, threads, deletes the raw copy"), as
# changed by errata S247 (ADR 0010 decision 9): SES is used for RECEIVING only here; traveller mail is sent from the
# agency's own mailbox (Gmail / Microsoft 365 / SMTP), never through SES.
#
#   agency mailbox --(auto-forward / BCC)--> <local_part>@crm-in.lumiguides.it.com
#     MX crm-in.lumiguides.it.com -> inbound-smtp.us-west-1.amazonaws.com
#     -> the region's ONLY active receipt rule set aa-cis-dev-e2e (e2e_mailbox.tf), rule aa-crm-dev-ingest, placed
#        explicitly AFTER e2e-cognito (recipients = the whole crm-in domain, spam/virus scan, TLS required)
#     -> S3 aa-crm-dev-ingest-<account>/raw/<SES message id>  (crm_storage.tf: SSE-KMS bucket default under the CRM
#        ingest key, every object expires after 1 day)
#     <- the AA-Partner task role (crm_ecs_task_mail below): list / read / delete raw/ (the MailIngestScan hook +
#        crm_mail_ingest), write / read / delete imports/ (the mbox / CSV history import, <= 25 MB, deleted after its job)
#
# Facts checked 25/10/2026 (read-only): describe-active-receipt-rule-set -> aa-cis-dev-e2e with one rule, e2e-cognito
# (recipients under e2e-mail. only); crm-in.lumiguides.it.com has no record. The sub-domain inherits SES verification
# from the apex identity lumiguides.it.com (ses.tf), as e2e-mail. does, so no new SES identity.
#
# Decisions:
#   - The rule JOINS the existing active set. Only one set is active per region: activating a second set would switch
#     off the CIS / Booking / CRM Cognito E2E mailbox. `after = e2e-cognito` pins the order; the two rules have disjoint
#     recipients (e2e-mail. vs crm-in.), so neither one's mail reaches the other's bucket.
#   - No `kms_key_arn` on the S3 action (SES client-side encryption): that needs the S3 Encryption Client to read, which
#     boto3 does not have. The bucket's default SSE-KMS under the ingest key keeps raw mail encrypted at rest for <= 1
#     day; the app re-encrypts each mail under the agency's mail DEK and deletes the object. SES therefore needs
#     kms:Decrypt next to GenerateDataKey* on the ingest key (SES developer guide, "Give SES permission to use your KMS
#     key": "an S3 bucket with server-side encryption enabled ... add kms:Decrypt"); crm_data.tf SesReceiptEncrypt adds
#     it, still bound to this account's aa-crm-<env>-* receipt rules (aws:SourceAccount + aws:SourceArn). The key
#     policy statement CrmRuntimeReadSesMail (the client-side context) stays, unused and harmless.
#   - The rule name aa-crm-dev-ingest matches crm_storage.tf crm_ses_rule_arns (bucket policy AllowSesPutFromCrmRules)
#     and the ingest key policy SesReceiptEncrypt; neither policy changes shape.
#   - The app polls raw/ once a minute (its worker hook MailIngestScan queues crm_mail_ingest only when objects exist)
#     instead of an SNS / S3 event: no new topic, queue or Lambda. An unknown or inactive address is deleted with a count-only log line and the
#     metric MailIngestDropped in the existing AA/Jobs/Crm namespace (no new PutMetricData grant).
#   - OAuth client of the agencies' send-as: one secret shell crm/<env>/mail-oauth (JSON {google_client_id,
#     google_client_secret, ms_client_id, ms_client_secret}; no secret_version here, the values are set out of band).
#     The task maps it as MAIL_OAUTH only with var.crm_mail_oauth_enabled: a task whose valueFrom secret has no value
#     fails to start (crm_sentry_enabled pattern). Until then Gmail / Microsoft 365 connect answers not_configured; SMTP
#     works without it.
#   - No IAM user for an SES-SMTP test sender: the CI apply boundary denies iam:CreateUser / CreateAccessKey
#     (cicd_split.tf DenyIdentityAndAccountAdmin) and SMTP credentials would be long-lived keys. The live SMTP check
#     uses a mailbox app password (human step) instead.
#
# CI: the apply role already has ses:*ReceiptRule* (cicd_split.tf SESReceiptRuleManage), Route 53 record changes, IAM
# role policies on aa-*-<env>-* roles, Secrets Manager under crm/* and KMS key policy updates of the CRM keys
# (cicd_crm.tf): no bootstrap MFA apply.
#
# Cost (us-west-1, est.): SES receiving $0.10 per 1,000 mails + $0.09 per 1,000 256-KB chunks (Dev: a few dozen test
# mails, ~$0.01/month); S3 ListObjectsV2 by the per-minute poll ~43,200 requests x $0.005 / 1,000 = ~$0.22/month (GET
# and DELETE of each mail ~$0); raw objects live <= 1 day (~$0); KMS requests within the free tier (Bucket Keys);
# secret crm/dev/mail-oauth $0.40/month; MX record and IAM $0. Total ~ $0.65/month.
#
# Runbook (checks after apply, the SSE-KMS fallback, poison objects, the OAuth secret steps):
# docs/runbooks/crm-mail-ingest.md.
# =============================================================================

variable "crm_ingest_subdomain" {
  description = "AA-945: label under dns_zone_name of the AA-Partner forward-in mail domain (design v3 lane §6.5 'in.<domain>'). Agencies forward to <local_part>@<label>.<zone>; the AA-Partner task gets the full domain as CRM_INGEST_DOMAIN."
  type        = string
  default     = "crm-in"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.crm_ingest_subdomain))
    error_message = "crm_ingest_subdomain must be one DNS label."
  }
}

variable "crm_mail_oauth_enabled" {
  description = "AA-945: map secret crm/<env>/mail-oauth (Google + Microsoft OAuth client of the agencies' send-as) into the AA-Partner task as MAIL_OAUTH. Turn on only AFTER the secret has a value: a task whose valueFrom secret has no value fails to start."
  type        = bool
  default     = false
}

locals {
  crm_ingest_domain   = "${var.crm_ingest_subdomain}.${var.dns_zone_name}"
  crm_ingest_rule     = "${local.crm_name_prefix}-ingest"
  crm_ingest_raw      = "raw/"
  crm_ingest_imports  = "imports/"
  crm_ingest_bucket   = aws_s3_bucket.crm["ingest"]
  crm_mail_tags       = merge(local.crm_tags, { Service = "crm", Issue = "AA-945" })
  crm_mail_oauth_name = "crm/${var.environment}/mail-oauth"
  # AA-979 clean-up: the agency host (the web's /connect/mail/callback). The Google (and later Microsoft) OAuth client
  # must list https://portal.<zone>/connect/mail/callback as a redirect URI BEFORE the API runs with this value.
  crm_mail_redirect    = "https://${local.crm_agency_host}"
  crm_mail_object_arns = ["${local.crm_ingest_bucket.arn}/${local.crm_ingest_raw}*", "${local.crm_ingest_bucket.arn}/${local.crm_ingest_imports}*"]

  # Task environment (AA-Partner api/app/settings.py; crm_app.tf concatenates it). Bucket and domain are not secrets.
  crm_mail_env = [
    { name = "CRM_INGEST_BUCKET", value = local.crm_ingest_bucket.bucket },
    { name = "CRM_INGEST_DOMAIN", value = local.crm_ingest_domain },
    { name = "MAIL_OAUTH_REDIRECT_BASE", value = local.crm_mail_redirect },
  ]
  crm_mail_secrets = var.crm_mail_oauth_enabled ? [
    { name = "MAIL_OAUTH", valueFrom = aws_secretsmanager_secret.crm_mail_oauth.arn },
  ] : []
}

# ── 1. DNS: MX for the forward-in domain ─────────────────────────────────────────────────────────
resource "aws_route53_record" "crm_ingest_mx" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.crm_ingest_domain
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

# ── 2. The receipt rule, in the region's one active set, after e2e-cognito ───────────────────────
resource "aws_ses_receipt_rule" "crm_ingest" {
  name          = local.crm_ingest_rule
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  after         = aws_ses_receipt_rule.e2e_cognito.name
  # A domain recipient matches every address of the domain; the app decides per local part (unknown = discarded).
  recipients   = [local.crm_ingest_domain]
  enabled      = true
  scan_enabled = true
  # Gmail and Microsoft 365 forward over TLS; a plaintext relay has no legitimate reason to deliver client mail here.
  tls_policy = "Require"

  s3_action {
    position          = 1
    bucket_name       = local.crm_ingest_bucket.id
    object_key_prefix = local.crm_ingest_raw
  }

  # SES writes a setup-notification object when the rule is created: the bucket policy (crm_storage.tf) and the key
  # policy (crm_data.tf, SesReceiptEncrypt with kms:Decrypt) must be in place first.
  depends_on = [aws_s3_bucket_policy.crm, aws_kms_key.crm_ingest]
}

# ── 3. Task role: the ingest bucket's raw/ and imports/ prefixes ─────────────────────────────────
resource "aws_iam_role_policy" "crm_ecs_task_mail" {
  name = "${local.crm_service}-mail"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The MailIngestScan hook lists raw/ (and the history import its own imports/<tenant>/<id> key).
        Sid      = "CrmIngestList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.crm_ingest_bucket.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.crm_ingest_raw}*", "${local.crm_ingest_imports}*"] }
        }
      },
      {
        # Read then delete each raw mail after it is re-encrypted under the agency's mail DEK; the 1-day lifecycle is
        # the backstop. No PutObject on raw/: only SES writes there.
        Sid      = "CrmIngestRawMail"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "${local.crm_ingest_bucket.arn}/${local.crm_ingest_raw}*"
      },
      {
        # The mbox / CSV history import: the upload is streamed here, read by its job, then deleted.
        Sid      = "CrmIngestImports"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${local.crm_ingest_bucket.arn}/${local.crm_ingest_imports}*"
      },
      {
        # The bucket default SSE-KMS (ingest key) through S3 only and bound to the ingest bucket; the key policy's
        # CrmRuntimeS3Objects allows the same for this role (both must allow).
        Sid      = "CrmIngestSseKms"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.crm_ingest.arn
        Condition = {
          "StringEquals" = { "kms:ViaService" = local.crm_s3_via_service }
          "ArnLike" = {
            "kms:EncryptionContext:aws:s3:arn" = [local.crm_ingest_bucket.arn, "${local.crm_ingest_bucket.arn}/*"]
          }
        }
      },
    ]
  })
}

# ── 4. OAuth client secret shell (values set out of band, never by Terraform) ────────────────────
resource "aws_secretsmanager_secret" "crm_mail_oauth" {
  name                    = local.crm_mail_oauth_name
  description             = "AA-945: AA's own OAuth clients for the agencies' send-as (JSON google_client_id, google_client_secret, ms_client_id, ms_client_secret); MAIL_OAUTH of the AA-Partner task once crm_mail_oauth_enabled. Value set out-of-band."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.crm_mail_tags
}

output "crm_mail_ingest" {
  description = "AA-945: where the AA-Partner forward-in mail lands (domain, rule, bucket prefix)."
  value = {
    domain = local.crm_ingest_domain
    rule   = local.crm_ingest_rule
    bucket = local.crm_ingest_bucket.id
    prefix = local.crm_ingest_raw
  }
}
