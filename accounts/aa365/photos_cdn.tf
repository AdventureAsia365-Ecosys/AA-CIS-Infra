# =============================================================================
# AA-844 (S246) — CloudFront in front of the bronze bucket's photos/ prefix (Jira PR-11 promise).
#
# photo_sync (AA-708, AA-CIS-App services/photos/sync.py) writes
#   s3://<bronze>/photos/<country slug>/<drive file id>-{1600,600}.webp   (and -orig.<ext>)
# with CacheControl "public, max-age=31536000". The CIS route /content/photos/{id} answers a 302;
# from AA-844 its target is https://img.lumiguides.it.com/<slug>/<file>?v=<sha256[:12]> on this
# distribution (presigned S3 URL only as a fallback), so the catalog views, TripPlanner and the
# Booking admin keep the same /content/photos/{id} path and change nothing.
#
#   viewer -> CloudFront (img.) -> OAC SigV4 -> bronze bucket, origin_path /photos
#
# - The bucket stays private (Block Public Access fully on). modules/s3 adds ONE bucket-policy
#   statement for the CloudFront service principal, GetObject on photos/* only, conditioned on this
#   distribution's ARN. origin_path = /photos means a viewer path can only map under photos/, so
#   scripts/, batch-*/ and raw-*/ in the same bucket stay out of reach even before the policy.
# - No ListBucket: a missing key is a 403 (not a 404 and not a listing).
# - Cache key = path + query string "v" only (the CIS redirect appends ?v=<sha12> of the source
#   bytes, so a Drive edit that overwrites the same key gets a fresh cache entry). No cookies, no
#   headers. TTLs: min 1 day, default and max 1 year; the objects carry max-age=31536000 already.
# - Response headers policy: nosniff + HSTS only. Deliberately NO Cache-Control override: a response
#   headers policy also applies to error responses, so an override would make browsers keep a 403
#   for a key that is not synced yet for a year, and "immutable" is false (keys get overwritten).
# - PriceClass_100 (North America + Europe edges). Viewers are mostly in Asia, so PriceClass_200
#   would be faster; it is a one-line change (var.photos_cdn_price_class) at a slightly higher
#   per-GB price. No access logs, no WAF (static public images; WAF would be ~$5+/month).
#
# Gating follows custom_domains.tf: the certificate and its DNS-validation CNAME are always created
# (harmless before the zone is served); the validation wait, the distribution (which needs an
# ISSUED cert for its alias) and the alias records only when var.custom_domains_enabled (NS switched
# to Route 53, S237) and var.photos_cdn_enabled. The OAC and the two policies are free, unattached
# objects when gated off.
#
# Cost (D-19): CloudFront always-free tier is 1 TB out + 10M requests a month, i.e. ~$0 on Dev.
# Caveat: acc2 is billed through the TrueIDC reseller payer and the free tier is per payer, so it
# may already be used; pay-as-you-go worst case on Dev (~10 GB, ~100k requests) is under $2/month.
# ACM public cert, Route 53 alias queries and S3 -> CloudFront transfer are $0; S3 GETs on cache
# misses ~$0.0004 per 1k.
#
# Apply prerequisite: the CI apply role's PhotosCdnCloudFront grant (cicd_split.tf, applied
# locally first — bootstrap object). The distribution takes ~5-15 minutes to deploy.
# =============================================================================

variable "photos_cdn_enabled" {
  description = "AA-844: create the photos CloudFront distribution, its alias records and the bronze bucket-policy grant. Also needs custom_domains_enabled (certificate validation)."
  type        = bool
  default     = true
}

variable "photos_cdn_subdomain" {
  description = "AA-844: label under dns_zone_name for the photos CDN host (img -> img.lumiguides.it.com). The CIS app's code default PHOTO_CDN_BASE points at this host."
  type        = string
  default     = "img"
}

variable "photos_cdn_price_class" {
  description = "AA-844: CloudFront price class. PriceClass_100 = North America + Europe edges (cheapest); PriceClass_200 adds Asia edges."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.photos_cdn_price_class)
    error_message = "photos_cdn_price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

locals {
  photos_cdn_host   = "${var.photos_cdn_subdomain}.${var.dns_zone_name}"
  photos_cdn_on     = var.photos_cdn_enabled && var.custom_domains_enabled ? 1 : 0
  photos_cdn_prefix = "photos" # S3 prefix photo_sync writes under; also the origin_path
  photos_cdn_tags   = merge(local.cis_app_tags, { Issue = "AA-844" })
}

# -----------------------------------------------------------------------------
# Certificate (us-east-1, CloudFront) + its DNS-validation CNAME (unconditional)
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "photos_cdn" {
  provider = aws.us_east_1

  domain_name       = local.photos_cdn_host
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = merge(local.photos_cdn_tags, { Name = "aa-cis-dev-photos-cdn" })

  # A distribution keeps the certificate it was created with: a host change replaces the cert, so
  # create the new one before the old one goes.
  lifecycle {
    create_before_destroy = true
  }
}

# Separate from aws_route53_record.acm_validation (custom_domains.tf) so the api / auth
# certificates and their records are untouched.
resource "aws_route53_record" "photos_cdn_acm_validation" {
  for_each = { for dvo in aws_acm_certificate.photos_cdn.domain_validation_options : dvo.domain_name => dvo }

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "photos_cdn" {
  count    = local.photos_cdn_on
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.photos_cdn.arn
  validation_record_fqdns = [aws_route53_record.photos_cdn_acm_validation[local.photos_cdn_host].fqdn]
}

# -----------------------------------------------------------------------------
# Origin access control + cache / response headers policies (free, always)
# -----------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "photos_cdn" {
  name                              = "${local.name_prefix}-photos-oac"
  description                       = "AA-844: photos CDN -> bronze bucket photos/ (SigV4)"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "photos_cdn" {
  name        = "${local.name_prefix}-photos-cache"
  comment     = "AA-844: long TTL, cache key = path + ?v= only"
  min_ttl     = 86400
  default_ttl = 31536000
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = ["v"]
      }
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_response_headers_policy" "photos_cdn" {
  name    = "${local.name_prefix}-photos-headers"
  comment = "AA-844: nosniff + HSTS only; no Cache-Control override (errors must not be cached for a year)"

  security_headers_config {
    content_type_options {
      override = true
    }
    # The host only ever answers over HTTPS (viewer_protocol_policy redirect-to-https). No
    # includeSubdomains / preload: other lumiguides.it.com hosts are not this policy's business.
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }
  }
}

# -----------------------------------------------------------------------------
# Gated: distribution + alias records
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "photos_cdn" {
  count = local.photos_cdn_on

  enabled         = true
  comment         = "AA-844 CIS photos (bronze photos/ via OAC)"
  aliases         = [local.photos_cdn_host]
  price_class     = var.photos_cdn_price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id                = "bronze-photos"
    domain_name              = module.s3.bronze_bucket_regional_domain_name
    origin_path              = "/${local.photos_cdn_prefix}"
    origin_access_control_id = aws_cloudfront_origin_access_control.photos_cdn.id
  }

  default_cache_behavior {
    target_origin_id           = "bronze-photos"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"] # the Done-when check is two HEADs, the 2nd a Hit
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.photos_cdn.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.photos_cdn.id
  }

  # A 403 (key not synced yet, or a path outside photos/) and a 404 are cached at the edge for one
  # minute only, so a photo that photo_sync uploads after a miss shows up quickly. No custom page.
  custom_error_response {
    error_code            = 403
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.photos_cdn[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.photos_cdn_tags, { Name = "aa-cis-dev-photos-cdn" })
}

resource "aws_route53_record" "photos_cdn" {
  for_each = local.photos_cdn_on == 1 ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.photos_cdn_host
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.photos_cdn[0].domain_name
    zone_id                = aws_cloudfront_distribution.photos_cdn[0].hosted_zone_id
    evaluate_target_health = false
  }
}
