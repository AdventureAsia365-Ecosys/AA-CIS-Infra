# =============================================================================
# AA-1038 R5 hosting (root ADR 0019 d23, S265 tech-lead decision: one Fargate Spot task + CloudFront + WAF; the
# Fargate and WAF cost yeses are in the AA-1038 description; S272 tech-lead decision: the WAF rules move into the ALB
# web ACL, about 9.5 USD a month in all) — the edge of the TripPlanner frontend on ECS
# (modules/environment/tripplanner_web.tf).
#
#   viewer -> CloudFront tripplanner.<zone>  (viewer-request function: + x-aa-viewer-ip; + X-AA-Origin: <the
#             crm_edge.tf secret>)
#          -> the shared VPC origin on the internal NLB (crm_edge.tf) -> ALB :80, its web ACL aa-<env>-waf (the
#             TripPlanner rules below), then the listener rules (alb_rules.tf order)
#             tripplanner_web  (Host + secret, any path) -> the TripPlanner web service
#             crm_origin_deny  (crm_edge.tf)             -> 403 for anything else that came through CloudFront
#
# The VPC origin and the origin-verify secret are the ones every CloudFront host of this ALB uses (crm_edge.tf): the
# secret proves "came through one of our distributions"; the Host rule picks the service, and CloudFront only accepts a
# viewer Host that is an alias of the distribution. The regional web ACL on the ALB inspects these requests with its
# CommonRuleSet, then the TripPlanner rules, then lets them past its rate and geo rules (CloudFrontOriginAllow,
# modules/waf).
#
# Caching: pages and /api/* are never cached at the edge (CachingDisabled: the guest cookie of /plan, per-traveller
# answers; the task serves pages from its own ISR cache, which the CIS purge notice drops). The immutable build chunks
# (/_next/static/*, content-hashed paths) use CachingOptimized. The photo proxy (/photo-cdn/*) uses its own policy
# (tripplanner_web_photos): CachingOptimized's TTLs and compression plus ?v= in the cache key, because a photo file is
# versioned by its query (AA-TripPlanner-Web lib/photoResolve.ts), not by its path; CachingOptimized drops the query
# and would serve the old file for a new ?v= (review S272). A photo withdrawn from the CDN at the same path and ?v=
# stays in this distribution's cache too: the runbook names the invalidation (the CIS purge reaches the photos CDN only).
#
# Bot and abuse rules: three rules in the EXISTING regional web ACL of the ALB, aa-<env>-waf (modules/waf, input
# tripplanner_web of module "waf" in main.tf). S272 tech-lead decision (cost): no CLOUDFRONT-scope web ACL of its own
# (was aa-tripplanner-<env>-web: 5 USD/month fixed) and no Bot Control. AWS WAF returns a JavaScript integration URL
# (challenge.js) only for a web ACL with a paid intelligent-threat group (Bot Control / ATP / ACFP), so the planner's
# background token never existed; the app now opens the planner with a full page load instead (AA-TripPlanner-Web).
# Each rule is scoped to Host tripplanner.<zone> AND the exact origin secret, and runs after CommonRuleSet and before
# VpcLinkInternalAllow / CloudFrontOriginAllow (modules/waf local.rule_priorities); no other host is touched.
#   2 TripPlannerRateLimitPerIp       per viewer address, var.tripplanner_web_rate_limit per 5 minutes -> 429 JSON
#   3 TripPlannerRateLimitModelPaths  the protected paths (local.tp_web_protected_paths): GET /api/browse/search +
#                                     POST /api/trip/narrate (the two calls that reach a model) and POST
#                                     /api/trip/send ("Send to advisor": stores a traveller's contact for an agency),
#                                     per viewer address, var.tripplanner_web_model_rate_limit -> 429
#   4 TripPlannerChallengePlanner     Challenge (silent JavaScript proof, no puzzle) on a document navigation of a
#                                     planner page (GET with sec-fetch-dest: document on /plan, /{tenant}/plan and
#                                     below) and on the protected paths. Every in-site link into the planner is a full
#                                     document load (AA-TripPlanner-Web), so the browser gets its aws-waf-token on that
#                                     load; a script without the token gets HTTP 202 + x-amzn-waf-action: challenge and
#                                     never reaches the app. On a challenged model call the planner reloads itself
#                                     once (then shows its bot-check notice); a challenged send keeps the form and
#                                     asks the traveller to reload. Home, destination and tour pages never see an
#                                     interstitial. The app answers the older spellings of the three calls 404
#                                     (AA-TripPlanner-Web lib/edgeGate.ts, task env TP_EDGE_GATE=on), so no model call
#                                     and no lead passes outside rules 3 and 4. On ECS these rules are the whole bot
#                                     check of the three calls (BotID needs the Vercel edge: the image builds it off).
#   Every path match of rules 3 and 4 runs URL_DECODE then NORMALIZE_PATH (local.tp_web_path_normalize), and a
#   protected path matches with CONTAINS, so a dot-segment spelling (/api/browse/%2e/search, /api/trip/./narrate,
#   /x/../api/trip/send, and a LEADING one: /%2e%2e/api/trip/send, /../api/browse/search, /./api/trip/narrate), which
#   the app resolves to the protected route, is rate-limited and challenged like the plain path. NORMALIZE_PATH keeps a
#   back-reference at the start of the path, so EXACTLY let the leading spellings through (review S272).
#   Token: the ALB web ACL issues it for the request's host (tripplanner.<zone>, the Host CloudFront forwards), so no
#   token domain list is needed; lifetime var.tripplanner_web_challenge_immunity_s (default 4 h), set on the rule, so
#   the ACL default stays as it is for the other hosts.
#   Viewer address: at the ALB the source address is CloudFront's. The viewer-request function below writes the
#   viewer's own address into local.tp_web_viewer_ip_header on every request (over any value the viewer sent); the
#   two rate rules key on that header (FORWARDED_IP). Not X-Forwarded-For: AWS WAF takes its first address, which the
#   viewer writes. The rules see only the requests that reach the ALB (CloudFront serves cached build chunks and
#   photos itself), so the per-IP limit counts pages, BFF calls and cache misses.
#   No extra WAF log: the ACL's log keeps the requests a rule acted on (30 days, modules/waf).

# DNS (root runbook docs/ops/runbooks/tripplanner-web-ecs-cutover.md): tripplanner.<zone> stays a CNAME on both sides of
# the switch, so the switch and its rollback are a one-value change. var.tripplanner_web_dns_on_cloudfront = false
# (default) keeps the Vercel target; true points it at the distribution. var.tripplanner_web_dns_switch_window gives
# the record a 60 s TTL (300 s normally) while a switch or a rollback is possible; it is on from the first apply, so
# the window is open well before the switch PR. The record moved here from custom_domains.tf
# (vercel_frontend["tripplanner"]) with a moved block: the same Route 53 record, never destroyed.
#
# Certificate: the us-east-1 wildcard *.<zone> of crm_agency_edge.tf (tripplanner. CNAMEs to Vercel until the switch;
# a certificate naming it would fail CAA, critic C1). A certificate can serve several distributions.
#
# Cost (us-west-1 / global, est., D-19): 3 rules x 1 USD/month in the existing ALB web ACL (no web ACL fee: that ACL
# is paid already) + 0.60 USD per million requests it inspects; Challenge responses are billed per attempt (AWS WAF
# pricing, CAPTCHA / Challenge), cents at Dev volume; the viewer-request function: CloudFront Functions 0.10 USD per
# million invocations after the always-free 2M a month (shared with crm_edge.tf), 0 on Dev; the photo cache policy
# costs nothing; CloudFront and the VPC origin inside the always-free tier (1 TB, 10M requests); ACM, Route 53 alias
# queries 0; one ALB rule inside the LCU rule allowance. ~ 3.1 USD/month for the edge (was ~ 8.5 with the CLOUDFRONT
# web ACL); with the task (tripplanner_web.tf, ~ 6 USD) ~ 9.5 USD/month on Dev. Vercel Hobby costs nothing, so the
# delta is the same figure.
# =============================================================================

variable "tripplanner_web_edge_enabled" {
  description = "AA-1038: create the TripPlanner web edge (CloudFront distribution and its viewer-request function, the three TripPlanner rules in the ALB web ACL, ALB host rule). Needs the CRM edge (crm_edge_enabled and custom_domains_enabled): it reuses its VPC origin, origin secret and wildcard certificate."
  type        = bool
  default     = true
}

variable "tripplanner_web_dns_on_cloudfront" {
  description = "AA-1038: false keeps tripplanner.<zone> on Vercel (var.tripplanner_web_vercel_target); true points it at the CloudFront distribution (ECS). Flip only after the runbook's checks through the distribution pass; false is the rollback."
  type        = bool
  default     = false
}

variable "tripplanner_web_dns_switch_window" {
  description = "AA-1038: true gives tripplanner.<zone> a 60 s TTL (300 s otherwise) while a switch or a rollback is possible. Keep it on at least 30 minutes before the record changes; close it after the Vercel retirement."
  type        = bool
  default     = true
}

variable "tripplanner_web_vercel_target" {
  description = "AA-1038: the CNAME target Vercel gave the aa-tripplanner project for tripplanner.<zone> (was custom_domain_vercel_hosts[\"tripplanner\"]). Used while tripplanner_web_dns_on_cloudfront is false; removed at the Vercel retirement (a CNAME to Vercel with no project claiming the host is a takeover risk)."
  type        = string
  default     = "a1520bcb29624260.vercel-dns-017.com"
}

variable "tripplanner_web_rate_limit" {
  description = "AA-1038: requests per 5 minutes per viewer IP on the TripPlanner host (WAF rule TripPlannerRateLimitPerIp in the ALB web ACL): pages, BFF calls and the cache misses of chunks and photos that reach the ALB."
  type        = number
  default     = 3000

  validation {
    condition     = var.tripplanner_web_rate_limit >= 100
    error_message = "tripplanner_web_rate_limit must be at least 100 (the AWS WAF rate-based minimum is 10; a page load is dozens of requests)."
  }
}

variable "tripplanner_web_model_rate_limit" {
  description = "AA-1038: requests per 5 minutes per viewer IP on the protected paths, the two model calls and Send to advisor (WAF rule TripPlannerRateLimitModelPaths in the ALB web ACL). The app's own per-session / per-IP / per-agency limits and the daily spend cap stay underneath."
  type        = number
  default     = 100

  validation {
    condition     = var.tripplanner_web_model_rate_limit >= 10
    error_message = "tripplanner_web_model_rate_limit must be at least 10 (the AWS WAF rate-based minimum)."
  }
}

variable "tripplanner_web_challenge_immunity_s" {
  description = "AA-1038: seconds a solved Challenge (the aws-waf-token) stays valid. A traveller who stays on the planner longer gets a challenged model call until the next page load."
  type        = number
  default     = 14400

  validation {
    condition     = var.tripplanner_web_challenge_immunity_s >= 300 && var.tripplanner_web_challenge_immunity_s <= 259200
    error_message = "tripplanner_web_challenge_immunity_s must be between 300 and 259200 (AWS WAF limits)."
  }
}

locals {
  tp_web_edge_on   = var.tripplanner_web_edge_enabled && local.crm_edge_on == 1 ? 1 : 0
  tp_web_host      = "tripplanner.${var.dns_zone_name}"
  tp_web_edge_tags = merge(local.tp_tags, { Component = "edge", Issue = "AA-1038" })

  # The header the viewer-request function writes with the viewer's address: the key of the two WAF rate rules.
  tp_web_viewer_ip_header = "x-aa-viewer-ip"

  # The protected BFF paths (AA-TripPlanner-Web lib/botCheck.ts SEARCH_PATH / NARRATE_PATH / SEND_PATH): the two calls
  # that reach a model and "Send to advisor", which stores a traveller's contact for an agency (review S272: on Vercel
  # BotID guarded it; on ECS only these rules do). Rate rule 3 and the Challenge rule 4 match a path that CONTAINS one
  # of these after the transformations below (a leading /../ survives NORMALIZE_PATH; review S272).
  tp_web_protected_paths = ["/api/browse/search", "/api/trip/narrate", "/api/trip/send"]

  # Text transformations on every uri_path match of the TripPlanner WAF rules, in this order (priority = index):
  # URL_DECODE, then NORMALIZE_PATH (drops /./, resolves /x/../, folds //; a leading /../ or /./ stays). CloudFront
  # passes the raw path and the app (Next, WHATWG new URL) resolves %2e / %2E as a dot segment, so
  # /api/browse/%2e/search reaches the search route; with NONE that spelling matched neither model rule and skipped the
  # Challenge and the model rate (review S272). Matching the path the app routes to is the point: the rules see the
  # same path the route handler sees, up to a leading back-reference, which the CONTAINS match covers.
  tp_web_path_normalize = ["URL_DECODE", "NORMALIZE_PATH"]

  # Cached at the edge, each with its cache policy; everything else is CachingDisabled.
  tp_web_static_path = "/_next/static/*"
  tp_web_photo_path  = "/photo-cdn/*"

  # TTL of the tripplanner. record: 60 s during the switch window, else the 300 s it had in custom_domains.tf.
  tp_web_dns_ttl = var.tripplanner_web_dns_switch_window ? 60 : 300
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = local.tp_web_edge_on
  name  = "Managed-CachingOptimized"
}

# /photo-cdn/*: CachingOptimized's TTLs (1 s / 1 day / 1 year, on the origin's Cache-Control) and compression, plus the
# photo version ?v= in the cache key. Only v: any other query is neither a key nor forwarded (the CDN file needs none).
# CreateCachePolicy: cicd_split.tf PhotosCdnCloudFront (cloudfront:*CachePolicy*).
resource "aws_cloudfront_cache_policy" "tripplanner_web_photos" {
  count = local.tp_web_edge_on

  name        = "aa-tripplanner-${var.environment}-web-photos"
  comment     = "AA-1038: TripPlanner /photo-cdn/* proxy, CachingOptimized TTLs, cache key = path + ?v="
  min_ttl     = 1
  default_ttl = 86400
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

# -----------------------------------------------------------------------------
# Viewer-request function: writes the viewer's address into local.tp_web_viewer_ip_header (the WAF rate key, see the
# header). On every behaviour: a cache miss of a chunk or a photo reaches the ALB too and must carry the key.
# CreateFunction: cicd_crm.tf CrmCloudFrontEdge (cloudfront:*Function*).
# -----------------------------------------------------------------------------
resource "aws_cloudfront_function" "tripplanner_web_viewer_ip" {
  count = local.tp_web_edge_on

  name    = "aa-tripplanner-${var.environment}-web-viewer-ip"
  runtime = "cloudfront-js-2.0"
  comment = "AA-1038: viewer address header for the WAF rate rules"
  publish = true
  code = templatefile("${path.module}/cloudfront_functions/tripplanner_web_viewer_ip.js", {
    header_name = local.tp_web_viewer_ip_header
  })

  tags = local.tp_web_edge_tags
}

# -----------------------------------------------------------------------------
# CloudFront distribution: the shared VPC origin (crm_edge.tf), the wildcard certificate (crm_agency_edge.tf).
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "tripplanner_web" {
  count = local.tp_web_edge_on

  enabled         = true
  comment         = "AA-1038 TripPlanner web on ECS (VPC origin on the NLB, ALB host rule)"
  aliases         = [local.tp_web_host]
  price_class     = var.crm_cdn_price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = local.crm_origin_id
    domain_name = module.alb.nlb_dns_name

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.crm[0].id
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }

    custom_header {
      name  = local.alb_origin_header_name
      value = random_password.crm_origin_verify[0].result
    }
  }

  # Pages and /api/*: never cached at the edge (header). Every viewer header (the Host the ALB rule matches, cookies)
  # plus CloudFront-Viewer-Address (the app's client address, TP_CLIENT_IP_SOURCE=cloudfront) reach the task.
  default_cache_behavior {
    target_origin_id         = local.crm_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false # nothing is cached; keep streamed SSR chunks unbuffered
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf_headers[0].id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.tripplanner_web_viewer_ip[0].arn
    }
  }

  # Immutable build chunks (content-hashed paths): cached on the origin's Cache-Control, query not in the key.
  ordered_cache_behavior {
    path_pattern             = local.tp_web_static_path
    target_origin_id         = local.crm_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf_headers[0].id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.tripplanner_web_viewer_ip[0].arn
    }
  }

  # The photo proxy: versioned by ?v=, so the version is in the cache key (tripplanner_web_photos).
  ordered_cache_behavior {
    path_pattern             = local.tp_web_photo_path
    target_origin_id         = local.crm_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.tripplanner_web_photos[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_and_cf_headers[0].id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.tripplanner_web_viewer_ip[0].arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.crm_agency[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.tp_web_edge_tags, { Name = "aa-tripplanner-${var.environment}-web-cdn" })
}

# -----------------------------------------------------------------------------
# ALB :80 host rule (priority in alb_rules.tf; host + secret, below crm_origin_deny 20). CreateRule: cicd.tf
# BookingAlbListenerRuleManage (every listener of the shared ALB).
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "tripplanner_web" {
  count = local.tp_web_edge_on

  listener_arn = module.alb.http_listener_arn
  priority     = local.alb_http_rule_priorities.tripplanner_web

  action {
    type             = "forward"
    target_group_arn = module.environment.tripplanner_web_target_group_arn
  }

  condition {
    host_header {
      values = [local.tp_web_host]
    }
  }

  condition {
    http_header {
      http_header_name = local.alb_origin_header_name
      values           = [random_password.crm_origin_verify[0].result]
    }
  }

  tags = local.tp_web_edge_tags
}

# -----------------------------------------------------------------------------
# DNS: tripplanner.<zone>. Moved from custom_domains.tf (vercel_frontend["tripplanner"]): the same Route 53 record,
# updated in place (TTL now, target at the switch), never destroyed.
# -----------------------------------------------------------------------------
moved {
  from = aws_route53_record.vercel_frontend["tripplanner"]
  to   = aws_route53_record.tripplanner_web[0]
}

resource "aws_route53_record" "tripplanner_web" {
  count = var.custom_domains_enabled ? 1 : 0

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = local.tp_web_host
  type    = "CNAME"
  ttl     = local.tp_web_dns_ttl
  records = [var.tripplanner_web_dns_on_cloudfront ? aws_cloudfront_distribution.tripplanner_web[0].domain_name : var.tripplanner_web_vercel_target]

  lifecycle {
    precondition {
      condition     = !var.tripplanner_web_dns_on_cloudfront || local.tp_web_edge_on == 1
      error_message = "tripplanner_web_dns_on_cloudfront needs the TripPlanner web edge (tripplanner_web_edge_enabled and the CRM edge)."
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs (no secret values).
# -----------------------------------------------------------------------------
output "tripplanner_web_edge" {
  description = "AA-1038: the public host, the distribution (its domain is the --resolve target of the pre-switch checks and the repository variable TP_WEB_CLOUDFRONT_DNS), the web ACL that holds the TripPlanner rules (the ALB one) with their rule names, and where the host points now."
  value = local.tp_web_edge_on == 1 ? {
    host                = local.tp_web_host
    distribution_id     = aws_cloudfront_distribution.tripplanner_web[0].id
    distribution_domain = aws_cloudfront_distribution.tripplanner_web[0].domain_name
    web_acl_name        = module.waf.web_acl_name
    waf_rules           = module.waf.tripplanner_web_rule_names
    dns_target          = var.tripplanner_web_dns_on_cloudfront ? aws_cloudfront_distribution.tripplanner_web[0].domain_name : var.tripplanner_web_vercel_target
    ecs_service         = module.environment.tripplanner_web_ecs_service_name
    ecr_repository_url  = module.environment.tripplanner_web_ecr_repository_url
    secret_name         = module.environment.tripplanner_web_secret_name
  } : null
}
