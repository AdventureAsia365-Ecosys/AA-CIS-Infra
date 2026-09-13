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

resource "random_password" "tripplanner_api_key" {
  length  = 48
  special = false # url/header-safe token
}

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
  # The `us.` CROSS-REGION inference profile routes the actual model call to a
  # member region (observed live: us-east-1) and authorizes bedrock:InvokeModel
  # against the foundation-model ARN IN THAT MEMBER REGION — not just the
  # profile's home region. A us-west-1-only grant fails with AccessDenied on
  # arn:aws:bedrock:us-east-1::foundation-model/cohere.embed-v4:0. So allow the
  # foundation-model ARN in ANY region (wildcard) plus the inference-profile
  # ARN in any region — same "list every ARN form" discipline as
  # AA3-Bedrock-Invoker, extended to cross-region member regions.
  tp_embed_model_arns = [
    local.tp_embed_profile_arn,
    "arn:aws:bedrock:*:${var.account_id}:inference-profile/us.cohere.embed-v4:0",
    "arn:aws:bedrock:*::foundation-model/cohere.embed-v4:0",
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
# Edge shared-secret. The Lambdas verify the X-TripPlanner-Key header against
# this value (backend/shared/auth.py); the Vercel BFF sends it. API Gateway
# itself stays authorization = NONE (MVP; a JWT/authorizer is the later
# hardening). Generated here (random_password) so the value is managed, and
# also stored in Secrets Manager so the BFF's value can be fetched to set the
# Vercel env without reading Lambda config.
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "tripplanner_api_key" {
  name                    = "tripplanner/${var.environment}/api-key"
  description             = "AA-TripPlanner edge shared secret (X-TripPlanner-Key header)"
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = local.tp_tags
}

resource "aws_secretsmanager_secret_version" "tripplanner_api_key" {
  secret_id     = aws_secretsmanager_secret.tripplanner_api_key.id
  secret_string = random_password.tripplanner_api_key.result
}

# -----------------------------------------------------------------------------
# Lambda deployment artifacts — S3, with a clean split of responsibility:
#
#   Terraform (this file, Infra repo) OWNS the artifacts bucket and seeds a
#   tiny PLACEHOLDER zip under each key so the Lambdas can be created on first
#   apply without needing the real (43MB) build here. Terraform then
#   ignore_changes the Lambda code attributes so it never fights the app.
#
#   The AA-TripPlanner-Web repo (App) OWNS the real code: its deploy workflow
#   builds the zips (backend/package_lambdas.sh), uploads them to this bucket
#   and calls lambda:UpdateFunctionCode — via a dedicated, least-privilege
#   OIDC role defined below (tripplanner_app_deploy). This keeps the app's
#   build artifact out of the Infra repo entirely.
#
# Versioning is on so each app upload is a new object version.
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

# A tiny valid Lambda zip (a single placeholder.py returning 501), committed
# at artifacts/placeholder.zip, used ONLY to create the functions on first
# apply. The App deploy workflow (AA-TripPlanner-Web) replaces this with the
# real code via lambda:UpdateFunctionCode immediately after. Committed as a
# static file (209 bytes) rather than generated so no extra Terraform provider
# (hashicorp/archive) is needed.
locals {
  tp_placeholder_zip = "${path.module}/artifacts/placeholder.zip"
}

resource "aws_s3_object" "tripplanner_browse_zip" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "browse.zip"
  source = local.tp_placeholder_zip
  etag   = filemd5(local.tp_placeholder_zip)

  # The App deploy workflow overwrites this object with the real build; do not
  # let Terraform revert it back to the placeholder on later applies.
  lifecycle {
    ignore_changes = [etag, source]
  }
}

resource "aws_s3_object" "tripplanner_assembly_zip" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "assembly.zip"
  source = local.tp_placeholder_zip
  etag   = filemd5(local.tp_placeholder_zip)

  lifecycle {
    ignore_changes = [etag, source]
  }
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

  # Created from the S3 placeholder object; the AA-TripPlanner-Web deploy
  # workflow replaces the actual code via lambda:UpdateFunctionCode. Terraform
  # ignore_changes the code attributes so it never reverts the app's deploy.
  s3_bucket = aws_s3_bucket.tripplanner_artifacts.id
  s3_key    = "browse.zip"

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
      TRIPPLANNER_API_KEY          = random_password.tripplanner_api_key.result
    }
  }

  tags = local.tp_tags

  # The S3 object (placeholder) must exist before CreateFunction.
  depends_on = [aws_s3_object.tripplanner_browse_zip]

  lifecycle {
    ignore_changes = [s3_object_version, source_code_hash, s3_key]
  }
}

resource "aws_lambda_function" "tripplanner_assembly" {
  function_name = "${local.tp_name_prefix}-assembly"
  role          = aws_iam_role.tripplanner_lambda_exec.arn
  runtime       = "python3.12"
  handler       = "backend.assembly.handler.handler"
  timeout       = 60
  memory_size   = 512

  # Created from the S3 placeholder (see browse Lambda above); app deploy
  # workflow replaces the code.
  s3_bucket = aws_s3_bucket.tripplanner_artifacts.id
  s3_key    = "assembly.zip"

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
      # global (not us.) — that's what the satellite invoker roles allow;
      # see accounts/acc1-bedrock/bedrock_invoker_import.tf.
      BEDROCK_MODEL_COMPOSE               = "global.anthropic.claude-sonnet-4-6"
      ADVISOR_NOTIFY_EMAIL                = var.tripplanner_advisor_email
      REQUIRE_REGISTRATION_BEFORE_HANDOFF = "true"
      TRIPPLANNER_API_KEY                 = random_password.tripplanner_api_key.result
    }
  }

  tags = local.tp_tags

  # The S3 object (placeholder) must exist before CreateFunction.
  depends_on = [aws_s3_object.tripplanner_assembly_zip]

  lifecycle {
    ignore_changes = [s3_object_version, source_code_hash, s3_key]
  }
}

# -----------------------------------------------------------------------------
# API Gateway (HTTP API v2) — the public entry point, same "API Gateway in
# front of the compute" pattern AA-CIS uses (AA-CIS fronts ECS via a REST API
# + VPC Link; TripPlanner fronts Lambda via an HTTP API + AWS_PROXY). Chosen
# over public Lambda Function URLs because the org SCP blocks unauthenticated
# Function URLs (verified: AuthType=NONE returned 403 AccessDenied at the org
# edge). The frontend BFF calls this API; the Lambdas keep no public URL.
#
# HTTP API payload format 2.0 matches the event shape the handlers already
# parse (requestContext.http.method/path + rawPath).
#
# Routes:
#   ANY /browse/{proxy+} -> browse Lambda   (stateless, cacheable reads)
#   ANY /trip/{proxy+}   -> assembly Lambda (stateful + Bedrock)
# Auth is NONE at the edge for MVP dev (the BFF is the only caller) — add a
# JWT/authorizer before real use.
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "tripplanner" {
  name          = "${local.tp_name_prefix}-api"
  protocol_type = "HTTP"
  tags          = local.tp_tags

  # Tagging (provider default_tags -> apigateway:TagResource) — wait for the
  # CI/CD role's TagResource grant to propagate, same as the stage below.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_apigatewayv2_integration" "tripplanner_browse" {
  api_id                 = aws_apigatewayv2_api.tripplanner.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.tripplanner_browse.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "tripplanner_assembly" {
  api_id                 = aws_apigatewayv2_api.tripplanner.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.tripplanner_assembly.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "tripplanner_browse" {
  api_id    = aws_apigatewayv2_api.tripplanner.id
  route_key = "ANY /browse/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.tripplanner_browse.id}"
}

resource "aws_apigatewayv2_route" "tripplanner_assembly" {
  api_id    = aws_apigatewayv2_api.tripplanner.id
  route_key = "ANY /trip/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.tripplanner_assembly.id}"
}

resource "aws_apigatewayv2_stage" "tripplanner" {
  api_id      = aws_apigatewayv2_api.tripplanner.id
  name        = "$default"
  auto_deploy = true
  tags        = local.tp_tags

  # Creating the stage calls apigateway:TagResource (provider default_tags).
  # That grant was added to the CI/CD role in the same apply, so wait for IAM
  # propagation first — same mitigation the tagged IAM roles use.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_lambda_permission" "tripplanner_browse_apigw" {
  statement_id  = "AllowApiGwInvokeBrowse"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tripplanner_browse.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.tripplanner.execution_arn}/*/*"
}

resource "aws_lambda_permission" "tripplanner_assembly_apigw" {
  statement_id  = "AllowApiGwInvokeAssembly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tripplanner_assembly.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.tripplanner.execution_arn}/*/*"
}

# The BFF calls "<api_base>/browse/..." and "<api_base>/trip/...".
output "tripplanner_api_base_url" {
  value = aws_apigatewayv2_stage.tripplanner.invoke_url
}

output "tripplanner_lambda_exec_role_arn" {
  value = aws_iam_role.tripplanner_lambda_exec.arn
}

# -----------------------------------------------------------------------------
# App deploy role — assumed via GitHub OIDC by the AA-TripPlanner-Web repo's
# deploy workflow ONLY. Least-privilege: put the build zip in the artifacts
# bucket + update the two Lambdas' code. Nothing else. Separate from the
# aa-cis-dev-role CI/CD role (which is broad); this keeps the app repo's
# blast radius to exactly "ship TripPlanner Lambda code".
#
# Trust is scoped to this one repo (any branch) via the sub claim, reusing the
# existing GitHub OIDC provider (cicd.tf).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tripplanner_app_deploy" {
  name = "${local.tp_name_prefix}-app-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # This org/repo has GitHub's "include owner/repo ID in the OIDC
        # subject" customization ON, so the real sub is
        #   repo:AdventureAsia365-CIS@<orgid>/AA-TripPlanner-Web@<repoid>:ref:...
        # (confirmed via CloudTrail). The "@<id>" segments are why a plain
        # repo:Org/Repo:* pattern failed with AccessDenied. Match with wildcards
        # around each "@<id>" while still pinning the org + repo names.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:AdventureAsia365-CIS*/AA-TripPlanner-Web*:*"
        }
      }
    }]
  })

  tags = local.tp_tags

  # Tagged role -> CreateRole calls iam:TagRole; wait for the widened CI/CD
  # grant (cicd.tf "TripPlannerRoleTagging") to propagate first.
  depends_on = [time_sleep.wait_for_iam_propagation]
}

resource "aws_iam_role_policy" "tripplanner_app_deploy" {
  name = "${local.tp_name_prefix}-app-deploy-policy"
  role = aws_iam_role.tripplanner_app_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutArtifacts"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.tripplanner_artifacts.arn}/*"
      },
      {
        Sid    = "UpdateLambdaCode"
        Effect = "Allow"
        # GetFunctionConfiguration is what the `aws lambda wait
        # function-updated` waiter polls after UpdateFunctionCode.
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
        ]
        Resource = [
          aws_lambda_function.tripplanner_browse.arn,
          aws_lambda_function.tripplanner_assembly.arn,
        ]
      },
    ]
  })
}

output "tripplanner_app_deploy_role_arn" {
  value = aws_iam_role.tripplanner_app_deploy.arn
}

output "tripplanner_artifacts_bucket" {
  value = aws_s3_bucket.tripplanner_artifacts.id
}

output "tripplanner_api_key_secret_arn" {
  value = aws_secretsmanager_secret.tripplanner_api_key.arn
}
