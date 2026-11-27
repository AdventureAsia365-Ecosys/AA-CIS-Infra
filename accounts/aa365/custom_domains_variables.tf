# AA-818 — custom domains for AA-Booking and TripPlanner on lumiguides.it.com (custom_domains.tf).

variable "custom_domains_enabled" {
  description = "Create the API GW custom domains (api-booking., api-tripplanner.), their base path / API mappings, the Route 53 alias records, the ACM validation waits and the Vercel CNAMEs. Turn on ONLY after the Namecheap -> Route 53 NS switch, once both certificates (output custom_domain_certificates) show ISSUED; before that ACM cannot validate and the apply would hang on aws_acm_certificate_validation."
  type        = bool
  default     = true # S237 15/10: NS switched to Route 53, both certificates ISSUED
}

variable "custom_domain_vercel_hosts" {
  description = "Frontend hosts on Vercel, as { label under dns_zone_name = CNAME target }. Created only when custom_domains_enabled = true. Add the domain to the Vercel project FIRST and use the target Vercel shows (project-specific *.vercel-dns-0xx.com, or cname.vercel-dns.com); a CNAME to Vercel with no project claiming the host is a takeover risk. booking (staff admin, S239) left at the AA-911 Vercel retirement (staff_web_edge.tf staff_web); tripplanner moved to tripplanner_web_edge.tf (AA-1038); portal moved to crm_agency_edge.tf (AA-979); the Preview hosts booking-preview and aa-cis-preview (S246) were deleted with their Vercel projects (AA-911, S272)."
  type        = map(string)
  default = {
    # tripplanner moved to tripplanner_web_edge.tf aws_route53_record.tripplanner_web (AA-1038): a CNAME to the
    # TripPlanner web CloudFront distribution (the aa-tripplanner Vercel project was deleted at the retirement, S272).
    # booking moved to staff_web_edge.tf aws_route53_record.staff_web["booking"] (AA-911 Vercel retirement, S272).
    # portal moved to crm_agency_edge.tf (AA-979 P2b): aws_route53_record.crm_agency, the crm_agency CloudFront
    # distribution (the Vercel project aa-cis-portal was deleted at the P2b clean-up).
    # booking-preview / aa-cis-preview (the S246 Preview sign-in hosts) were deleted with the aa-booking-admin and
    # aa-cis-frontend Vercel projects (AA-911, S272; root ADR 0006a A13).
  }
}

# AA-1185 (S296; S295 security audit SA-55, the S241 SDLC review A13): every caller reaches the three APIs through their
# custom domains (api-cis., api-booking., api-tripplanner.; the CRM's TripPlanner URL moved in the S295 sweep), so the
# default https://<api id>.execute-api.<region>.amazonaws.com endpoints are switched off: they answer 403 (REST) or
# 404 (HTTP API) and the WAF, geo rules and logs in front of the custom domains can no longer be bypassed through them.
# Setting it back to false is the rollback (one apply: the REST stages redeploy, the HTTP stage auto-deploys).
variable "api_default_endpoints_disabled" {
  description = "Switch off the default execute-api endpoints of the CIS and Booking REST APIs and the TripPlanner HTTP API (clients use the custom domains only). Booking and TripPlanner follow only while custom_domains_enabled = true (their custom domains exist only then)."
  type        = bool
  default     = true
}
