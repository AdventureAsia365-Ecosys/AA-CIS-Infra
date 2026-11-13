output "web_acl_arn" {
  value = aws_wafv2_web_acl.main.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.main.id
}

output "web_acl_name" {
  value = aws_wafv2_web_acl.main.name
}

output "tripplanner_web_rule_names" {
  description = "AA-1038: the TripPlanner web rules of this ACL (empty without var.tripplanner_web), for the runbook's metric checks."
  value       = local.tp_on ? ["TripPlannerRateLimitPerIp", "TripPlannerRateLimitModelPaths", "TripPlannerChallengePlanner"] : []
}

output "geo_allowed_countries" {
  description = "AA-1096 L6: the countries rule GeoBlockNonAllowed lets through (ISO 3166-1 alpha-2), for the root output platform_limits."
  value       = var.geo_allowed_countries
}
