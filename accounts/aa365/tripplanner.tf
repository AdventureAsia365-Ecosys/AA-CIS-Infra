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
#       role acc3 AA3-Bedrock-Invoker (the only LLM satellite since AA-998;
#       the acc1 fallback is retired) — same pattern as module.ecs's task role
#       (see bedrock_satellite_assume.tf). The TRUST side (adding this Lambda
#       role as a principal on that role) lives in accounts/acc3-bedrock and
#       is applied by a human; this file only grants the caller-side
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
    App         = "tripplanner" # S235 Phase 0: per-app cost allocation tag (additive)
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
  #
  # AA-856 (S239): the GLOBAL cross-region profile as well. The `us.` profile's
  # requests-per-minute quota (L-EB8C1F30) is fixed at 20; the global one
  # (L-7089DC7D) is adjustable (increase requested, case 179212369200770), so
  # CIS migration 238 points shared.llm_model_catalog 'cohere-embed-v4' acc2 at
  # global.cohere.embed-v4:0. A global profile routes to any commercial region;
  # its models are the regionless foundation-model ARN (already granted) plus
  # the source region's. The `us.` grant stays: the Lambdas' built-in route
  # (used only when the catalog is unreadable) and a rollback of 238 use it.
  # Apply this BEFORE DB Migrate applies 238.
  tp_embed_model_arns = [
    local.tp_embed_profile_arn,
    "arn:aws:bedrock:*:${var.account_id}:inference-profile/us.cohere.embed-v4:0",
    "arn:aws:bedrock:*:${var.account_id}:inference-profile/global.cohere.embed-v4:0",
    "arn:aws:bedrock:*::foundation-model/cohere.embed-v4:0",
    "arn:aws:bedrock:::foundation-model/cohere.embed-v4:0",
  ]

  # Satellite invoker role (Claude). Same ARN AA-CIS uses; acc3 only (AA-998).
  tp_satellite_invoker_arns = [
    "arn:aws:iam::786888028788:role/AA3-Bedrock-Invoker", # acc3
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
# stored in Secrets Manager, the single source of truth: since AA-878 (S243) the
# Lambdas read it by name at run time (IAM grant ReadApiKeySecret below), and
# Nghiep copies the same value into the Vercel TRIPPLANNER_API_KEY by hand.
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
# AA-871: Sentry DSN for both Lambdas (project aa-tripplanner-lambdas) — SHELL ONLY: no secret_version,
# Terraform never holds the DSN (so terraform plan never reads it either, nothing to add to
# tf_plan_secret_arns). Same run-time pattern as the edge key (AA-878): the Lambdas read it by NAME,
# tripplanner/<ENVIRONMENT>/sentry-dsn, once per cold start (backend/shared/observability.py in
# AA-TripPlanner-Web; grant ReadSentryDsnSecret below), so no DSN in the Lambda environment and no
# Lambda update when it is set or rotated (new containers pick it up). Until a value is put, the read
# fails with ResourceNotFoundException and Sentry stays off (logged sentry_disabled); requests are not
# affected. The CIS task role cannot read it (modules/ecs DenyMasterAndOtherAppSecrets, tripplanner/*).
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "tripplanner_sentry_dsn" {
  name                    = "tripplanner/${var.environment}/sentry-dsn"
  description             = "AA-TripPlanner Sentry DSN (project aa-tripplanner-lambdas), read by name at cold start by browse + assembly. Value set out-of-band."
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
  tags                    = merge(local.tp_tags, { Issue = "AA-871" })
}

# -----------------------------------------------------------------------------
# AA-878 (S243): the Mapbox geocoding token secret (AA-675, tour-day extraction) has had no reader
# since AA-712 slice 6a moved extraction to CIS: no code on main reads MAPBOX_GEOCODING_TOKEN_ARN,
# and CloudTrail since 18/10 shows only the plan role (refresh) reading it. Terraform FORGETS the
# secret and its version here; it does not delete them (recovery_window_in_days was 0 in dev, so a
# plain resource removal would have deleted the secret at once, with no recovery). The secret is
# then deleted by hand with a 30-day recovery window after a DRY RUN (AA-878 step M2), and the
# token itself is revoked in the Mapbox account.
# -----------------------------------------------------------------------------
removed {
  from = aws_secretsmanager_secret.tripplanner_mapbox

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.tripplanner_mapbox

  lifecycle {
    destroy = false
  }
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
    # metadata: deploy-lambdas.yml writes git-sha / app-version / code-sha256 on upload (AA-993 V4 verify).
    ignore_changes = [etag, source, metadata]
  }

  # AA-846: the App deploy workflow uploads with `aws s3 cp`, which replaces the object and drops
  # its object tags. With the provider default_tags, every plan then showed `tags_all` +4 tags on
  # both zips and every apply re-tagged them. These two objects carry no tags at all (S3 object
  # tags are not used for cost allocation; the bucket keeps its tags), so the plan matches what
  # the deploy leaves and stays "No changes".
  override_provider {
    default_tags {
      tags = {}
    }
  }
}

resource "aws_s3_object" "tripplanner_assembly_zip" {
  bucket = aws_s3_bucket.tripplanner_artifacts.id
  key    = "assembly.zip"
  source = local.tp_placeholder_zip
  etag   = filemd5(local.tp_placeholder_zip)

  lifecycle {
    # metadata: deploy-lambdas.yml writes git-sha / app-version / code-sha256 on upload (AA-993 V4 verify).
    ignore_changes = [etag, source, metadata]
  }

  # AA-846: same as tripplanner_browse_zip (no object tags; `aws s3 cp` drops them).
  override_provider {
    default_tags {
      tags = {}
    }
  }
}

# -----------------------------------------------------------------------------
# Lambda execution role (shared by both TripPlanner Lambdas).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "tripplanner_lambda_exec" {
  name                 = "${local.tp_name_prefix}-lambda-exec"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

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
        # AA-878: the edge key is read by name (tripplanner/<ENVIRONMENT>/api-key) at run time,
        # never passed as a plaintext env value (backend/shared/auth.py in AA-TripPlanner-Web).
        Sid      = "ReadApiKeySecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_api_key.arn]
      },
      {
        # AA-871: the Sentry DSN, read by name (tripplanner/<ENVIRONMENT>/sentry-dsn) at cold start,
        # never a plaintext env value (backend/shared/observability.py in AA-TripPlanner-Web).
        Sid      = "ReadSentryDsnSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.tripplanner_sentry_dsn.arn]
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

  # AA-824 connection budget: cap concurrent instances (each opens its own DB pool).
  reserved_concurrent_executions = var.tripplanner_browse_reserved_concurrency

  # Created from the S3 placeholder object; the AA-TripPlanner-Web deploy
  # workflow replaces the actual code via lambda:UpdateFunctionCode. Terraform
  # ignore_changes the code attributes so it never reverts the app's deploy.
  s3_bucket = aws_s3_bucket.tripplanner_artifacts.id
  s3_key    = "browse.zip"

  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [aws_security_group.tp_lambda.id] # ADR 0004b (X1 S13b)
  }

  environment {
    variables = {
      # ENVIRONMENT also names the edge-key secret the app reads (tripplanner/<ENVIRONMENT>/api-key,
      # AA-878): no plaintext key in the function config.
      ENVIRONMENT                  = var.environment
      TRIPPLANNER_DATABASE_URL_ARN = aws_secretsmanager_secret.tripplanner_db.arn
      BEDROCK_REGION               = var.aws_region
      # AA-902: account IDs left the public TripPlanner repo; browse embeds through the same satellite
      # (acc3 only, AA-998).
      BEDROCK_ACCT_PRIMARY = local.bedrock_acct_primary
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

  # AA-824 connection budget: cap concurrent instances (each opens its own DB pool).
  reserved_concurrent_executions = var.tripplanner_lambda_reserved_concurrency

  # Created from the S3 placeholder (see browse Lambda above); app deploy
  # workflow replaces the code.
  s3_bucket = aws_s3_bucket.tripplanner_artifacts.id
  s3_key    = "assembly.zip"

  vpc_config {
    subnet_ids         = module.vpc.private_subnet_ids
    security_group_ids = [aws_security_group.tp_lambda.id] # ADR 0004b (X1 S13b)
  }

  environment {
    variables = {
      ENVIRONMENT                  = var.environment
      TRIPPLANNER_DATABASE_URL_ARN = aws_secretsmanager_secret.tripplanner_db.arn
      BEDROCK_REGION               = var.aws_region
      BEDROCK_ACCT_PRIMARY         = local.bedrock_acct_primary
      # acc3 is the only satellite (AA-998: the acc1 fallback env is gone).
      BEDROCK_ROLE_NAME_PRIMARY   = "AA3-Bedrock-Invoker"
      BEDROCK_EXTERNAL_ID_PRIMARY = "aa296-satellite-bedrock-acc3"
      # No ADVISOR_NOTIFY_EMAIL: the advisor e-mail is sent by AA-Booking (bk_notify_email, AA-811 S238).
      REQUIRE_REGISTRATION_BEFORE_HANDOFF = "true"
      # AA-878: no TRIPPLANNER_API_KEY here (read by name from Secrets Manager, see browse) and no
      # MAPBOX_GEOCODING_TOKEN_ARN (no reader since AA-712 slice 6a).
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
#   GET /browse/search, POST /trip/{trip_id}/narrate -> same Lambdas, own
#     tighter throttles (LLM cost per request, AA-806)
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

# AA-908: the signed-in traveller routes (/me/trips, /me/claim) live in the assembly Lambda, which routes on
# requestContext.http.path; without this route API Gateway answers 404 and the BFF shows My Trips as 502.
# The Lambda permission already allows any route of this API (/*/*), so no IAM change.
resource "aws_apigatewayv2_route" "tripplanner_me" {
  api_id    = aws_apigatewayv2_api.tripplanner.id
  route_key = "ANY /me/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.tripplanner_assembly.id}"
}

# AA-806 (from AA-805): narration is the one LLM-backed call (compose/renarrate on the satellite
# Bedrock roles), so it gets its own route with a lower throttle than the rest of /trip. A specific
# route wins over the greedy ANY /trip/{proxy+}; both go to the same assembly integration, and the
# handler routes on requestContext.http.path, which is the same either way.
resource "aws_apigatewayv2_route" "tripplanner_narrate" {
  api_id    = aws_apigatewayv2_api.tripplanner.id
  route_key = "POST /trip/{trip_id}/narrate"
  target    = "integrations/${aws_apigatewayv2_integration.tripplanner_assembly.id}"
}

# AA-806: free-text search is the other per-request LLM cost (one Cohere embedding call per query,
# backend/browse/search.py), so it gets its own route and a moderate throttle. It is a specific route
# over the greedy ANY /browse/{proxy+}, same browse integration; the handler matches rawPath
# /browse/search either way. Tiles, destinations, countries, routes and by-country stay on the greedy
# route with the generous stage default: the map fetches one tile per 1-degree cell with Promise.all
# on every moveend/filter change, so a tight default throttles the map itself (429s).
resource "aws_apigatewayv2_route" "tripplanner_search" {
  api_id    = aws_apigatewayv2_api.tripplanner.id
  route_key = "GET /browse/search"
  target    = "integrations/${aws_apigatewayv2_integration.tripplanner_browse.id}"
}

resource "aws_apigatewayv2_stage" "tripplanner" {
  api_id      = aws_apigatewayv2_api.tripplanner.id
  name        = "$default"
  auto_deploy = true
  tags        = local.tp_tags

  # AA-806 (from AA-805): the HTTP API has no auth at the edge and HTTP APIs cannot carry a WAF web
  # ACL, so stage throttling is the only cap in front of the Lambdas. default_route_settings applies
  # per route (each route its own bucket), not as one stage-wide cap. The limits are shared by every
  # caller (the Vercel BFF is the only one), not per client. The default is deliberately generous
  # (map tile fan-out, see the search route above); tight limits sit only on the two LLM-cost routes.
  # Numbers (Dev placeholders): tripplanner_variables.tf.
  default_route_settings {
    throttling_rate_limit  = var.tripplanner_throttle_rate_limit
    throttling_burst_limit = var.tripplanner_throttle_burst_limit
  }

  route_settings {
    route_key              = aws_apigatewayv2_route.tripplanner_narrate.route_key
    throttling_rate_limit  = var.tripplanner_narrate_throttle_rate_limit
    throttling_burst_limit = var.tripplanner_narrate_throttle_burst_limit
  }

  route_settings {
    route_key              = aws_apigatewayv2_route.tripplanner_search.route_key
    throttling_rate_limit  = var.tripplanner_search_throttle_rate_limit
    throttling_burst_limit = var.tripplanner_search_throttle_burst_limit
  }

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
# CIS CI/CD roles (cicd_split.tf); this keeps the app repo's
# blast radius to exactly "ship TripPlanner Lambda code".
#
# Trust is pinned to ONE exact OIDC subject (S235 Phase 0): this repo by immutable
# org + repo id, and only the context its deploy workflow actually produces. Reuses
# the existing GitHub OIDC provider (cicd.tf).
# -----------------------------------------------------------------------------
locals {
  # S235 Phase 0: exact OIDC subjects for aa-tripplanner-dev-app-deploy (see the trust comment).
  tp_oidc_sub_prefix = "repo:AdventureAsia365-Ecosys@276539096/AA-TripPlanner-Web@1365222661"
  tp_oidc_subjects   = ["${local.tp_oidc_sub_prefix}:ref:refs/heads/main"]
}

resource "aws_iam_role" "tripplanner_app_deploy" {
  name                 = "${local.tp_name_prefix}-app-deploy"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # The AA-TripPlanner-Web repo has GitHub's immutable OIDC subject ON (read 14/10/2026 via
        # GET /repos/AdventureAsia365-Ecosys/AA-TripPlanner-Web/actions/oidc/customization/sub:
        # use_immutable_subject=true, sub_claim_prefix below; repo id 1365222661, org id 276539096).
        #
        # Two workflows assume this role, both with no `environment:`, so the sub context is the ref ->
        # `ref:refs/heads/main`: .github/workflows/deploy-lambdas.yml job `deploy` (push to main, paths
        # backend/**, or workflow_dispatch), and the read-only post-deploy-verify.yml job `lambdas`
        # (AA-993 V4: GetFunctionConfiguration + GetObject/HeadObject, called by deploy-lambdas.yml or
        # dispatched from main). A dispatch from any other branch, a pull_request run or a tag is
        # denied. ci.yml has no id-token permission.
        #
        # History: AA-588 used "repo:AdventureAsia365-Ecosys*/AA-TripPlanner-Web*:*" (any branch,
        # any id). S235 Phase 0 replaces it with the exact subject (StringEquals, fail closed): if the
        # repo is renamed/re-created, the immutable subject is turned off, or the deploy job gains an
        # `environment:`, re-read the prefix with the call above and update tp_oidc_subjects.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.tp_oidc_subjects
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
