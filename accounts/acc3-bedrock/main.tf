# =============================================================================
# AA-397 — new AA3-Bedrock-Invoker role on account 3 (786888028788).
# NOT an import — this role does not exist yet on acc3. Mirrors the shape of
# acc1's AA-Bedrock-Invoker (accounts/acc1-bedrock/bedrock_invoker_import.tf)
# so the two accounts stay swappable from the client's point of view
# (shared/llm_client/bedrock_satellite.py in AA-CIS-App).
#
# ExternalId "aa296-satellite-bedrock-acc3" confirmed by Nghiep (AA-397, Bước 1b).
#
# AA-399 — Batch inference statements added below (originally scoped out of
# AA-397 — see that issue's history — Nghiep confirmed acc3 should also serve
# Batch, acc3-primary/acc1-fallback, same as the interactive tiers). Mirrors
# accounts/acc1-bedrock/bedrock_invoker_import.tf's 3 Batch statements
# byte-for-byte except account IDs/ARNs, pointing at the new acc3 Batch
# service role (batch.tf, aa3-bedrock-batch-inference-role).
# =============================================================================

resource "aws_iam_role" "bedrock_invoker" {
  name = "AA3-Bedrock-Invoker"

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
          StringEquals = { "sts:ExternalId" = "aa296-satellite-bedrock-acc3" }
        }
      },
      # AA-TripPlanner — new B2C service in the SAME acc2, separate Lambda
      # exec role (aa-tripplanner-dev-lambda-exec, defined in
      # accounts/aa365/tripplanner.tf). Additive: does NOT modify or replace
      # the AA-CIS ECS statement above. Same ExternalId as CIS on acc3.
      {
        Sid    = "AllowAcc2TripPlannerLambdaAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::005097885195:role/aa-tripplanner-dev-lambda-exec"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = "aa296-satellite-bedrock-acc3" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_invoker_policy" {
  # Name kept as-is on purpose: renaming an inline policy forces destroy+create, leaving the role
  # with no invoke permission between the two steps. Only the Sid below was renamed.
  name = "InvokeApprovedClaudeModelsOnly"
  role = aws_iam_role.bedrock_invoker.id

  # Same N-model x 3-ARN-form shape as acc1 (inference-profile, foundation-model
  # +region, foundation-model region-empty) — undocumented Bedrock IAM evaluation
  # behavior under assumed-role sessions, confirmed live on acc1 2026-07-16 (see
  # shared/llm_client/bedrock_satellite.py docstring in AA-CIS-App). Same lesson
  # applies here: whitelist both ARN forms per model, not just the region-scoped one.
  #
  # AA-657 — added Sonnet 5, Opus 5.5, GPT-5.6 Luna, GPT-6 Astra (agreement
  # AVAILABLE + AUTHORIZED on acc3, verified 28/09/2026 via
  # get-foundation-model-availability). Inference-profile prefix is "global."
  # only, matching the "global." convention bedrock_satellite.py already uses
  # for the existing 2 models (NOT "us." — see that file's docstring); "openai."
  # models use the same 3-ARN shape as "anthropic." ones, no vendor-specific form.
  # No longer Claude-only, hence the statement Sid rename below.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeApprovedModelsOnly"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-sonnet-5",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-5",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-5",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-opus-5-5",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-opus-5-5",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-opus-5-5",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.openai.gpt-5.6-luna",
          "arn:aws:bedrock:us-west-1::foundation-model/openai.gpt-5.6-luna",
          "arn:aws:bedrock:::foundation-model/openai.gpt-5.6-luna",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.openai.gpt-6-astra",
          "arn:aws:bedrock:us-west-1::foundation-model/openai.gpt-6-astra",
          "arn:aws:bedrock:::foundation-model/openai.gpt-6-astra"
        ]
      },
      # AA-399 — Bedrock Batch job creation (model-scoped, same resource shape
      # as InvokeModel above, plus the model-invocation-job/* ARN acc1 needed
      # live — see accounts/acc1-bedrock/bedrock_invoker_import.tf's AA-303 note).
      {
        Sid    = "AllowBedrockBatchJobCreate"
        Effect = "Allow"
        Action = ["bedrock:CreateModelInvocationJob"]
        Resource = [
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
          "arn:aws:bedrock:us-west-1:786888028788:model-invocation-job/*"
        ]
      },
      # AA-399 — Bedrock Batch job read/list, job resource (not model ARN) —
      # same shape as acc1's AllowBedrockBatchJobRead.
      {
        Sid    = "AllowBedrockBatchJobRead"
        Effect = "Allow"
        Action = [
          "bedrock:GetModelInvocationJob",
          "bedrock:ListModelInvocationJobs"
        ]
        Resource = "arn:aws:bedrock:us-west-1:786888028788:model-invocation-job/*"
      },
      # AA-399 — Bedrock itself needs PassRole on the acc3 batch service role
      # (aa3-bedrock-batch-inference-role, batch.tf) to assume it when running
      # the job — separate from the caller's own CreateModelInvocationJob above.
      {
        Sid      = "AllowPassBatchInferenceRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::786888028788:role/aa3-bedrock-batch-inference-role"
      }
    ]
  })
}
