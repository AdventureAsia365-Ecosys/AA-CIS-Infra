# =============================================================================
# AA-CIS API Gateway Module — AA-13
# REST API + TOKEN authorizer scoped to /v1/* only
# All other routes (admin, content, docs, auth, health) use NONE — FastAPI JWT.
# =============================================================================

# REST API
resource "aws_api_gateway_rest_api" "this" {
  name = "${var.project}-${var.environment}-api"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = var.tags
}

# Lambda Authorizer — validates X-API-Key against shared.tenants.api_key_hash
resource "aws_api_gateway_authorizer" "tenant_key" {
  name                             = "tenant-key-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  type                             = "TOKEN"
  identity_source                  = "method.request.header.X-API-Key"
  authorizer_uri                   = var.authorizer_lambda_invoke_arn
  authorizer_result_ttl_in_seconds = 300
}

# Root (/) — NONE auth, passes through to ALB root
resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_rest_api.this.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_rest_api.this.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}"
}

# =============================================================================
# Public resources — NONE authorization (protected by FastAPI JWT middleware)
# =============================================================================

# /health — unauthenticated health check
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "health" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/health"
}

# /auth/{auth_proxy+} — login, refresh, verify (no API key required)
resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "auth"
}

resource "aws_api_gateway_resource" "auth_proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "{auth_proxy+}"
}

resource "aws_api_gateway_method" "auth_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.auth_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.auth_proxy" = true
  }
}

resource "aws_api_gateway_integration" "auth" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.auth_proxy.id
  http_method             = aws_api_gateway_method.auth_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/auth/{auth_proxy}"

  request_parameters = {
    "integration.request.path.auth_proxy" = "method.request.path.auth_proxy"
  }
}

# /admin/{admin_proxy+} — internal admin routes, protected by FastAPI JWT
resource "aws_api_gateway_resource" "admin" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "admin"
}

resource "aws_api_gateway_resource" "admin_proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.admin.id
  path_part   = "{admin_proxy+}"
}

resource "aws_api_gateway_method" "admin_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.admin_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.admin_proxy" = true
  }
}

resource "aws_api_gateway_integration" "admin" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.admin_proxy.id
  http_method             = aws_api_gateway_method.admin_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/admin/{admin_proxy}"

  request_parameters = {
    "integration.request.path.admin_proxy" = "method.request.path.admin_proxy"
  }
}

# /content/{content_proxy+} — content team routes, protected by FastAPI JWT
resource "aws_api_gateway_resource" "content" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "content"
}

resource "aws_api_gateway_resource" "content_proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.content.id
  path_part   = "{content_proxy+}"
}

resource "aws_api_gateway_method" "content_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.content_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.content_proxy" = true
  }
}

resource "aws_api_gateway_integration" "content" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.content_proxy.id
  http_method             = aws_api_gateway_method.content_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/content/{content_proxy}"

  request_parameters = {
    "integration.request.path.content_proxy" = "method.request.path.content_proxy"
  }
}

# /docs — FastAPI Swagger UI (no auth)
resource "aws_api_gateway_resource" "docs" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "docs"
}

resource "aws_api_gateway_method" "docs" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.docs.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "docs" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.docs.id
  http_method             = aws_api_gateway_method.docs.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/docs"
}

# /openapi.json — FastAPI OpenAPI schema (no auth)
resource "aws_api_gateway_resource" "openapi" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "openapi.json"
}

resource "aws_api_gateway_method" "openapi" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.openapi.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "openapi" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.openapi.id
  http_method             = aws_api_gateway_method.openapi.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/openapi.json"
}

# /redoc — FastAPI ReDoc UI (no auth)
resource "aws_api_gateway_resource" "redoc" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "redoc"
}

resource "aws_api_gateway_method" "redoc" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.redoc.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "redoc" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.redoc.id
  http_method             = aws_api_gateway_method.redoc.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/redoc"
}

# /docs/oauth2-redirect — FastAPI Swagger OAuth2 redirect helper (no auth)
resource "aws_api_gateway_resource" "docs_oauth2_redirect" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.docs.id
  path_part   = "oauth2-redirect"
}

resource "aws_api_gateway_method" "docs_oauth2_redirect" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.docs_oauth2_redirect.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "docs_oauth2_redirect" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.docs_oauth2_redirect.id
  http_method             = aws_api_gateway_method.docs_oauth2_redirect.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/docs/oauth2-redirect"
}

# =============================================================================
# /v1/{v1_proxy+} — B2B tenant routes.
#
# AA-432: was CUSTOM (tenant_key TOKEN authorizer, X-API-Key gate) — removed
# 22/08/2026. STEP0 (docs/claude_audit/AA-432-api-gateway-401-step0.md, AA-CIS-App
# repo) confirmed the FE tenant-portal BFF proxy never sent X-API-Key (only
# `Authorization: Bearer <JWT>`), so every /v1/* call 401'd at the gateway edge
# before FastAPI ever ran. Confirmed separately (same report, §5) that
# api/routers/v1_tours.py's get_tenant() decodes the JWT itself and never reads
# any tenant context the authorizer would have attached — so the gateway's
# X-API-Key check was a redundant coarse edge gate, not the real source of
# per-tenant auth. JWT (verified in FastAPI) is now the only auth boundary for
# /v1/*, matching NONE at the gateway for /admin, /auth, /content already.
# Per-tenant rate-limit/revoke moves to the app layer (Redis, api/main.py) —
# see get_tenant() in v1_tours.py. The `tenant_key` authorizer resource above is
# deliberately left declared (not deleted) — nothing else references it, but
# removing the Lambda/authorizer itself is a separate cleanup task, out of
# scope here (task instruction: don't delete the Lambda in this change).
# =============================================================================

resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "v1_proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "{v1_proxy+}"
}

resource "aws_api_gateway_method" "v1_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.v1_proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.v1_proxy" = true
  }
}

resource "aws_api_gateway_integration" "v1" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.v1_proxy.id
  http_method             = aws_api_gateway_method.v1_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  uri                     = "http://${var.nlb_dns_name}/v1/{v1_proxy}"

  # AA-465 — TEMPORARY patch, parallel to AA-466 (real fix: move /goal + /write to async).
  # Raised from the AWS default 29000 after real measurement (AA-453 STEP0 + AA-465):
  # /goal 30.29s, /write worst-case (2-attempt retry, CloudWatch-confirmed) 57.16s,
  # /s1-from-atom/.../generate 48.13s all real-exceed or approach 29s. 90000 = ~58% margin
  # over the highest real measurement (57.16s), deliberately not maxed to the ~300000
  # ceiling — this single integration is a catch-all for ALL of /v1/*, including
  # latency-sensitive polling routes (execution/{id}, slot-grid, requests/{id}) that
  # should still fail fast on a real backend hang, not just LLM-writing routes.
  # Requires Service Quota L-E5AE38E3 raised first (requested 26/08/2026, PENDING as of
  # this commit) — this value has no effect above 29000 until that quota is approved.
  timeout_milliseconds = 90000

  request_parameters = {
    "integration.request.path.v1_proxy" = "method.request.path.v1_proxy"
  }
}

# =============================================================================
# Deployment — force redeploy whenever any integration URI, authorizer, or
# method authorization setting changes.
#
# AA-432: the hash previously only covered integration URIs + the authorizer
# resource's own id — never any method's `authorization`/`authorizer_id`
# attribute. A stage always serves a frozen deployment snapshot; changing a
# method (e.g. v1_any CUSTOM -> NONE) edits the live REST API definition but
# does NOT retarget the stage unless this trigger hash actually changes too.
# Caught this live: the AA-432 plan showed a clean 1-attribute method update
# with nothing here changing, which would have applied "successfully" while
# leaving the dev stage pinned to the OLD deployment — the 401 bug this
# change exists to fix would NOT have actually gone away. Added the 4 gated
# methods' authorization + authorizer_id (coalesced, since NONE leaves
# authorizer_id null and join() can't take a null) so any future change to
# either forces a fresh deployment the same way an integration/authorizer
# change already does.
# =============================================================================

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  depends_on = [
    aws_api_gateway_integration.root,
    aws_api_gateway_integration.health,
    aws_api_gateway_integration.auth,
    aws_api_gateway_integration.admin,
    aws_api_gateway_integration.content,
    aws_api_gateway_integration.docs,
    aws_api_gateway_integration.openapi,
    aws_api_gateway_integration.redoc,
    aws_api_gateway_integration.docs_oauth2_redirect,
    aws_api_gateway_integration.v1,
  ]
  triggers = {
    redeployment = sha1(join(",", [
      aws_api_gateway_integration.root.uri,
      aws_api_gateway_integration.health.uri,
      aws_api_gateway_integration.auth.uri,
      aws_api_gateway_integration.admin.uri,
      aws_api_gateway_integration.content.uri,
      aws_api_gateway_integration.docs.uri,
      aws_api_gateway_integration.openapi.uri,
      # AA-583: added when /redoc + /docs/oauth2-redirect resources were created — same
      # AA-432/AA-465 trap otherwise recurs (new resource/integration added but stage
      # never redeploys because the trigger hash didn't change).
      aws_api_gateway_integration.redoc.uri,
      aws_api_gateway_integration.docs_oauth2_redirect.uri,
      aws_api_gateway_integration.v1.uri,
      # AA-465: same trap AA-432 already caught for authorization — this hash only covers
      # .uri by default, so a timeout_milliseconds-only change on the v1 integration would
      # NOT force a new deployment on its own, leaving the stage silently pinned to the old
      # snapshot (still 29000ms) even after `terraform apply` "succeeds". Added explicitly.
      tostring(aws_api_gateway_integration.v1.timeout_milliseconds),
      aws_api_gateway_authorizer.tenant_key.id,
      aws_api_gateway_method.v1_any.authorization,
      coalesce(aws_api_gateway_method.v1_any.authorizer_id, "none"),
      aws_api_gateway_method.admin_any.authorization,
      aws_api_gateway_method.auth_any.authorization,
      aws_api_gateway_method.content_any.authorization,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

# Stage
resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment
}

# AA-272 diagnostic only — INFO-level execution logging, gated so account-1's
# root (which doesn't set this var) never enables it. Requires the account's
# aws_api_gateway_account.cloudwatch_role_arn to already be set.
resource "aws_api_gateway_method_settings" "diagnostic_logging" {
  count = var.enable_execution_logging ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.dev.stage_name
  method_path = "*/*"

  settings {
    logging_level      = "INFO"
    data_trace_enabled = false
    metrics_enabled    = true
  }
}

# =============================================================================
# Usage Plans — mapped to plan_tier values in shared.tenants
# =============================================================================

resource "aws_api_gateway_usage_plan" "starter" {
  name = "${var.project}-${var.environment}-starter"
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
  throttle_settings {
    rate_limit  = 1
    burst_limit = 10
  }
  quota_settings {
    limit  = 1000
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan" "growth" {
  name = "${var.project}-${var.environment}-growth"
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
  throttle_settings {
    rate_limit  = 5
    burst_limit = 50
  }
  quota_settings {
    limit  = 5000
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan" "business" {
  name = "${var.project}-${var.environment}-business"
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
  throttle_settings {
    rate_limit  = 17
    burst_limit = 100
  }
  quota_settings {
    limit  = 20000
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan" "internal" {
  name = "${var.project}-${var.environment}-internal"
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
  throttle_settings {
    rate_limit  = 100
    burst_limit = 500
  }
}

# =============================================================================
# Custom Domain + Base Path Mapping
# =============================================================================

resource "aws_api_gateway_domain_name" "api_cis" {
  domain_name              = var.domain_name
  regional_certificate_arn = var.acm_cert_arn_us_east1
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = var.tags
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.dev.stage_name
  domain_name = aws_api_gateway_domain_name.api_cis.domain_name
}

# =============================================================================
# Lambda Permission — allow API Gateway to invoke the authorizer
# =============================================================================

resource "aws_lambda_permission" "api_gateway_authorizer" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
