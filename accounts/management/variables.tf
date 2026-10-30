# AA-1004 — inputs of the management root. Account IDs, the organization ID and e-mail addresses are inputs only:
# none is written in this public repo. Copy terraform.tfvars.example to terraform.tfvars (git-ignored) and fill it.

variable "region" {
  description = "Home region of the organization: IAM Identity Center, the trail and its bucket live here."
  type        = string
  default     = "us-west-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile for a human or agent apply: aa-mgmt (the AA-Bootstrap role, then an AA-Admin session). Null in CI (OIDC)."
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

variable "extra_service_access_principals" {
  description = <<-EOT
    Service principals that already have trusted access in the organization but are not in the base list of
    organization.tf (aws_service_access_principals replaces the whole list, so a principal missing here would be
    switched OFF). Before every apply that touches the organization, run
    aws organizations list-aws-service-access-for-organization --profile aa-mgmt
    and add any principal it prints that the base list lacks (README §4).
  EOT
  type        = list(string)
  default     = []
}

variable "identity_center_enabled" {
  description = "False for apply 1 (the organization does not exist yet). True once the tech lead has enabled the Identity Center organization instance in the home region (README §2 step 4)."
  type        = bool
  default     = false
}

variable "sso_users" {
  description = <<-EOT
    Identity Center users created by Terraform, keyed by a short handle, each in one group (admins, developers,
    billing). Only in the git-ignored terraform.tfvars: names and e-mails never go into this public repo.
    Keys are handles u1, u2, ... (validated; they appear in resource addresses). The first entry (u1) is the tech lead
    (group admins); it replaces the AA-Bootstrap role (README §4).
  EOT
  type = map(object({
    given_name  = string
    family_name = string
    email       = string
    group       = string
  }))
  default = {}

  validation {
    condition     = alltrue([for u in values(var.sso_users) : contains(["admins", "developers", "billing"], u.group)])
    error_message = "sso_users[*].group must be admins, developers or billing."
  }

  # AA-1004 review (S259): keys show up in resource addresses, which CI writes to public job summaries (redacted there
  # as well). Non-identifying handles only: u1, u2, ...
  validation {
    condition     = alltrue([for k in keys(var.sso_users) : can(regex("^u[0-9]+$", k))])
    error_message = "sso_users keys must be non-identifying handles u1, u2, ... (they appear in resource addresses)."
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

variable "scp_exempt_role_arn_patterns" {
  description = <<-EOT
    SCP 2 exemptions (ArnLike on aws:PrincipalArn): the roles allowed to change trails, billing and account
    settings in a member account, and the only principals allowed to create or edit these same roles (SCP 2
    statement ProtectExemptRoles). Patterns with a wildcard account, never a literal ID. Defaults: the
    cross-account admin role, the Identity Center AA-Admin role, the current and the planned Terraform apply
    roles. A legacy admin role that must keep running bootstrap applies in the nonprod account after it joins an
    OU is appended in the git-ignored terraform.tfvars, not here.
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
