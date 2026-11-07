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
    # tripplanner moved to tripplanner_web_edge.tf aws_route53_record.tripplanner_web (AA-1038): its Vercel target is
    # var.tripplanner_web_vercel_target until the switch to the CloudFront distribution.
    # booking moved to staff_web_edge.tf aws_route53_record.staff_web["booking"] (AA-911 Vercel retirement, S272).
    # portal moved to crm_agency_edge.tf (AA-979 P2b): aws_route53_record.crm_agency, the crm_agency CloudFront
    # distribution (the Vercel project aa-cis-portal was deleted at the P2b clean-up).
    # booking-preview / aa-cis-preview (the S246 Preview sign-in hosts) were deleted with the aa-booking-admin and
    # aa-cis-frontend Vercel projects (AA-911, S272; root ADR 0006a A13).
  }
}
