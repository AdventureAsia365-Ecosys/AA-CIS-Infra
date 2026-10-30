# AA-1004 — inputs of the management root. Account IDs, the organization ID and e-mail addresses are inputs only:
# none is written in this public repo. Copy terraform.tfvars.example to terraform.tfvars (git-ignored) and fill it.

variable "region" {
  description = "Home region of the organization: IAM Identity Center, the trail and its bucket live here."
  type        = string
  default     = "us-west-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile (IAM Identity Center session) for a human apply, e.g. aa-mgmt. Null in CI (OIDC)."
  type        = string
  default     = null
}

variable "management_account_id" {
  description = "12-digit ID of the new management account (aa-management). Guards every plan via allowed_account_ids."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "organization_id" {
  description = "ID (o-...) of the organization created when IAM Identity Center was enabled in the console (README step 2). Imported, not created."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-xxxxxxxxxx."
  }
}

variable "member_accounts" {
  description = <<-EOT
    Member accounts, keyed by role: nonprod (today's infrastructure account), ai (today's LLM account), prod
    (created at go-live). Leave a key out until the account is in the organization.
      name       - display name (aa-nonprod, aa-ai, aa-prod); ignored for an invited account.
      email      - root e-mail; required by the API, ignored after an import (an invited account keeps its own).
      account_id - set for an INVITED account once it has accepted: Terraform imports it. Null = Terraform creates it.
      ou         - root | nonprod | prod | suspended. "root" is the transitional place: no SCP of ours applies there,
                   so an invited account can still leave the organization if billing or Bedrock breaks (README §6).
      budget_usd - monthly budget in USD (gross cost, credits excluded).
  EOT
  type = map(object({
    name       = string
    email      = string
    account_id = optional(string)
    ou         = string
    budget_usd = number
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.member_accounts) : contains(["nonprod", "ai", "prod"], k)])
    error_message = "member_accounts keys must be nonprod, ai or prod (the Identity Center matrix is keyed on them)."
  }

  validation {
    condition     = alltrue([for a in values(var.member_accounts) : contains(["root", "nonprod", "prod", "suspended"], a.ou)])
    error_message = "member_accounts[*].ou must be root, nonprod, prod or suspended."
  }

  validation {
    condition     = alltrue([for a in values(var.member_accounts) : a.account_id == null || can(regex("^[0-9]{12}$", a.account_id))])
    error_message = "member_accounts[*].account_id must be null or a 12-digit AWS account ID."
  }
}

variable "budget_alert_emails" {
  description = "Recipients of every budget and cost-anomaly alert (role mailboxes of the tech lead and the business owner)."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0 && length(var.budget_alert_emails) <= 10
    error_message = "Give 1 to 10 e-mail addresses (Budgets and Cost Anomaly Detection allow at most 10)."
  }
}

variable "org_budget_usd" {
  description = "Monthly budget of the whole organization in USD (blueprint: 300 now, 1000 at go-live)."
  type        = number
  default     = 300
}

variable "management_budget_usd" {
  description = "Monthly budget of the management account itself in USD (expected 0-3)."
  type        = number
  default     = 10
}

variable "anomaly_threshold_usd" {
  description = "Cost Anomaly Detection: e-mail when an anomaly's total impact is at least this many USD."
  type        = number
  default     = 15
}

variable "allowed_regions" {
  description = "SCP 3 allow-list: us-west-1 (all workloads), us-east-1 (ACM for CloudFront/Cognito), us-west-2 (backup copy)."
  type        = list(string)
  default     = ["us-west-1", "us-east-1", "us-west-2"]
}

variable "bedrock_extra_regions" {
  description = <<-EOT
    SCP 3: extra values of aws:RequestedRegion allowed for bedrock:* only, on top of allowed_regions, so
    cross-Region inference profiles keep working: us-east-2 (a destination of the "us." profiles) and
    "unspecified" (what a "global." inference profile reports). Check against the Bedrock cross-Region inference
    page before apply; test with one real call per route (README §7).
  EOT
  type        = list(string)
  default     = ["us-east-2", "unspecified"]
}

variable "scp_exempt_role_arn_patterns" {
  description = <<-EOT
    SCP 2 exemptions (ArnLike on aws:PrincipalArn): the roles allowed to change trails and billing settings in a
    member account. Patterns with a wildcard account, never a literal ID. Defaults: the cross-account admin role,
    the Identity Center AA-Admin role, the current and the planned Terraform apply roles.
  EOT
  type        = list(string)
  default = [
    "arn:aws:iam::*:role/OrganizationAccountAccessRole",
    "arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AA-Admin_*",
    "arn:aws:iam::*:role/aa-cis-infra-tf-apply",
    "arn:aws:iam::*:role/aa-terraform-apply",
  ]
}

variable "cloudtrail_retention_days" {
  description = "Days the organization trail's log files are kept (Object Lock GOVERNANCE for the same period, then expired)."
  type        = number
  default     = 365
}
