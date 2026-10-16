# AA-818 — custom domains for AA-Booking and TripPlanner on lumiguides.it.com (custom_domains.tf).

variable "custom_domains_enabled" {
  description = "Create the API GW custom domains (api-booking., api-tripplanner.), their base path / API mappings, the Route 53 alias records, the ACM validation waits and the Vercel CNAMEs. Turn on ONLY after the Namecheap -> Route 53 NS switch, once both certificates (output custom_domain_certificates) show ISSUED; before that ACM cannot validate and the apply would hang on aws_acm_certificate_validation."
  type        = bool
  default     = true # S237 15/10: NS switched to Route 53, both certificates ISSUED
}

variable "custom_domain_vercel_hosts" {
  description = "Frontend hosts on Vercel, as { label under dns_zone_name = CNAME target }. Created only when custom_domains_enabled = true. Add the domain to the Vercel project FIRST and use the target Vercel shows (project-specific *.vercel-dns-0xx.com, or cname.vercel-dns.com); a CNAME to Vercel with no project claiming the host is a takeover risk. booking (staff admin) added S239 (AA-818)."
  type        = map(string)
  default = {
    tripplanner = "a1520bcb29624260.vercel-dns-017.com" # project-specific target, domain added to aa-tripplanner first
    booking     = "faa59191f1f73e21.vercel-dns-017.com" # S239 AA-818: staff admin, domain added to aa-booking-admin first (verified)
  }
}
