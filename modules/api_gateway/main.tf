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

# =============================================================================
# /v1/{v1_proxy+} — B2B tenant routes, gated by Lambda Authorizer (X-API-Key)
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
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant_key.id

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

  request_parameters = {
    "integration.request.path.v1_proxy" = "method.request.path.v1_proxy"
  }
}

# =============================================================================
# Deployment — force redeploy whenever any integration URI or authorizer changes
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
      aws_api_gateway_integration.v1.uri,
      aws_api_gateway_authorizer.tenant_key.id,
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
