# =============================================================================
# AA-CIS API Gateway Module — AA-13
# REST API + TOKEN authorizer + HTTP_PROXY to ALB + usage plans + custom domain
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

# {proxy+} resource — catches all paths
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

# ANY method on {proxy+} with tenant authorizer
resource "aws_api_gateway_method" "proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant_key.id

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# HTTP_PROXY integration → ALB (internet-facing, no NLB needed)
resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_any.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${var.alb_dns_name}/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# Root (/) method — required for health checks and base path calls
resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_rest_api.this.root_resource_id
  http_method   = "ANY"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.tenant_key.id
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_rest_api.this.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${var.alb_dns_name}"
}

# Deployment
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
  ]
  triggers = {
    redeployment = sha1(join(",", [
      aws_api_gateway_integration.proxy.uri,
      aws_api_gateway_integration.root.uri,
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
  domain_name              = "api-cis.lumiguides.it.com"
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
