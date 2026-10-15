# AA-811 — Route 53 zone (dns.tf) and SES (ses.tf).

variable "dns_zone_name" {
  description = "Public DNS zone moved from Namecheap to Route 53; also the SES domain identity (ADR 0006 item 5, S237 D5)."
  type        = string
  default     = "lumiguides.it.com"
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
