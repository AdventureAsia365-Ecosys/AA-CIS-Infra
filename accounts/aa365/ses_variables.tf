# AA-811 — Route 53 zone (dns.tf) and SES (ses.tf).

variable "dns_zone_name" {
  description = "Public DNS zone moved from Namecheap to Route 53; also the SES domain identity (ADR 0006 item 5, S237 D5)."
  type        = string
  default     = "lumiguides.it.com"
}

variable "dns_apex_a_records" {
  description = "A record(s) of the bare dns_zone_name (dns.tf, AA-816). Cognito custom domains need the parent to resolve. Vercel apex anycast IP: attach lumiguides.it.com to the aa-cis-frontend Vercel project (redirect to aa-cis.) BEFORE applying; use the IP the Vercel domain panel shows if it differs."
  type        = list(string)
  default     = ["76.76.21.21"]
}

variable "ses_from_address" {
  description = "The only From address the app roles may send as (ses:FromAddress condition). App send helpers must use exactly this."
  type        = string
  default     = "no-reply@lumiguides.it.com"

  validation {
    condition     = endswith(lower(var.ses_from_address), "@lumiguides.it.com")
    error_message = "ses_from_address must be an address of the SES identity domain lumiguides.it.com."
  }
}

variable "ses_mail_from_subdomain" {
  description = "Custom MAIL FROM (envelope sender / bounce) sub-domain label under dns_zone_name. Must not be used for anything else."
  type        = string
  default     = "bounce"
}

variable "ses_dmarc_rua_email" {
  description = "Optional DMARC aggregate-report mailbox (rua). Empty = DMARC p=none without reports. A mailbox outside lumiguides.it.com also needs an authorization record in that domain."
  type        = string
  default     = ""
}

# AA-828: operator mailbox for CIS alert e-mails (spend budget crossings, CIS job ops_alert_email).
# Not var.alert_email: that is a personal mailbox for SNS/AWS Budgets; this one is the work inbox.
variable "cis_ops_alert_email" {
  description = "Operator inbox that receives CIS alert e-mails (ALERT_EMAIL_TO on the CIS api + worker). Empty = CIS sends no alert e-mail (the app logs it)."
  type        = string
  default     = ""

  validation {
    condition     = var.cis_ops_alert_email == "" || can(regex("^[^@\\s,]+@[^@\\s,]+$", var.cis_ops_alert_email))
    error_message = "cis_ops_alert_email must be empty or a single e-mail address."
  }
}
