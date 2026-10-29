# =============================================================================
# AA-399 — Bedrock Batch inference service role on acc3 (786888028788), same
# shape as the former acc1 aa-bedrock-batch-inference-role (removed, AA-998).
# roleArn passed to bedrock:CreateModelInvocationJob when the caller (acc2
# ECS task, via AA3-Bedrock-Invoker) submits a Batch job through acc3. S3
# input/output stays in account 2's bronze bucket (aa-cis-bronze-005097885195)
# — cross-account access granted via bucket policy on that bucket
# (modules/s3/main.tf's aws_s3_bucket_policy.bronze — a NEW statement added
# for this role; the acc1 statements were removed in AA-998).
#
# Design: acc3 is the only Batch account since AA-998 (S255); the former
# acc3-primary/acc1-fallback pattern of AA-397/399 is gone.
# =============================================================================

resource "aws_iam_role" "bedrock_batch_inference" {
  name = "aa3-bedrock-batch-inference-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "786888028788" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:us-west-1:786888028788:model-invocation-job/*" }
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
        Sid    = "ReadBatchInput"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-input/atom-decompose/*",
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-input/s1-rewrite/*" # AA-606
        ]
      },
      {
        Sid    = "WriteBatchOutput"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-output/atom-decompose/*",
          "arn:aws:s3:::aa-cis-bronze-005097885195/batch-output/s1-rewrite/*" # AA-606
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

resource "aws_iam_role_policy" "bedrock_batch_model_access" {
  name = "bedrock-batch-model-invoke"
  role = aws_iam_role.bedrock_batch_inference.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel"]
      Resource = [
        "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:us-west-1:786888028788:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
        "arn:aws:bedrock:::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
      ]
    }]
  })
}
