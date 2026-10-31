# =============================================================================
# AA-816 step I5 (S243) — SES inbound mailbox for the Cognito email-code E2E test.
#
# The WORKFORCE pool signs staff in with an email code. To run that sign-in in CI, the E2E staff
# user `e2e-cognito@adventure.asia` (a forwarder in the adventure.asia mail host panel, set by hand,
# D2 option a) forwards to e2e@e2e-mail.lumiguides.it.com. This file makes that address real:
#
#   MX e2e-mail.lumiguides.it.com -> inbound-smtp.us-west-1.amazonaws.com
#     -> active receipt rule set aa-cis-dev-e2e, rule e2e-cognito (only the listed recipients)
#     -> S3 aa-cis-dev-e2e-mail-<account>/inbound/<message id>   (objects expire after 1 day)
#     <- read-only role aa-cis-dev-e2e-mail-reader, assumed by AA-CIS-App and AA-Partner GitHub Actions
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
#     allow-map lambda_src/identity_triggers/workforce.py E2E_TEST_STAFF, root ADR 0006a A10, A10a) and, since
#     AA-935, the e2e test users of the synthetic AA-Partner agencies (tools/identity/crm_e2e_users.json,
#     e2e-test-crm-<agency>-<role>@; EXTERNAL-pool users, email-code sign-in to the CRM web on Dev), and,
#     since AA-908, three synthetic travellers e2e-test-traveller@ / -2@ / -3@ (EXTERNAL pool,
#     TripPlanner sign-up and email-code sign-in on Dev; -3 is a never-signed-up address for the first-session
#     email_verified check), and, since AA-979 (S252), two Content studio invitees e2e-test-studio-viewer@ /
#     -editor@ (crm_e2e_users.json studio_invitees; partner-pool accounts created by the invitation claim, deleted by
#     crm_dev_identity.py invitee-reset --invitee studio-<role>; synthetic CIS tenants only, ADR 0006a A10b-1).
#     Anything else to the sub-domain is bounced by SES (no matching rule). Their codes land under the
#     same prefix; the CIS reader role can read them too, which is acceptable for synthetic Dev agency
#     users (no real person, no real agency data). Spam/virus scan on; SES only tags the verdict, the reader must not
#     trust the message beyond pulling a 6-8 digit code from it.
#   - Messages hold one-time sign-in codes of a reviewer-role CIS staff user and (AA-910) of a booking-admin
#     staff user, whose codes the CIS reader role can read too (same prefix; accepted for Dev, S250).
#     1-day expiry, BPA, SSE-S3, TLS-only access, object reads denied to every principal except the reader role and the MFA
#     admin role. SES may only PutObject from this account's rule (aws:SourceAccount + SourceArn).
#   - The reader role cannot write or delete (read-only by design, S243); the 1-day lifecycle
#     cleans up. Its trust is the immutable AA-CIS-App and AA-Partner (AA-936) subjects + `environment:e2e` + ref main.
#   - Exposure (AA-910, root ADR 0006a A10a): a booking-admin code gives full Booking write admin on the production
#     client; AA-Booking refuses that user's writes (403 e2e_read_only), so a leaked code yields admin reads only.
#   - A10b (AA-816, S252, root ADR 0006a A10b): the Dev-only CIS admin E2E address e2e-cis-admin@ (WORKFORCE user in
#     cis-admin only; trigger map workforce.py E2E_DEV_ONLY_TEST_STAFF, switched on by E2E_DEV_ONLY_STAFF_ENABLED,
#     identity.tf) has its OWN rule e2e-cognito-admin (dev only, count) writing to its OWN prefix inbound-admin/. It
#     is never a recipient of e2e-cognito (its codes must never land in inbound/). SES PutObject statements pair
#     rule ARN <-> prefix, so neither rule can write into the other's prefix. DenyAdminPrefixReadsExceptMfaAdmin
#     refuses object reads under inbound-admin/ to every principal except the MFA admin role, the reader role
#     included whatever its identity policy says (and that policy is scoped to inbound/*, which does not match
#     inbound-admin/...). The statement has no count: harmless while the prefix is empty, and it protects the prefix
#     name on every environment. The 1-day lifecycle (filter {}) covers the prefix too.
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
  e2e_crm_file  = jsondecode(file("${path.module}/../../tools/identity/crm_e2e_users.json"))
  e2e_crm_users = local.e2e_crm_file.users
  e2e_crm_recipients = [
    for u in local.e2e_crm_users : "e2e-test-crm-${u.agency}-${u.role}@${local.e2e_mail_domain}"
  ]
  # AA-979 (S252, root ADR 0006a A10b-1): the Content studio invitees of the phase 2 re-enrolment E2E (viewer, editor;
  # a CIS tenant member, no CRM agency). Same file, key studio_invitees; partner-pool accounts made by the claim.
  e2e_studio_invitee_recipients = [
    for u in local.e2e_crm_file.studio_invitees : "e2e-test-studio-${u.role}@${local.e2e_mail_domain}"
  ]
  # AA-908: synthetic travellers (EXTERNAL pool, tripplanner client, native email sign-up) for the
  # TripPlanner sign-in / My Trips check: one owns the trip, the other must see an empty list and a 404; the third
  # is kept unregistered for the fresh sign-up check (email_verified in the first session, TP #149).
  e2e_traveller_recipients = [
    for n in ["", "-2", "-3"] : "e2e-test-traveller${n}@${local.e2e_mail_domain}"
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

  # A10b (AA-816, S252): Dev-only CIS admin E2E user; must equal workforce.py E2E_CIS_ADMIN_TEST_STAFF_EMAIL. Own rule
  # and prefix (never added to e2e-cognito's recipients), readable only by the MFA admin role.
  e2e_admin_enabled        = var.environment == "dev"
  e2e_mail_admin_recipient = "e2e-cis-admin@${local.e2e_mail_domain}"
  # A10c (AA-1019, S262): the Dev-only AA-Partner staff E2E user (crm-ops + crm-support); must equal workforce.py
  # E2E_CRM_STAFF_TEST_STAFF_EMAIL. Same rule and prefix as A10b (MFA admin reads only), never on e2e-cognito.
  e2e_mail_crm_staff_recipient = "e2e-crm-staff@${local.e2e_mail_domain}"
  e2e_mail_admin_prefix        = "inbound-admin/"
  e2e_mail_admin_rule          = "e2e-cognito-admin"
  e2e_mail_admin_rule_arn      = "arn:aws:ses:${var.aws_region}:${var.account_id}:receipt-rule-set/${local.e2e_mail_rule_set}:receipt-rule/${local.e2e_mail_admin_rule}"
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

  # A10b (AA-816, S252): SES writes the CIS admin E2E mail under inbound-admin/ only from the e2e-cognito-admin rule
  # (dev only, like the rule). Paired rule ARN <-> prefix: e2e-cognito cannot write here, this rule cannot write inbound/.
  dynamic "statement" {
    for_each = local.e2e_admin_enabled ? [1] : []
    content {
      sid       = "AllowSesPutFromE2eAdminRule"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_admin_prefix}*"]

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
        values   = [local.e2e_mail_admin_rule_arn]
      }
    }
  }

  # A10b: CIS admin sign-in codes. Object reads under inbound-admin/ are denied to every principal except the MFA admin
  # role, the reader role included even if its identity policy is ever widened. No count on purpose (see header).
  statement {
    sid       = "DenyAdminPrefixReadsExceptMfaAdmin"
    effect    = "Deny"
    actions   = local.e2e_mail_object_reads
    resources = ["${aws_s3_bucket.e2e_mail.arn}/${local.e2e_mail_admin_prefix}*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.id_breakglass_admin_role_arn]
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
# receiving for the whole region. AA-945: the set also holds the AA-Partner forward-in rule aa-crm-dev-ingest
# (crm_mail.tf, recipients crm-in.<zone>, placed after e2e-cognito).
resource "aws_ses_active_receipt_rule_set" "e2e" {
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
}

resource "aws_ses_receipt_rule" "e2e_cognito" {
  name          = local.e2e_mail_rule
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  recipients    = concat([local.e2e_mail_recipient, local.e2e_mail_booking_recipient], local.e2e_crm_recipients, local.e2e_traveller_recipients, local.e2e_studio_invitee_recipients)
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

# A10b (AA-816, S252): the Dev-only CIS admin E2E address, its own rule and prefix. Appended at the END of the active
# set (after aa-crm-dev-ingest): inserting it after e2e-cognito would move aa-crm-dev-ingest, whose own
# `after = e2e-cognito` would then plan a perpetual diff. Recipients are disjoint from both other rules, so the order
# has no functional effect.
resource "aws_ses_receipt_rule" "e2e_cognito_admin" {
  count         = local.e2e_admin_enabled ? 1 : 0
  name          = local.e2e_mail_admin_rule
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  after         = aws_ses_receipt_rule.crm_ingest.name
  recipients    = [local.e2e_mail_admin_recipient, local.e2e_mail_crm_staff_recipient]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.e2e_mail.id
    object_key_prefix = local.e2e_mail_admin_prefix
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

# A10b (AA-816, S252): scoped to inbound/* on purpose. The CIS admin E2E prefix inbound-admin/ is out of scope (the
# string "inbound/" does not match "inbound-admin/..."), and the bucket policy denies it to this role anyway
# (DenyAdminPrefixReadsExceptMfaAdmin). Never widen this to the bucket or to "inbound*".
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
    # AA-908: read by the agent (MFA admin role) during the TripPlanner sign-in check; no CI reader yet.
    traveller_recipients = local.e2e_traveller_recipients
    bucket               = aws_s3_bucket.e2e_mail.id
    prefix               = local.e2e_mail_prefix
    # A10b (AA-816, S252): dev only (null elsewhere); read by the agent with the MFA admin role.
    admin_recipient = local.e2e_admin_enabled ? local.e2e_mail_admin_recipient : null
    admin_prefix    = local.e2e_admin_enabled ? local.e2e_mail_admin_prefix : null
  }
}
