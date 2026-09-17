# =============================================================================
# AA-302 — Bedrock Batch inference service role (account 1)
# roleArn passed to bedrock:CreateModelInvocationJob. S3 input/output stays
# in account 2's bronze bucket (aa-cis-bronze-005097885195) — cross-account
# access granted via bucket policy on that bucket (see modules/s3/main.tf),
# using the s3BucketOwner mechanism documented for Batch inference.
# =============================================================================

resource "aws_iam_role" "bedrock_batch_inference" {
  name = "aa-bedrock-batch-inference-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "867490540162" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:us-west-1:867490540162:model-invocation-job/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_batch_s3_access" {
  name = "bedrock-batch-s3-cross-account-access"
  role = aws_iam_role.bedrock_batch_inference.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBatchInput"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-input/atom-decompose/*",
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-input/s1-rewrite/*"  # AA-606
        ]
      },
      {
        Sid      = "WriteBatchOutput"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = [
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-output/atom-decompose/*",
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-output/s1-rewrite/*"  # AA-606
        ]
      },
      {
        Sid      = "ListBucketForBatchPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::aa-cis-bronze-005097885195"
        Condition = {
          StringLike = { "s3:prefix" = [
            "batch-input/atom-decompose/*", "batch-output/atom-decompose/*",
            "batch-input/s1-rewrite/*", "batch-output/s1-rewrite/*"
          ] }
        }
      }
    ]
  })
}

# ARN list copied verbatim from `aws iam get-role-policy --role-name
# AA-Bedrock-Invoker --policy-name InvokeApprovedClaudeModelsOnly` (live
# read, 2026-07-17) — 2 models x 3 ARN forms each (inference-profile,
# region-scoped foundation-model, unscoped foundation-model).
resource "aws_iam_role_policy" "bedrock_batch_model_access" {
  name = "bedrock-batch-model-invoke"
  role = aws_iam_role.bedrock_batch_inference.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel"]
      Resource = [
        "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:us-west-1:867490540162:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
      ]
    }]
  })
}
