# =============================================================================
# AA-TripPlanner-AI — backend infrastructure (NEW service, NOT part of AA-CIS).
#
# WHY THIS FILE EXISTS / WHAT IT ADDS (report for reviewers):
#   AA-TripPlanner is a separate B2C product (repo: AA-TripPlanner-Web). Its
#   two Python Lambdas run in the SAME acc2 (005097885195) VPC as AA-CIS so
#   they can reach the shared RDS. To use the existing account-aa365 CI/CD
#   pipeline (terraform-plan on PR, terraform-apply via workflow_dispatch —
#   both hardcode working-directory: accounts/aa365) WITHOUT modifying any
#   workflow, the resources live in this dedicated file inside the aa365 root.
#
#   Everything here is prefixed `tripplanner*` / uses the `aa-tripplanner-dev-*`
#   name prefix and is self-contained in this file. It does NOT modify any
#   existing AA-CIS resource. It only READS existing module outputs
#   (module.vpc.*, module.rds.*) to place the Lambdas in-VPC and build the DB
#   connection secret — it creates NO new VPC/RDS/subnet/SG.
#
#   Bedrock model access mirrors AA-CIS/ACPv2 exactly (verified live):
#     - Claude (compose/renarrate): acc2 is a channel-program account and
#       CANNOT invoke Claude, so the Lambda assumes the satellite invoker
#       roles — acc3 AA3-Bedrock-Invoker (primary) / acc1 AA-Bedrock-Invoker
#       (fallback) — same pattern as module.ecs's task role
#       (see bedrock_satellite_assume.tf). The TRUST side (adding this Lambda
#       role as a principal on those roles) lives in accounts/acc3-bedrock and
#       accounts/acc1-bedrock and is applied via their own workflow — see the
#       companion change there; this file only grants the caller-side
#       sts:AssumeRole.
#     - Embeddings (Cohere Embed v4): acc2 CAN invoke Cohere directly, so no
#       satellite — a direct bedrock:InvokeModel grant on the inference
#       profile is enough.
# =============================================================================

locals {
  tp_name_prefix = "aa-tripplanner-${var.environment}"

  tp_tags = {
    Project     = "AA-TripPlanner"
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "tripplanner"
  }

  # Cohere Embed v4 inference profile in acc2 (direct-invoke, verified live).
  tp_embed_profile_arn = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/us.cohere.embed-v4:0"
  # Cohere v4 foundation model (region + region-empty forms, mirroring the
  # AA3-Bedrock-Invoker whitelist discipline of listing all ARN forms).
  tp_embed_model_arns = [
    local.tp_embed_profile_arn,
    "arn:aws:bedrock:${var.aws_region}::foundation-model/cohere.embed-v4:0",
    "arn:aws:bedrock:::foundation-model/cohere.embed-v4:0",
  ]

  # Satellite invoker roles (Claude). Same ARNs AA-CIS uses.
  tp_satellite_invoker_arns = [
    "arn:aws:iam::786888028788:role/AA3-Bedrock-Invoker", # acc3 primary
    "arn:aws:iam::867490540162:role/AA-Bedrock-Invoker",  # acc1 fallback
  ]
}

# -----------------------------------------------------------------------------
# DB connection secret for the TripPlanner Lambdas.
# Placeholder value; the real DSN is set out-of-band (ignore_changes), same
# convention as modules/secrets. TripPlanner owns the `tripplanner` schema in
# the shared DB (migrations in the app repo).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "tripplanner_db" {
  name                    = "tripplanner/${var.environment}/database-url"
  description             = "AA-TripPlanner DB connection string (tripplanner schema, shared RDS)"
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.tp_tags
}

resource "aws_secretsmanager_secret_version" "tripplanner_db" {
  secret_id     = aws_secretsmanager_secret.tripplanner_db.id
  secret_string = "REPLACE_ME"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------------------------------
# Lambda deployment artifacts — S3 (chosen over local `filename` because the
# zips are built in the AA-TripPlanner-Web repo, not this Infra repo, so they
# are not present in a fresh Infra CI checkout). The packaging step
# (backend/package_lambdas.sh) builds dist/tripplanner/{browse,assembly}.zip;
# Terraform uploads them here (aws_s3_object) and the Lambdas deploy from S3.
#
# The zips are still not present at PLAN time in a fresh checkout, so both the
# object `source`/`etag` and the Lambda `s3_object_version`/`source_code_hash`
# are guarded with fileexists(): plan is a clean no-op-on-missing-artifact,
# apply (run with the zips built locally first) uploads + deploys the real
# artifact. Versioning is on so each upload produces a new object version the
# Lambda redeploys from.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "tripplanner_artifacts" {
  bucket = "${local.tp_name_prefix}-lambda-artifacts-${var.account_id}"
  tags   = local.tp_tags
}

resource "aws_s3_bucket_versioning" "tripplanner_artifacts" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tripplanner_artifacts" {
  bucket                  = aws_s3_bucket.tripplanner_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tripplanner_artifacts" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

locals {
  tp_browse_zip   = "${var.tripplanner_lambda_zip_dir}/browse.zip"
  tp_assembly_zip = "${var.tripplanner_lambda_zip_dir}/assembly.zip"
}

resource "aws_s3_object" "tripplanner_browse_zip" {
  count  = fileexists(local.tp_browse_zip) ? 1 : 0
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "browse.zip"
  source = local.tp_browse_zip
  etag   = filemd5(local.tp_browse_zip)
}

resource "aws_s3_object" "tripplanner_assembly_zip" {
  count  = fileexists(local.tp_assembly_zip) ? 1 : 0
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "assembly.zip"
  source = local.tp_assembly_zip
  etag   = filemd5(local.tp_assembly_zip)
}

# -----------------------------------------------------------------------------
# Lambda execution role (shared by both TripPlanner Lambdas).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tripplanner_lambda_exec" {
  name = "${local.tp_name_prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tp_tags

  # This role is tagged, so CreateRole calls iam:TagRole. The CI/CD role's
  # grant for that (cicd.tf, "TripPlannerLambdaRoleTagging") is applied in
  # this same run, so wait for IAM propagation before creating the role —
  # same eventual-consistency mitigation the budgets/CloudTrail resources use.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

# ENI-in-VPC (reach RDS) — AWS-managed policy, same as the CIS lambda module.
resource "aws_iam_role_policy_attachment" "tripplanner_lambda_vpc" {
  role       = aws_iam_role.tripplanner_lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "tripplanner_lambda_permissions" {
  name = "${local.tp_name_prefix}-lambda-permissions"
  role = aws_iam_role.tripplanner_lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_db.arn]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:*"
      },
      # Direct Cohere embeddings on acc2 (no satellite needed for embeddings).
      {
        Sid      = "BedrockEmbedDirect"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = local.tp_embed_model_arns
      },
      # Caller-side grant to assume the satellite invoker roles for Claude.
      # Mirrors accounts/aa365/bedrock_satellite_assume.tf (ECS task role).
      {
        Sid      = "AssumeSatelliteBedrockInvokers"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.tp_satellite_invoker_arns
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# The two Lambdas. Zips are built by the app repo's packaging step and placed
# in dist/ before apply (var.tripplanner_lambda_zip_dir). Kept as separate
# functions per the app's hard architectural boundary (browse = stateless
# cacheable, assembly = stateful + Bedrock).
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "tripplanner_browse" {
  function_name = "${local.tp_name_prefix}-browse"
  role          = aws_iam_role.tripplanner_lambda_exec.arn
  runtime       = "python3.12"
  handler       = "backend.browse.handler.handler"
  timeout       = 30
  memory_size   = 512

  # Deploy from S3 (see the tripplanner_artifacts bucket above). s3_key is
  # static; s3_object_version + source_code_hash come from the uploaded object
  # / local zip and are guarded with fileexists()/try() so plan is a clean
  # no-op when the artifact isn't present yet.
  s3_bucket         = aws_s3_bucket.tripplanner_artifacts.id
  s3_key            = "browse.zip"
  s3_object_version = try(aws_s3_object.tripplanner_browse_zip[0].version_id, null)
  source_code_hash  = fileexists(local.tp_browse_zip) ? filebase64sha256(local.tp_browse_zip) : null

  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [module.vpc.sg_app_id]
  }

  environment {
    variables = {
      ENVIRONMENT                  = var.environment
      TRIPPLANNER_DATABASE_URL_ARN = aws_secretsmanager_secret.tripplanner_db.arn
      BEDROCK_REGION               = var.aws_region
      BEDROCK_MODEL_EMBED          = "us.cohere.embed-v4:0"
    }
  }

  tags = local.tp_tags
}

resource "aws_lambda_function" "tripplanner_assembly" {
  function_name = "${local.tp_name_prefix}-assembly"
  role          = aws_iam_role.tripplanner_lambda_exec.arn
  runtime       = "python3.12"
  handler       = "backend.assembly.handler.handler"
  timeout       = 60
  memory_size   = 512

  # Deploy from S3 (see browse Lambda above).
  s3_bucket         = aws_s3_bucket.tripplanner_artifacts.id
  s3_key            = "assembly.zip"
  s3_object_version = try(aws_s3_object.tripplanner_assembly_zip[0].version_id, null)
  source_code_hash  = fileexists(local.tp_assembly_zip) ? filebase64sha256(local.tp_assembly_zip) : null

  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [module.vpc.sg_app_id]
  }

  environment {
    variables = {
      ENVIRONMENT                  = var.environment
      TRIPPLANNER_DATABASE_URL_ARN = aws_secretsmanager_secret.tripplanner_db.arn
      BEDROCK_REGION               = var.aws_region
      BEDROCK_ACCT_PRIMARY         = "786888028788"
      BEDROCK_ACCT_FALLBACK        = "867490540162"
      # acc3 and acc1 use DIFFERENT invoker role names — pass both (a single
      # name breaks the fallback path).
      BEDROCK_ROLE_NAME_PRIMARY           = "AA3-Bedrock-Invoker"
      BEDROCK_ROLE_NAME_FALLBACK          = "AA-Bedrock-Invoker"
      BEDROCK_EXTERNAL_ID_PRIMARY         = "aa296-satellite-bedrock-acc3"
      BEDROCK_EXTERNAL_ID_FALLBACK        = "aa296-satellite-bedrock"
      BEDROCK_MODEL_COMPOSE               = "us.anthropic.claude-sonnet-4-6"
      ADVISOR_NOTIFY_EMAIL                = var.tripplanner_advisor_email
      REQUIRE_REGISTRATION_BEFORE_HANDOFF = "true"
    }
  }

  tags = local.tp_tags
}

# Function URLs (the frontend BFF calls these; CloudFront can sit in front of
# browse later). AWS_IAM auth left off for MVP dev — revisit before real use.
resource "aws_lambda_function_url" "tripplanner_browse" {
  function_name      = aws_lambda_function.tripplanner_browse.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_function_url" "tripplanner_assembly" {
  function_name      = aws_lambda_function.tripplanner_assembly.function_name
  authorization_type = "NONE"
}

output "tripplanner_browse_url" {
  value = aws_lambda_function_url.tripplanner_browse.function_url
}

output "tripplanner_assembly_url" {
  value = aws_lambda_function_url.tripplanner_assembly.function_url
}

output "tripplanner_lambda_exec_role_arn" {
  value = aws_iam_role.tripplanner_lambda_exec.arn
}
