# =============================================================================
# AA-1095 (S278) — AA1-Bedrock-Invoker on account 1 (acc1), the Bedrock chat account while acc3 is blocked.
#
# Mirrors acc3's AA3-Bedrock-Invoker (accounts/acc3-bedrock/main.tf), narrowed to what the gateway calls:
#   - trust: the acc2 CIS ECS task role (api and worker share it, modules/ecs aws_iam_role.ecs_task), ExternalId
#     pinned. The TripPlanner Lambda role is NOT trusted: TripPlanner's gateway calls only the BEDROCK_ACCT_PRIMARY
#     (acc3) satellite today; giving it acc1 is its own change (Lambda env + grant + TripPlanner code).
#   - permissions: InvokeModel / InvokeModelWithResponseStream (Converse and ConverseStream authorize as these two
#     actions) on the 13 chat models of the gateway, through their global. inference profiles, plus the free, read-only
#     ListFoundationModels the CIS lifecycle sync reads per Bedrock connection.
#   - nothing else: no Batch (no batch service role, no CreateModelInvocationJob, no PassRole), no Cost Explorer
#     reader, no embeddings (Cohere Embed v4 stays on acc2 / acc3). Adding a model = a new id in local.chat_models
#     plus the CIS deployment row (migration), the same pair as on acc3.
#
# IAM note (AA-296, AA-CIS-App shared/llm_client/bedrock_satellite.py): on an assumed-role session Bedrock also
# evaluates the foundation-model ARN WITHOUT a region, and a global. profile authorizes the call against the
# foundation-model ARN of whichever region serves it. Hence three forms per model: the profile in us-west-1, the
# foundation model in any region, and the region-empty foundation model (the shape of acc3's
# InvokeAvailabilityCandidates statement).
#
# ExternalId aa1095-satellite-bedrock-acc1: the value the CIS connection row `acc1` carries (AA-CIS-App migration
# 406). Not a secret (acc3's is public in this repo too); it pins the trust to the gateway's own assume call.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  external_id = "aa1095-satellite-bedrock-acc1"

  # The Bedrock model ids of the gateway's 13 chat models (AA-CIS-App catalog keys sonnet-5-5, opus-5-5, haiku-5-5,
  # sonnet-5, sonnet-4-6, opus-4-6, haiku-4-5, gpt-6-luna, gpt-6-astra, gpt-6-sol, gpt-5.6-luna, gpt-6.1-sol,
  # gpt-6.1-terra). Each answered a Converse call on acc1 through global.<id> on 12/11/2026 (S278).
  chat_models = [
    "anthropic.claude-sonnet-5-5",
    "anthropic.claude-opus-5-5",
    "anthropic.claude-haiku-5-5",
    "anthropic.claude-sonnet-5",
    "anthropic.claude-sonnet-4-6",
    "anthropic.claude-opus-4-6-v1",
    "anthropic.claude-haiku-4-5-20251001-v1:0",
    "openai.gpt-6-luna",
    "openai.gpt-6-astra",
    "openai.gpt-6-sol",
    "openai.gpt-5.6-luna",
    "openai.gpt-6.1-sol",
    "openai.gpt-6.1-terra",
  ]

  invoke_resources = flatten([for m in local.chat_models : [
    "arn:aws:bedrock:us-west-1:${data.aws_caller_identity.current.account_id}:inference-profile/global.${m}",
    "arn:aws:bedrock:*::foundation-model/${m}",
    "arn:aws:bedrock:::foundation-model/${m}",
  ]])
}

resource "aws_iam_role" "bedrock_invoker" {
  name                 = "AA1-Bedrock-Invoker"
  description          = "AA-1095: the acc2 CIS gateway invokes Bedrock chat models on acc1 (root ADR 0001a, Note S278)"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAcc2ECSTaskRoleAssume"
        Effect = "Allow"
        # The CIS ECS task role (acc2), a literal like acc3's AllowAcc2ECSTaskRoleAssume (the trust inventory guard,
        # tools/terraform/iam_trust_inventory.py, reads the principal statically).
        Principal = { AWS = "arn:aws:iam::005097885195:role/aa-cis-dev-ecs-task-role" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = local.external_id }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_invoker_policy" {
  name = "InvokeGatewayChatModelsOnly"
  role = aws_iam_role.bedrock_invoker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeGatewayChatModels"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = local.invoke_resources
      },
      {
        # The AA-CIS-App nightly llm_model_lifecycle_sync job (AA-1024 D2) lists the foundation models of every
        # Bedrock connection. Read only, free; ListFoundationModels has no resource-level permission.
        Sid      = "ListFoundationModelsForLifecycle"
        Effect   = "Allow"
        Action   = ["bedrock:ListFoundationModels"]
        Resource = "*"
      }
    ]
  })
}
