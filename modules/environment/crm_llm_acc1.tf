# =============================================================================
# AA-1138 (S285, tech lead decision of 19/11/2026) — the AA-Partner CRM draft stage runs Claude Haiku 5.5 on acc1's
# Bedrock first, then Amazon Nova Lite on acc2 (crm_llm.tf) as its last fallback.
#
# Why: a blind A/B of ten client replies (Haiku 5.5 won 7 of 10 over Nova Lite). acc2 cannot run Claude and acc3
# refuses models at account level, so the CRM's Claude hop is acc1's AA1-Bedrock-Invoker (accounts/acc1-bedrock), the
# role the CIS gateway already assumes (root ADR 0001a, Note S278: nothing else on acc1). The CRM is Bedrock only
# (root ADR 0008a §5), so it does not use the Anthropic API connection CIS tries first.
#
#   Resources (only when var.crm_llm_acc1_enabled AND crm_llm_bedrock_enabled AND the acc1 ID input is set):
#     - inline policy aa-crm-<env>-ecs-task-llm-acc1 on the CRM task role: sts:AssumeRole on exactly acc1's
#       AA1-Bedrock-Invoker. The model grant itself lives on acc1 (the invoker role's own policy); the acc1 root's
#       trust names this task role with its own ExternalId (statement AllowAcc2CrmEcsTaskRoleAssume).
#     - task env (local.crm_llm_acc1_env, read by crm_app.tf): CRM_LLM_ACC1_ROLE_ARN and CRM_LLM_ACC1_EXTERNAL_ID, read
#       by AA-Partner app/llm/providers/bedrock.py for a route entry with connection_key 'bedrock_acc1' (crm-078).
#   Off = no policy, no env: the app never calls a 'bedrock_acc1' entry (a 0 USD refused attempt, then Nova Lite).
#
# The acc1 ID is never committed here (public repo): it is var.bedrock_acct_payer, the root's local.bedrock_acct_payer
# (repo secret BEDROCK_ACCT_PAYER_ID, bedrock_satellite_assume.tf). The ExternalId is not a secret (the acc1 root
# carries it in clear, like the CIS one); it pins the trust to the CRM's own assume call.
#
# Order: the acc1 root apply (the trust statement) and this apply, then AA-Partner crm-078 (Migration Apply), then the
# AA-Partner code PR deploy (it copies the family's latest task-def revision, so the env reaches the task then).
# Cost: IAM $0. The CRM's spend on acc1 is capped by the AA-Partner setting crm.ai.connection_monthly_cap_usd entry
# "acc1" (5 USD a month, tech lead 19/11), taken from the CIS share of acc1.
# =============================================================================

variable "crm_llm_acc1_enabled" {
  description = "AA-1138: let the CRM AI gateway assume acc1's AA1-Bedrock-Invoker for its Claude route entry (crm-078 connection_key bedrock_acc1): sts:AssumeRole on that role only and the task env CRM_LLM_ACC1_ROLE_ARN / CRM_LLM_ACC1_EXTERNAL_ID. Needs crm_llm_bedrock_enabled and the acc1 ID (repo secret BEDROCK_ACCT_PAYER_ID). Apply the acc1 root's trust statement first."
  type        = bool
  default     = false
}

variable "bedrock_acct_payer" {
  description = "AA-1138: acc1's 12-digit account ID (the root's local.bedrock_acct_payer, from the repo secret BEDROCK_ACCT_PAYER_ID); empty = unset (no acc1 grant, no env)."
  type        = string
  default     = ""

  validation {
    condition     = var.bedrock_acct_payer == "" || can(regex("^[0-9]{12}$", var.bedrock_acct_payer))
    error_message = "bedrock_acct_payer must be a 12-digit AWS account id or empty."
  }
}

locals {
  crm_llm_acc1_on = local.crm_llm_enabled && var.crm_llm_acc1_enabled && var.bedrock_acct_payer != ""

  crm_llm_acc1_role_arn = "arn:aws:iam::${var.bedrock_acct_payer}:role/AA1-Bedrock-Invoker"
  # The same value as local.crm_external_id of accounts/acc1-bedrock/main.tf (tools/terraform/tests checks both).
  crm_llm_acc1_external_id = "aa1138-crm-bedrock-acc1"

  # Read by crm_app.tf (task definition environment).
  crm_llm_acc1_env = local.crm_llm_acc1_on ? [
    { name = "CRM_LLM_ACC1_ROLE_ARN", value = local.crm_llm_acc1_role_arn },
    { name = "CRM_LLM_ACC1_EXTERNAL_ID", value = local.crm_llm_acc1_external_id },
  ] : []
}

resource "aws_iam_role_policy" "crm_ecs_task_llm_acc1" {
  count = local.crm_llm_acc1_on ? 1 : 0

  name = "${local.crm_name_prefix}-ecs-task-llm-acc1"
  role = aws_iam_role.crm_ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # AA-1138: the CRM's Claude route entry on acc1 (AA-Partner app/llm/providers/bedrock.py, Connection bedrock_acc1).
      Sid      = "CrmLlmAssumeAcc1BedrockInvoker"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = local.crm_llm_acc1_role_arn
    }]
  })
}
