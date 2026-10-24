# =============================================================================
# AA-938 (CRM-10) — the AA-Partner F3 PII scrubber's pass 3: a Bedrock guardrail in DETECT mode, the CRM task role's
# right to call it, and the OIDC role of AA-Partner's "Scrub corpus" workflow.
#
# Design: root docs/audits/2026-10-21-S246-crm-design-v3/design-v3.md §4.5 (PII filter before any LLM call: known
# values -> regex -> Bedrock Guardrails ApplyGuardrail in detect mode; fail closed; CI corpus >= 200 EN/VI samples,
# 0 leaks, nightly and on scrubber change), card CRM-10. Location: root docs/audits/2026-10-22-S247-crm-readiness §2
# (AA-930): Guardrails is a first-party AWS charge that the TrueIDC payer does not block, so the guardrail lives in
# acc2 us-west-1 and the raw text never leaves the account before it is scrubbed. The LLM call itself stays on acc3
# (CRM-33a). Pulled ahead from CRM-33a: pass 3 cannot run without the guardrail.
#
#   Resources (all only when var.crm_scrub_guardrail_enabled):
#     - guardrail aa-crm-<env>-scrub: every PII entity type on action NONE (detect only: it never blocks or rewrites;
#       the app numbers the placeholders and never logs `match`). No content / topic / word filters, no custom regex
#       (the app's pass 2 runs the regexes locally, for free). URL and AGE are left out on purpose (catalog links and
#       age bands are planning data). Input side only (the app sends source=INPUT).
#     - guardrail version (published, immutable): its description carries a hash of the entity list, so a change of
#       the list publishes a new version; old versions are kept (skip_destroy) for a task still pinned to one.
#     - inline policy aa-crm-<env>-ecs-task-scrub on the CRM task role: bedrock:ApplyGuardrail on this guardrail only.
#     - OIDC role aa-crm-<env>-scrub-corpus (workload boundary): trusted only by AA-Partner jobs in the GitHub
#       environment `scrub-corpus` (deployment-branch policy main only, create it BEFORE this apply), ApplyGuardrail
#       on this guardrail only. Used by AA-Partner .github/workflows/scrub-corpus.yml.
#     - task env SCRUB_GUARDRAIL_ID / SCRUB_GUARDRAIL_VERSION / SCRUB_GUARDRAIL_REGION (local.crm_scrub_env, read by
#       crm_app.tf). Off = no env = the app refuses every scrub (fail closed), so AI stays impossible.
#
# Order of applies: the apply role has no Bedrock verbs until cicd_crm.tf statements CrmBedrockGuardrail* are
# applied (BOOTSTRAP, local MFA apply of aws_iam_policy.tf_apply_crm, Nghiệp). Then set
# crm_scrub_guardrail_enabled = true in terraform.tfvars and apply through CI. The next AA-Partner deploy picks the env
# up (deploy-dev.yml copies the latest task definition revision).
#
# Cost (us-west-1, est., D-19): the guardrail and its versions $0 at rest; ApplyGuardrail PII filter $0.10 per 1,000
# text units (1 unit = up to 1,000 characters, AWS Price List 22/10/2026, AA-930 §2). The corpus workflow sends about
# 240 units a run: nightly ~ $0.72/month (+ ~$0.02 per run on a scrubber change). Dev app traffic (synthetic agencies,
# AI off by default) < $0.05/month. IAM roles and policies $0. Total ~ $0.75/month.
# =============================================================================

variable "crm_scrub_guardrail_enabled" {
  description = "AA-938: create the F3 scrub guardrail (acc2), grant the CRM task role and the corpus role ApplyGuardrail on it, and pass its id / version to the AA-Partner task. Turn on only AFTER the MFA bootstrap apply of the cicd_crm.tf CrmBedrockGuardrail* statements."
  type        = bool
  default     = false
}

locals {
  crm_scrub_enabled = var.crm_scrub_guardrail_enabled

  # Every Guardrails PII entity type except URL and AGE (see header). Mirrors AA-Partner app/privacy/scrubber.py
  # DETECTOR_KINDS (a type missing there is ignored by the app, so add it in both places).
  crm_scrub_pii_types = [
    "NAME", "EMAIL", "PHONE", "ADDRESS", "USERNAME", "PASSWORD", "PIN", "DRIVER_ID", "LICENSE_PLATE",
    "VEHICLE_IDENTIFICATION_NUMBER", "CREDIT_DEBIT_CARD_NUMBER", "CREDIT_DEBIT_CARD_CVV", "CREDIT_DEBIT_CARD_EXPIRY",
    "INTERNATIONAL_BANK_ACCOUNT_NUMBER", "SWIFT_CODE", "US_BANK_ACCOUNT_NUMBER", "US_BANK_ROUTING_NUMBER",
    "IP_ADDRESS", "MAC_ADDRESS", "US_PASSPORT_NUMBER", "US_SOCIAL_SECURITY_NUMBER",
    "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER", "UK_NATIONAL_INSURANCE_NUMBER", "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER",
    "UK_NATIONAL_HEALTH_SERVICE_NUMBER", "CA_SOCIAL_INSURANCE_NUMBER", "CA_HEALTH_NUMBER", "AWS_ACCESS_KEY",
    "AWS_SECRET_KEY",
  ]
  crm_scrub_config_hash = substr(sha256(jsonencode(local.crm_scrub_pii_types)), 0, 12)

  crm_scrub_tags = merge(local.crm_tags, { Service = "crm", Issue = "AA-938" })

  crm_scrub_guardrail_arns = local.crm_scrub_enabled ? [
    aws_bedrock_guardrail.crm_scrub[0].guardrail_arn,
    "${aws_bedrock_guardrail.crm_scrub[0].guardrail_arn}:*",
  ] : []

  # Read by crm_app.tf (task definition environment).
  crm_scrub_env = local.crm_scrub_enabled ? [
    { name = "SCRUB_GUARDRAIL_ID", value = aws_bedrock_guardrail.crm_scrub[0].guardrail_id },
    { name = "SCRUB_GUARDRAIL_VERSION", value = aws_bedrock_guardrail_version.crm_scrub[0].version },
    { name = "SCRUB_GUARDRAIL_REGION", value = var.aws_region },
  ] : []

  crm_scrub_oidc_subjects = concat(
    ["repo:AdventureAsia365-Ecosys@276539096/AA-Partner@${local.crm_oidc_repo_id}:environment:scrub-corpus"],
    var.crm_github_repo_id != "" ? [] : ["repo:AdventureAsia365-Ecosys/AA-Partner:environment:scrub-corpus"],
  )
}

resource "aws_bedrock_guardrail" "crm_scrub" {
  count = local.crm_scrub_enabled ? 1 : 0

  name        = "${local.crm_name_prefix}-scrub"
  description = "AA-938 F3 PII scrubber pass 3 (detect only, never blocks): AA-Partner app/privacy/guardrails.py"

  # Required by the API; never shown, because no policy blocks (every action is NONE).
  blocked_input_messaging   = "This text could not be processed."
  blocked_outputs_messaging = "This text could not be processed."

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = local.crm_scrub_pii_types
      content {
        type           = pii_entities_config.value
        action         = "NONE"
        input_action   = "NONE"
        input_enabled  = true
        output_action  = "NONE"
        output_enabled = false
      }
    }
  }

  tags = local.crm_scrub_tags
}

resource "aws_bedrock_guardrail_version" "crm_scrub" {
  count = local.crm_scrub_enabled ? 1 : 0

  guardrail_arn = aws_bedrock_guardrail.crm_scrub[0].guardrail_arn
  description   = "AA-938 scrub entities ${local.crm_scrub_config_hash}"
  skip_destroy  = true
}

resource "aws_iam_role_policy" "crm_ecs_task_scrub" {
  count = local.crm_scrub_enabled ? 1 : 0

  name = "${local.crm_name_prefix}-ecs-task-scrub"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # F3 pass 3 (AA-Partner app/privacy/guardrails.py): this guardrail only, no model invocation.
      Sid      = "CrmScrubApplyGuardrail"
      Effect   = "Allow"
      Action   = "bedrock:ApplyGuardrail"
      Resource = local.crm_scrub_guardrail_arns
    }]
  })
}

# -----------------------------------------------------------------------------
# OIDC role of AA-Partner's "Scrub corpus" workflow: ApplyGuardrail only, environment scrub-corpus only.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "crm_scrub_corpus" {
  count = local.crm_scrub_enabled ? 1 : 0

  name                 = "${local.crm_name_prefix}-scrub-corpus"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.crm_scrub_oidc_subjects }
      }
    }]
  })

  tags = local.crm_scrub_tags

  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "crm_scrub_corpus" {
  count = local.crm_scrub_enabled ? 1 : 0

  name = "${local.crm_name_prefix}-scrub-corpus"
  role = aws_iam_role.crm_scrub_corpus[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "CrmScrubCorpusApplyGuardrail"
      Effect   = "Allow"
      Action   = "bedrock:ApplyGuardrail"
      Resource = local.crm_scrub_guardrail_arns
    }]
  })
}

output "crm_scrub_guardrail_id" {
  description = "AA-938: SCRUB_GUARDRAIL_ID (AA-Partner task env, set here; and the scrub-corpus environment variable)."
  value       = local.crm_scrub_enabled ? aws_bedrock_guardrail.crm_scrub[0].guardrail_id : null
}

output "crm_scrub_guardrail_version" {
  description = "AA-938: SCRUB_GUARDRAIL_VERSION (published version the task and the corpus workflow use)."
  value       = local.crm_scrub_enabled ? aws_bedrock_guardrail_version.crm_scrub[0].version : null
}

output "crm_scrub_corpus_role_arn" {
  description = "AA-938: SCRUB_CORPUS_ROLE_ARN of the AA-Partner GitHub environment scrub-corpus."
  value       = local.crm_scrub_enabled ? aws_iam_role.crm_scrub_corpus[0].arn : null
}
