# =============================================================================
# AA-816 step I5 (S243) — SES inbound mailbox for the Cognito email-code E2E test.
#
# The WORKFORCE pool signs staff in with an email code. To run that sign-in in CI, the E2E staff
# user `e2e-cognito@adventure.asia` (a forwarder in the adventure.asia mail host panel, set by hand,
# D2 option a) forwards to e2e@e2e-mail.lumiguides.it.com. This file makes that address real:
#
#   MX e2e-mail.lumiguides.it.com -> inbound-smtp.us-west-1.amazonaws.com
#     -> active receipt rule set aa-cis-dev-e2e, rule e2e-cognito (only that recipient)
#     -> S3 aa-cis-dev-e2e-mail-<account>/inbound/<message id>   (objects expire after 1 day)
#     <- read-only role aa-cis-dev-e2e-mail-reader, assumed by AA-CIS-App GitHub Actions
#        (environment `e2e`, ref main) to pull the code out of the newest message.
#
# Facts checked 19/10/2026 (read-only):
#   - SES receiving answers in us-west-1 (inbound-smtp.us-west-1.amazonaws.com resolves;
#     list-receipt-rule-sets -> [], describe-active-receipt-rule-set -> none). Only ONE rule set can
#     be active per region; there is none today, so activating this one changes nothing else. A
#     future receiving use in this region must add its rule to THIS set, not a second set.
#   - No own SES identity for the sub-domain: receiving needs a verified domain, and sub-domains
#     inherit verification from the parent (SES dev guide, "Creating and verifying identities":
#     "Subdomains and email addresses inherit verification from the parent domain"). The apex
#     identity lumiguides.it.com (ses.tf) is verified (VerificationStatus SUCCESS).
#   - The apex MX is Zoho (dns.tf) and bounce. is the SES MAIL FROM (ses.tf): a separate label
#     keeps both untouched. `e2e-mail` was free in the zone.
#
# Security:
#   - The rule accepts mail for a fixed list of recipients only: the CIS staff E2E address, since AA-910
#     (S250) the Booking staff E2E address e2e-booking@ (WORKFORCE user in booking-admin only; the trigger
#     allow-map lambda_src/identity_triggers/workforce.py E2E_TEST_STAFF, root ADR 0006a A10) and, since
#     AA-935, the e2e test users of the synthetic AA-Partner agencies (tools/identity/crm_e2e_users.json,
#     e2e-test-crm-<agency>-<role>@; EXTERNAL-pool users, email-code sign-in to the CRM web on Dev).
#     Anything else to the sub-domain is bounced by SES (no matching rule). Their codes land under the
#     same prefix; the CIS reader role can read them too, which is acceptable for synthetic Dev agency
#     users (no real person, no real agency data). Spam/virus scan on; SES only tags the verdict, the reader must not
#     trust the message beyond pulling a 6-8 digit code from it.
#   - Messages hold one-time sign-in codes of a reviewer-role CIS staff user and (AA-910) of a booking-admin
#     staff user, whose codes the CIS reader role can read too (same prefix; accepted for Dev, S250).
#     1-day expiry, BPA, SSE-S3, TLS-only access, object reads denied to every principal except the reader role and the MFA
#     admin role. SES may only PutObject from this account's rule (aws:SourceAccount + SourceArn).
#   - The reader role cannot write or delete (read-only by design, S243); the 1-day lifecycle
#     cleans up. Its trust is the immutable AA-CIS-App subject + `environment:e2e` + ref main.
#
# CI: the apply role needs ses:*ReceiptRule* (cicd_split.tf, Sid SESReceiptRuleManage). That is a
# bootstrap grant: local MFA targeted apply of aws_iam_role_policy.tf_apply first, then Terraform
# Apply for the rest. S3 (AmazonS3FullAccess), Route 53 (Route53ZoneManage) and the role
# (IAMRoleManageStack + workload boundary) are already covered.
#
# Cost: SES receiving $0.10 per 1,000 mails + $0.09 per 1,000 256-KB chunks; a few test mails a
# month, each < 100 KB, kept 1 day in S3 -> well under $0.01/month. Route 53 record in the existing
# zone, IAM role and rule set: $0.
# =============================================================================

locals {
  e2e_mail_domain    = "e2e-mail.${var.dns_zone_name}"
  e2e_mail_recipient = "e2e@${local.e2e_mail_domain}"
  # AA-910 (S250): Booking staff admin E2E user; must equal workforce.py E2E_BOOKING_TEST_STAFF_EMAIL.
  e2e_mail_booking_recipient = "e2e-booking@${local.e2e_mail_domain}"
  # AA-935: e2e users of the synthetic CRM agencies (one source with tools/identity/crm_dev_identity.py).
  e2e_crm_users = jsondecode(file("${path.module}/../../tools/identity/crm_e2e_users.json")).users
  e2e_crm_recipients = [
    for u in local.e2e_crm_users : "e2e-test-crm-${u.agency}-${u.role}@${local.e2e_mail_domain}"
  ]
  e2e_mail_bucket       = "${local.name_prefix}-e2e-mail-${var.account_id}"
  e2e_mail_prefix       = "inbound/"
  e2e_mail_rule_set     = "${local.name_prefix}-e2e"
  e2e_mail_rule         = "e2e-cognito"
  e2e_mail_rule_arn     = "arn:aws:ses:${var.aws_region}:${var.account_id}:receipt-rule-set/${local.e2e_mail_rule_set}:receipt-rule/${local.e2e_mail_rule}"
  e2e_mail_reader_name  = "${local.name_prefix}-e2e-mail-reader"
  e2e_mail_reader_arn   = "arn:aws:iam::${var.account_id}:role/${local.e2e_mail_reader_name}"
  e2e_mail_tags         = merge(local.ecosys_tags, { App = "cis", Issue = "AA-816" })
  e2e_mail_reader_sub   = "${local.oidc_sub_cis_app}:environment:e2e"
  e2e_mail_object_reads = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAttributes"]
}

# ── 1. DNS: MX for the sub-domain ────────────────────────────────────────────
resource "aws_route53_record" "e2e_mail_mx" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.e2e_mail_domain
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

# ── 2. S3 bucket for received messages ───────────────────────────────────────
resource "aws_s3_bucket" "e2e_mail" {
  bucket        = local.e2e_mail_bucket
  force_destroy = true # only 1-day-old test mail; never blocks a destroy

  tags = local.e2e_mail_tags
}

resource "aws_s3_bucket_public_access_block" "e2e_mail" {
  bucket                  = aws_s3_bucket.e2e_mail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "e2e_mail" {
  bucket = aws_s3_bucket.e2e_mail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "e2e_mail" {
  bucket = aws_s3_bucket.e2e_mail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "e2e_mail" {
  bucket = aws_s3_bucket.e2e_mail.id

  rule {
    id     = "expire-e2e-mail-1d"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "e2e_mail_bucket" {
  # SES writes received messages, only from this account's e2e-cognito rule (confused-deputy guard).
  statement {
    sid       = "AllowSesPutFromE2eRule"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_prefix}*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.e2e_mail_rule_arn]
    }
  }

  # Message bodies hold sign-in codes: no other principal of the account reads them, whatever its
  # identity policy says (ECS task roles, the CI roles, ReadOnlyAccess). Bucket-level calls
  # (HeadBucket = s3:ListBucket, Get*Configuration) stay open so Terraform plan/apply can refresh.
  statement {
    sid       = "DenyObjectReadsExceptReaderAndAdmin"
    effect    = "Deny"
    actions   = local.e2e_mail_object_reads
    resources = ["${aws_s3_bucket.e2e_mail.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.e2e_mail_reader_arn, local.id_breakglass_admin_role_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.e2e_mail.arn, "${aws_s3_bucket.e2e_mail.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "e2e_mail" {
  bucket = aws_s3_bucket.e2e_mail.id
  policy = data.aws_iam_policy_document.e2e_mail_bucket.json

  # BPA first: a policy with a Service principal is not public, but keep the order deterministic.
  depends_on = [aws_s3_bucket_public_access_block.e2e_mail]
}

# ── 3. SES receipt rule set (active) + rule ──────────────────────────────────
resource "aws_ses_receipt_rule_set" "e2e" {
  rule_set_name = local.e2e_mail_rule_set

  # SESReceiptRuleManage (cicd_split.tf) must have propagated; the gate re-sleeps on every change
  # of the apply role's policy (observability.tf).
  depends_on = [time_sleep.wait_for_iam_propagation]
}

# One active set per region (there was none, 19/10/2026). Destroying this resource deactivates
# receiving for the whole region.
resource "aws_ses_active_receipt_rule_set" "e2e" {
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
}

resource "aws_ses_receipt_rule" "e2e_cognito" {
  name          = local.e2e_mail_rule
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  recipients    = concat([local.e2e_mail_recipient, local.e2e_mail_booking_recipient], local.e2e_crm_recipients)
  enabled       = true
  scan_enabled  = true
  # Require (S243 option B): the code mail now comes straight from Cognito/SES, which delivers over
  # TLS; there is no forwarder any more, so a plaintext relay has no legitimate reason to deliver here.
  tls_policy = "Require"

  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.e2e_mail.id
    object_key_prefix = local.e2e_mail_prefix
  }

  # SES writes a setup-notification object when the rule is created: the bucket policy must exist.
  depends_on = [aws_s3_bucket_policy.e2e_mail]
}

# ── 4. Read-only role for AA-CIS-App GitHub Actions (cognito-e2e.yml) ────────
resource "aws_iam_role" "e2e_mail_reader" {
  name                 = local.e2e_mail_reader_name
  description          = "AA-816 I5: AA-CIS-App Cognito E2E (environment e2e, main) reads the SES inbound mailbox"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Same form as aa-cis-dev-app-deploy (cicd_split.tf): immutable AA-CIS-App subject with the
        # `e2e` environment context, and the ref claim pins it to main (AA-866).
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # AA-936: plus AA-Partner's `e2e` environment (workflow E2E Dev reads the synthetic agency users' codes).
          "token.actions.githubusercontent.com:sub" = [
            local.e2e_mail_reader_sub,
            "repo:AdventureAsia365-Ecosys@276539096/AA-Partner@${local.crm_oidc_repo_id}:environment:e2e",
          ]
          "token.actions.githubusercontent.com:ref" = "refs/heads/main"
        }
      }
    }]
  })

  tags = local.e2e_mail_tags
}

resource "aws_iam_role_policy" "e2e_mail_reader" {
  name = "${local.e2e_mail_reader_name}-policy"
  role = aws_iam_role.e2e_mail_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListInboundPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.e2e_mail.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.e2e_mail_prefix}*"] }
        }
      },
      {
        Sid      = "ReadInboundObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_prefix}*"
      },
    ]
  })
}

output "e2e_mail_reader_role_arn" {
  description = "AA-816 I5: set as GitHub environment secret E2E_MAIL_ROLE_ARN (environment e2e) on AA-CIS-App."
  value       = aws_iam_role.e2e_mail_reader.arn
}

output "e2e_mailbox" {
  description = "AA-816 I5: where the Cognito E2E mail lands."
  value = {
    recipient         = local.e2e_mail_recipient
    booking_recipient = local.e2e_mail_booking_recipient
    crm_recipients    = local.e2e_crm_recipients
    bucket            = aws_s3_bucket.e2e_mail.id
    prefix            = local.e2e_mail_prefix
  }
}
