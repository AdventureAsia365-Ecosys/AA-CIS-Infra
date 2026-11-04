# =============================================================================
# AA-1004 slice 2 (S266) — CRM outputs the account root reads (besides the per-file outputs in crm_*.tf, which the
# root re-exports under the same names). Each one replaces a direct reference the root had before the move; names,
# ids and ARNs only, no secrets.
# =============================================================================

# The CRM naming contract and per-service values the root files still use (cicd_crm.tf CI grants, the edge files,
# app_security_groups.tf, identity_partner.tf, identity_alerts.tf, e2e_mailbox.tf). One definition, here.
output "crm_name_prefix" {
  value = local.crm_name_prefix
}

output "crm_tags" {
  value = local.crm_tags
}

output "crm_port" {
  value = local.crm_port
}

output "crm_app_tags" {
  value = local.crm_app_tags
}

output "crm_web_port" {
  value = local.crm_web_port
}

output "crm_web_tags" {
  value = local.crm_web_tags
}

output "crm_oidc_repo_id" {
  description = "AA-Partner repo id in the GitHub OIDC subjects ('*' while crm_github_repo_id is empty); e2e_mailbox.tf trusts the e2e environment with it."
  value       = local.crm_oidc_repo_id
}

# Target groups the root's listener rules forward to (alb_rules.tf crm_api, crm_edge.tf, crm_client_edge.tf,
# crm_agency_edge.tf).
output "crm_api_target_group_arn" {
  value = aws_lb_target_group.crm_api.arn
}

output "crm_web_target_group_arn" {
  value = aws_lb_target_group.crm_web.arn
}

output "crm_ecs_task_role_id" {
  description = "AA-Partner API task role name/id: identity_partner.tf attaches the partner-pool and SES send grants to it."
  value       = aws_iam_role.crm_ecs_task.id
}

output "crm_ecs_task_role_arn" {
  description = "AA-Partner API task role ARN (identity_partner.tf partner-pool alarm pattern)."
  value       = aws_iam_role.crm_ecs_task.arn
}

output "crm_db_secret_arn" {
  description = "Secret crm/<env>/database-url (db_migrator.tf: the migrator reads it for set-password and the isolation probe)."
  value       = aws_secretsmanager_secret.crm_db.arn
}

output "crm_scrub_corpus_role_arns" {
  description = "The scrub-corpus OIDC role, as a list (empty while the guardrail is off; security_access_analyzer_archive.tf)."
  value       = aws_iam_role.crm_scrub_corpus[*].arn
}

# The forward-in mailbox's receipt values (accounts/aa365 crm_mail_receipt.tf: MX record + SES receipt rule). SES
# writes a setup-notification object when the rule is created, so the bucket value waits for the bucket policy and
# the ingest key (the rule's depends_on before the move).
output "crm_ingest_receipt" {
  value = {
    domain = local.crm_ingest_domain
    rule   = local.crm_ingest_rule
    bucket = local.crm_ingest_bucket.id
    prefix = local.crm_ingest_raw
  }

  depends_on = [aws_s3_bucket_policy.crm, aws_kms_key.crm_ingest]
}
