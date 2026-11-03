# =============================================================================
# AA-945 (CRM-17) — the two shared-platform pieces of the AA-Partner forward-in mailbox: the MX record in the account's
# zone and the SES receipt rule in the region's one active receipt rule set (e2e_mailbox.tf owns the set and the rule
# order: e2e-cognito -> aa-crm-<env>-ingest -> e2e-cognito-admin).
#
# AA-1004 slice 2 (S266) moved the rest of crm_mail.tf (variables, task-role grant, OAuth secret shell, the task env)
# into modules/environment/crm_mail.tf; these two stay in the account root with the zone and the rule set they sit
# in. Design, decisions, cost and runbook: the header of modules/environment/crm_mail.tf.
#
# module.environment.crm_ingest_receipt carries the domain, rule name, bucket and prefix. Its bucket value depends on
# the CRM bucket policy and the ingest KMS key (output depends_on): SES writes a setup-notification object when the
# rule is created, so both must be in place first (was depends_on = [aws_s3_bucket_policy.crm, aws_kms_key.crm_ingest]).
# =============================================================================

# ── 1. DNS: MX for the forward-in domain ─────────────────────────────────────────────────────────
resource "aws_route53_record" "crm_ingest_mx" {
  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = module.environment.crm_ingest_receipt.domain
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

# ── 2. The receipt rule, in the region's one active set, after e2e-cognito ───────────────────────
resource "aws_ses_receipt_rule" "crm_ingest" {
  name          = module.environment.crm_ingest_receipt.rule
  rule_set_name = aws_ses_receipt_rule_set.e2e.rule_set_name
  after         = aws_ses_receipt_rule.e2e_cognito.name
  # A domain recipient matches every address of the domain; the app decides per local part (unknown = discarded).
  recipients   = [module.environment.crm_ingest_receipt.domain]
  enabled      = true
  scan_enabled = true
  # Gmail and Microsoft 365 forward over TLS; a plaintext relay has no legitimate reason to deliver client mail here.
  tls_policy = "Require"

  s3_action {
    position          = 1
    bucket_name       = module.environment.crm_ingest_receipt.bucket
    object_key_prefix = module.environment.crm_ingest_receipt.prefix
  }
}
