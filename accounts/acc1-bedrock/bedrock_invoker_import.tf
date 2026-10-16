# =============================================================================
# AA-302 carryover #1 — import existing AA-Bedrock-Invoker role (created by
# hand for AA-296 satellite Bedrock pattern) into Terraform state, then add
# Batch inference job-management permissions.
#
# Trust policy + InvokeApprovedClaudeModelsOnly statement below are copied
# byte-for-byte from a live read (`aws iam get-role` / `get-role-policy
# --role-name AA-Bedrock-Invoker`, account 867490540162, 2026-07-17) — do
# NOT edit those without re-verifying against live state first.
# =============================================================================

resource "aws_iam_role" "bedrock_invoker" {
  name = "AA-Bedrock-Invoker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAcc2ECSTaskRoleAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::005097885195:role/aa-cis-dev-ecs-task-role"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = "aa296-satellite-bedrock" }
        }
      },
      # AA-TripPlanner — additive trust for the new B2C service's Lambda exec
      # role (aa-tripplanner-dev-lambda-exec in acc2, defined in
      # accounts/aa365/tripplanner.tf). acc1 is the FALLBACK satellite for
      # TripPlanner (acc3 primary). Does NOT modify the AA-CIS ECS statement
      # above. Same ExternalId as CIS on acc1 ("aa296-satellite-bedrock").
      {
        Sid    = "AllowAcc2TripPlannerLambdaAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::005097885195:role/aa-tripplanner-dev-lambda-exec"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = "aa296-satellite-bedrock" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_invoker_policy" {
  name = "InvokeApprovedClaudeModelsOnly"
  role = aws_iam_role.bedrock_invoker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Unchanged — existing live statement, copied verbatim.
      {
        Sid    = "InvokeApprovedClaudeModelsOnly"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
        ]
      },
      # AA-862 — Cohere Embed v4 as the last account hop of the embed chain
      # (acc2 -> acc3 -> acc1). Additive statement; the live statements around
      # it are unchanged. Same ARN set as acc3's InvokeCohereEmbedV4 (region
      # wildcards because a cross-region profile authorizes against the member
      # region's foundation-model ARN). acc1's Cohere quotas/model access are
      # NOT verified yet (SSO expired at S239): the catalog row stays disabled
      # until a probe through this role passes.
      {
        Sid    = "InvokeCohereEmbedV4"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:*:867490540162:inference-profile/global.cohere.embed-v4:0",
          "arn:aws:bedrock:*:867490540162:inference-profile/us.cohere.embed-v4:0",
          "arn:aws:bedrock:*::foundation-model/cohere.embed-v4:0",
          "arn:aws:bedrock:::foundation-model/cohere.embed-v4:0"
        ]
      },
      # New — AA-302 carryover: Bedrock Batch job creation (model-scoped,
      # same resource shape as InvokeModel above).
      # AA-303 live verify (2026-07-17): AccessDeniedException on real
      # CreateModelInvocationJob call demanded Resource
      # "model-invocation-job/*", on top of the model ARNs — same 2-ARN-form
      # lesson as the S106 InvokeModel bug (assumed-role Bedrock calls can be
      # evaluated against an ARN shape not documented publicly). Keep BOTH
      # forms; do not remove the model ARNs — may still be needed to
      # validate modelId exists.
      {
        Sid    = "AllowBedrockBatchJobCreate"
        Effect = "Allow"
        Action = ["bedrock:CreateModelInvocationJob"]
        Resource = [
          "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1:867490540162:model-invocation-job/*"
        ]
      },
      # New — AA-302 carryover: Bedrock Batch job read/list — job resource,
      # NOT the model ARN (unverified: ListModelInvocationJobs may require
      # Resource = "*" instead of this ARN pattern — confirm at carryover #2
      # live test; do not silently change if apply/runtime errors on it).
      {
        Sid    = "AllowBedrockBatchJobRead"
        Effect = "Allow"
        Action = [
          "bedrock:GetModelInvocationJob",
          "bedrock:ListModelInvocationJobs"
        ]
        Resource = "arn:aws:bedrock:us-west-1:867490540162:model-invocation-job/*"
      },
      # New — AA-303 live verify: Bedrock itself needs PassRole on the batch
      # service role (aa-bedrock-batch-inference-role, defined in main.tf)
      # to assume it when running the job — separate from the caller's own
      # CreateModelInvocationJob permission above.
      {
        Sid      = "AllowPassBatchInferenceRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::867490540162:role/aa-bedrock-batch-inference-role"
      }
    ]
  })
}
