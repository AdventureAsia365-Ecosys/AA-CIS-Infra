# =============================================================================
# AA-1027 F4 (interim path) — the AA-Partner CRM gateway calls a real model: Amazon Nova Lite on acc2, through the
# CRM task role, for the one AI stage the CRM has (crm_draft_reply, writer).
#
# Why: the CRM API ran CRM_LLM_PROVIDER=stub (no env here, so the app default). AA-1027 F4 was "one real Haiku draft
# on acc3"; acc3 refuses every model since 29/10 (Error 002) and acc2 cannot run Claude, so the tech lead re-scoped F4
# (S265) to one real draft on a cheap acc2 model through the gateway. Nova Lite is the cheapest acc2 chat model the CIS
# catalogue prices and probed (CIS migration 324, row 'nova-lite'; contract-smoked on acc2 for CIS 331-333). The route
# of the stage names it (AA-Partner crm-042: Nova Lite at position 2, the crm-037 Claude entries switched off). Root
# ADR 0009 decision 14 amendment (CRM draft on acc2, Dev only) records the exception to "writers stay on Claude".
#
#   Resources (only when var.crm_llm_bedrock_enabled):
#     - inline policy aa-crm-<env>-ecs-task-llm on the CRM task role: bedrock:InvokeModel (the IAM action of the
#       Converse API the app calls) on exactly the us. inference profile of Nova Lite in this account and region, and
#       its foundation model in the US regions that profile routes to. No other model, no global profile, no
#       InvokeModelWithResponseStream (the CRM does not stream), no sts:AssumeRole (no acc3 invoker role:
#       CRM_LLM_ROLE_ARN stays unset).
#     - task env (local.crm_llm_env, read by crm_app.tf): CRM_LLM_PROVIDER=bedrock, CRM_LLM_MODEL_ID = the profile,
#       CRM_LLM_USD_PER_MTOK_IN / _OUT = the CIS catalogue prices of 'nova-lite' (equal to the crm-042 route prices,
#       so the ledger price matches the catalogue whichever source prices the row), CRM_LLM_REGION, CRM_LLM_MAX_TOKENS.
#   Off = no env and no policy: the app falls back to its stub provider (cost 0), as before.
#
# Who pays, and the guards that stay in the app (AA-Partner app/llm/gateway.py, unchanged): an agency's draft reaches
# the model only with the ai_assist entitlement (AA grants it in the CIS admin), ai_enabled on (default off, owner),
# under its monthly ai_budget_usd (default 2 USD, AI_BUDGET_MAX_USD cap) with 75/90/100 % alerts, the CRM app profile
# (crm-041: app switch and daily budget of every agency together), the stage kill switch (crm-037 is_active), the
# per-agency rate cap (RATE_LIMIT_AI_PER_MINUTE, default 6) and the F3 scrub (fail closed: no guardrail = no call).
# An agency without ai_assist or with AI off pays nothing (refused before the scrub, 0 USD row or no row).
#
# Order: AA-Partner crm-042 applied (Migration Apply) BEFORE this apply, else the first real draft tries Claude on acc2
# (two refused rows, 0 USD, "reply by hand"). The env reaches the task on the next AA-Partner Deploy Dev (it copies the
# family's latest revision and swaps the image). No apply-role change: the role already writes inline policies on
# aa-crm-* roles (crm_scrub.tf) and registers the task definition.
#
# Cost (us-west-1, D-19): IAM $0. Nova Lite 0.077 / 0.308 USD per million input / output tokens (AWS Price List API,
# us-west-1 on-demand, 31/10/2026): a draft (about 600 input, at most 800 output tokens) is about 0.0003 USD plus the
# scrub's ApplyGuardrail units (about 0.0001 USD). Dev (synthetic agencies, AI off by default): < $0.05/month.
# =============================================================================

variable "crm_llm_bedrock_enabled" {
  description = "AA-1027 F4: run the CRM AI gateway on Amazon Nova Lite (acc2 Bedrock, the CRM task role): the task env CRM_LLM_* and bedrock:InvokeModel on that inference profile only. Off = the app's stub provider (cost 0). Apply AFTER AA-Partner crm-042 (the draft route) is applied."
  type        = bool
  default     = false
}

locals {
  crm_llm_enabled = var.crm_llm_bedrock_enabled

  # The model of the CRM draft route (AA-Partner crm-042) = the CIS catalogue row 'nova-lite' (CIS migration 324):
  # the acc2 us. inference profile, its foundation model, and its prices in USD per million tokens.
  crm_llm_profile_id       = "us.amazon.nova-lite-v1:0"
  crm_llm_foundation_model = "amazon.nova-lite-v1:0"
  crm_llm_usd_per_mtok_in  = "0.077"
  crm_llm_usd_per_mtok_out = "0.308"
  crm_llm_max_tokens       = "800"

  # A us. cross-region profile authorizes InvokeModel against the foundation model in the member region that serves
  # the request (tripplanner.tf, observed live for Cohere): grant the US commercial regions the profile routes to.
  crm_llm_profile_regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]

  crm_llm_model_arns = concat(
    ["arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/${local.crm_llm_profile_id}"],
    [for region in local.crm_llm_profile_regions : "arn:aws:bedrock:${region}::foundation-model/${local.crm_llm_foundation_model}"],
  )

  # Read by crm_app.tf (task definition environment). No CRM_LLM_ROLE_ARN: acc3 is not used (Error 002).
  crm_llm_env = local.crm_llm_enabled ? [
    { name = "CRM_LLM_PROVIDER", value = "bedrock" },
    { name = "CRM_LLM_MODEL_ID", value = local.crm_llm_profile_id },
    { name = "CRM_LLM_USD_PER_MTOK_IN", value = local.crm_llm_usd_per_mtok_in },
    { name = "CRM_LLM_USD_PER_MTOK_OUT", value = local.crm_llm_usd_per_mtok_out },
    { name = "CRM_LLM_REGION", value = var.aws_region },
    { name = "CRM_LLM_MAX_TOKENS", value = local.crm_llm_max_tokens },
  ] : []
}

resource "aws_iam_role_policy" "crm_ecs_task_llm" {
  count = local.crm_llm_enabled ? 1 : 0

  name = "${local.crm_name_prefix}-ecs-task-llm"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # AA-1027 F4: the CRM draft model only (AA-Partner app/llm/providers/bedrock.py, Converse = bedrock:InvokeModel).
      Sid      = "CrmLlmInvokeNovaLite"
      Effect   = "Allow"
      Action   = "bedrock:InvokeModel"
      Resource = local.crm_llm_model_arns
    }]
  })
}

output "crm_llm_model_id" {
  description = "AA-1027 F4: CRM_LLM_MODEL_ID of the AA-Partner task (null = the stub provider)."
  value       = local.crm_llm_enabled ? local.crm_llm_profile_id : null
}
