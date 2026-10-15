# =============================================================================
# AA-811 (S237, decision D5) — Route 53 public hosted zone for lumiguides.it.com.
#
# DNS for lumiguides.it.com is served today by Namecheap (dns1/dns2.registrar-servers.com). S236
# decided to move it to a Terraform-managed Route 53 zone so SES (ses.tf), ACM validation (AA-818)
# and the Cognito auth domains (AA-703) are records in code instead of hand steps at Namecheap.
#
# Cut-over (human, Nghiep): apply this zone, compare local.dns_parity_records with the Namecheap
# "Advanced DNS" panel (AA-Ecosys docs/audits/2026-10-14-S237-lane-backlog/dns-parity.md), add any
# record the discovery missed, THEN switch the domain's nameservers at Namecheap to the four values
# of output `lumiguides_zone_name_servers`. Until that switch nothing in this zone is served, so
# applying it is harmless; after the switch a missing record here is an outage (Zoho mail!).
#
# Parity list below = every record found with dig against the authoritative Namecheap servers on
# 14/10/2026 (no AXFR; apex types + ~150 common names + every *.lumiguides.it.com host named in the
# workspace repos + the ACM validation names from `acm describe-certificate`). No DNSSEC (no DS).
# =============================================================================

resource "aws_route53_zone" "lumiguides" {
  name    = var.dns_zone_name
  comment = "AA-811: lumiguides.it.com (moved from Namecheap DNS, S237). Managed by AA-CIS-Infra."

  tags = merge(local.ecosys_tags, { App = "shared", Issue = "AA-811" })

  # Deleting the zone after the NS switch takes every *.lumiguides.it.com name and the Zoho mail
  # offline. The CI apply role is also not granted route53:DeleteHostedZone (cicd_split.tf).
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Records copied 1:1 from Namecheap (dig, 14/10/2026). TTL 1800 = Namecheap "Automatic" (served
  # as 1799). Key = "<name>|<type>", name relative to the zone ("" = apex).
  dns_parity_records = {
    # Zoho Mail for the apex (inbound MX, SPF, domain verification, Zoho DKIM selector "zmail").
    "|MX" = {
      name    = ""
      type    = "MX"
      records = ["10 mx.zoho.com", "20 mx2.zoho.com", "50 mx3.zoho.com"]
    }
    "|TXT" = {
      name = ""
      type = "TXT"
      records = [
        "v=spf1 include:zohomail.com ~all",
        "zoho-verification=zb55616719.zmverify.zoho.com",
      ]
    }
    "zmail._domainkey|TXT" = {
      name    = "zmail._domainkey"
      type    = "TXT"
      records = ["v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCRUfeh2HiNAjL8S3BM/504yuZp5PX26R8zInoJDzySIjJ4B6aORZYP2o3FZpE0wGGJ+5M6XDgwVk83nNy5HV3VVXQ+QEibpelTenSNu7XOPKs2hzDV1/kfCXwzv5hslYbQirihzK1A7+XlQBpqqdGExmV5rm7snvcUBXHDQ8lZuwIDAQAB"]
    }

    # CIS admin/portal frontend on Vercel.
    "aa-cis|CNAME" = {
      name    = "aa-cis"
      type    = "CNAME"
      records = ["91b6470228dd7980.vercel-dns-017.com"]
    }

    # CIS REST API custom domain (API GW 4ylo382khg, hand-made domain + cert, not in Terraform
    # state) and the DNS-validation records ACM needs to auto-renew both api-cis certificates.
    # Both certs are outside Terraform (var.acm_certificate_arn). If one is ever imported with an
    # aws_route53_record for its validation (AA-818), delete the matching entry here first, or the
    # second record of the same name fails with "already exists".
    "api-cis|CNAME" = {
      name    = "api-cis"
      type    = "CNAME"
      records = ["d-p5fej4ddcg.execute-api.us-west-1.amazonaws.com"]
    }
    "_82696e885de42cd0cfe7589ce5cdb188.api-cis|CNAME" = {
      name    = "_82696e885de42cd0cfe7589ce5cdb188.api-cis"
      type    = "CNAME"
      records = ["_ca529c9e2dbfc61a703e33210ed793c2.jkddzztszm.acm-validations.aws"]
    }
    "_664ff4fa710e6d329ff66f6cb3ac3a64.api-cis-aa365|CNAME" = {
      name    = "_664ff4fa710e6d329ff66f6cb3ac3a64.api-cis-aa365"
      type    = "CNAME"
      records = ["_db1334da60091d3dc3b933a7027f9942.jkddzztszm.acm-validations.aws"]
    }

    # Legacy: the old Quanskill ap-southeast-1 ALB, which no longer resolves (NXDOMAIN, 14/10).
    # Copied for parity only; dropping them is a separate decision (dns-parity.md).
    "www|CNAME" = {
      name    = "www"
      type    = "CNAME"
      records = ["aa-alb-prod-203362903.ap-southeast-1.elb.amazonaws.com"]
    }
    "api|CNAME" = {
      name    = "api"
      type    = "CNAME"
      records = ["aa-alb-prod-203362903.ap-southeast-1.elb.amazonaws.com"]
    }
  }
}

resource "aws_route53_record" "parity" {
  for_each = local.dns_parity_records

  zone_id = aws_route53_zone.lumiguides.zone_id
  name    = each.value.name == "" ? var.dns_zone_name : "${each.value.name}.${var.dns_zone_name}"
  type    = each.value.type
  ttl     = 1800
  records = each.value.records
}

output "lumiguides_zone_id" {
  value = aws_route53_zone.lumiguides.zone_id
}

output "lumiguides_zone_name_servers" {
  description = "Set these as custom nameservers for lumiguides.it.com at Namecheap, AFTER the record parity check."
  value       = aws_route53_zone.lumiguides.name_servers
}
