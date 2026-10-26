# =============================================================================
# AA-818 (S237, decision D5) — custom domains for AA-Booking and TripPlanner on lumiguides.it.com.
#
# Today AA-Booking is served on 9z3xnalp59.execute-api.../dev and TripPlanner on
# 9vqkfbukvh.execute-api... + aa-tripplanner.vercel.app. ADR 0004 O2 fixed api-booking.; ADR 0006
# decision 10 fixed auth. (EXTERNAL) and staff-auth. (WORKFORCE) for the Cognito custom domains.
#
# Two stages, because the zone (dns.tf, AA-811) is not served until Nghiep switches the
# nameservers at Namecheap:
#
#   Always (safe before the NS switch, nothing is served from the zone yet):
#     - ACM cert us-west-1  api-booking. + api-tripplanner.   (API GW REGIONAL custom domains)
#     - ACM cert us-east-1  auth. + staff-auth.               (Cognito custom domains, CloudFront;
#                                                              consumed by AA-703 identity.tf via
#                                                              output auth_custom_domain_certificate_arn)
#     - their DNS-validation CNAMEs in the Route 53 zone. The certs stay PENDING_VALIDATION until
#       the switch, then ACM validates on its own (no apply needed) and they become ISSUED.
#
#   Only with var.custom_domains_enabled = true (after the switch, certs ISSUED):
#     - aws_acm_certificate_validation waits (would block an apply for up to 75 min before the switch)
#     - REST API custom domain api-booking. + EMPTY base path mapping -> aa-booking-dev-api stage dev
#       (routes keep their /booking prefix: https://api-booking.../booking/health/ready)
#     - HTTP API custom domain api-tripplanner. + API mapping -> aa-tripplanner-dev-api $default
#       (https://api-tripplanner.../browse/..., /trip/...)
#     - Route 53 A alias records for both, and the Vercel frontend CNAMEs (var.custom_domain_vercel_hosts)
#
# Not here: the Cognito custom domains themselves (AA-703/AA-816, identity.tf) and the apex A record
# they need (AA-816, dns.tf); app env / CORS / canonical / Mapbox URL restriction (TripPlanner and Booking lanes);
# the hand-made api-cis. domain + cert (still outside state, records copied in dns.tf).
#
# The WAF association on the Booking REST stage (var.waf_protect_rest_api_stages) is per stage, so
# it covers traffic through the custom domain too. HTTP APIs (TripPlanner) cannot carry a web ACL;
# their stage throttles (tripplanner.tf) apply the same through the custom domain.
# =============================================================================

locals {
  cd_tags = merge(local.ecosys_tags, { App = "shared", Issue = "AA-818" })

  cd_booking_api_host     = "api-booking.${var.dns_zone_name}"
  cd_tripplanner_api_host = "api-tripplanner.${var.dns_zone_name}"
  cd_auth_external_host   = "auth.${var.dns_zone_name}"       # ADR 0006: EXTERNAL pool
  cd_auth_workforce_host  = "staff-auth.${var.dns_zone_name}" # ADR 0006: WORKFORCE pool

  cd_enabled = var.custom_domains_enabled ? 1 : 0
}

# -----------------------------------------------------------------------------
# Certificates + DNS validation records (unconditional)
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "api" {
  domain_name               = local.cd_booking_api_host
  subject_alternative_names = [local.cd_tripplanner_api_host]
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  tags = merge(local.cd_tags, { Name = "aa-ecosys-dev-api-domains" })

  # An API GW domain keeps pointing at the certificate it was created with: a SAN change replaces
  # the cert, so create the new one before the old one goes.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "auth" {
  provider = aws.us_east_1

  domain_name               = local.cd_auth_external_host
  subject_alternative_names = [local.cd_auth_workforce_host]
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048" # Cognito custom domains accept RSA 2048 only

  tags = merge(local.cd_tags, { Name = "aa-ecosys-dev-auth-domains" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # One validation CNAME per host name, from both certificates. Key = the host name, known at plan.
  cd_validation_records = merge(
    { for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => dvo },
    { for dvo in aws_acm_certificate.auth.domain_validation_options : dvo.domain_name => dvo },
  )
}

resource "aws_route53_record" "acm_validation" {
  for_each = local.cd_validation_records

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

# -----------------------------------------------------------------------------
# Gated: validation waits (block until ISSUED), only after the NS switch
# -----------------------------------------------------------------------------
resource "aws_acm_certificate_validation" "api" {
  count = local.cd_enabled

  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for host in [local.cd_booking_api_host, local.cd_tripplanner_api_host] : aws_route53_record.acm_validation[host].fqdn]
}

resource "aws_acm_certificate_validation" "auth" {
  count    = local.cd_enabled
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.auth.arn
  validation_record_fqdns = [for host in [local.cd_auth_external_host, local.cd_auth_workforce_host] : aws_route53_record.acm_validation[host].fqdn]
}

# -----------------------------------------------------------------------------
# Gated: AA-Booking REST API custom domain (api-booking.)
# -----------------------------------------------------------------------------
resource "aws_api_gateway_domain_name" "booking" {
  count = local.cd_enabled

  domain_name              = local.cd_booking_api_host
  regional_certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = merge(local.cd_tags, { App = "booking" })
}

# Empty base path: the REST API's own resources start at /booking, so the public URL is
# https://api-booking.lumiguides.it.com/booking/... exactly like the execute-api .../dev/booking/...
resource "aws_api_gateway_base_path_mapping" "booking" {
  count = local.cd_enabled

  api_id      = aws_api_gateway_rest_api.booking.id
  stage_name  = aws_api_gateway_stage.booking.stage_name
  domain_name = aws_api_gateway_domain_name.booking[0].domain_name
}

resource "aws_route53_record" "booking_api" {
  count = local.cd_enabled

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.cd_booking_api_host
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.booking[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.booking[0].regional_zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# Gated: TripPlanner HTTP API custom domain (api-tripplanner.)
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_domain_name" "tripplanner" {
  count = local.cd_enabled

  domain_name = local.cd_tripplanner_api_host

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(local.cd_tags, { App = "tripplanner" })
}

# No api_mapping_key: the routes already start at /browse and /trip.
resource "aws_apigatewayv2_api_mapping" "tripplanner" {
  count = local.cd_enabled

  api_id      = aws_apigatewayv2_api.tripplanner.id
  domain_name = aws_apigatewayv2_domain_name.tripplanner[0].id
  stage       = aws_apigatewayv2_stage.tripplanner.id
}

resource "aws_route53_record" "tripplanner_api" {
  count = local.cd_enabled

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.cd_tripplanner_api_host
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.tripplanner[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.tripplanner[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# Gated: Vercel frontends (tripplanner., later booking.). No ACM: Vercel issues its own certificate
# once the CNAME resolves. Add the domain to the Vercel project before turning this on.
# -----------------------------------------------------------------------------
resource "aws_route53_record" "vercel_frontend" {
  for_each = var.custom_domains_enabled ? var.custom_domain_vercel_hosts : {}

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = "${each.key}.${var.dns_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [each.value]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "custom_domain_certificates" {
  description = "AA-818 certificates. Both must be ISSUED (aws acm describe-certificate) before custom_domains_enabled = true."
  value = {
    api_us_west_1  = aws_acm_certificate.api.arn
    auth_us_east_1 = aws_acm_certificate.auth.arn
  }
}

output "auth_custom_domain_certificate_arn" {
  description = "us-east-1 certificate for auth. + staff-auth. (identity.tf uses it directly unless var.identity_custom_domain_certificate_arn overrides it)."
  value       = aws_acm_certificate.auth.arn
}

output "custom_domain_urls" {
  description = "Public base URLs once custom_domains_enabled = true (empty before)."
  value = var.custom_domains_enabled ? {
    booking_api     = "https://${local.cd_booking_api_host}/booking"
    tripplanner_api = "https://${local.cd_tripplanner_api_host}"
    frontends       = concat([for label in keys(var.custom_domain_vercel_hosts) : "https://${label}.${var.dns_zone_name}"], ["https://${local.crm_agency_host}"])
  } : null
}
