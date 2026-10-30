output "organization_id" {
  description = "Organization ID (o-...)."
  value       = aws_organizations_organization.this.id
}

output "ou_ids" {
  description = "OU IDs by key (root, nonprod, prod, suspended): the parent IDs used for member accounts."
  value       = local.ou_parent_ids
}

output "member_account_ids" {
  description = "Member account IDs by key (nonprod, ai, prod), once in the organization."
  value       = { for k, a in aws_organizations_account.member : k => a.id }
}

output "scp_ids" {
  description = "SCP IDs by name."
  value       = { for k, p in aws_organizations_policy.scp : k => p.id }
}

output "sso_group_ids" {
  description = "Identity Center group IDs by key (admins, developers, billing): add users to these groups in the console."
  value       = { for k, g in aws_identitystore_group.this : k => g.group_id }
}

output "permission_set_arns" {
  description = "Permission set ARNs by name."
  value       = { for k, p in aws_ssoadmin_permission_set.this : k => p.arn }
}

output "org_trail_bucket" {
  description = "S3 bucket of the organization trail."
  value       = aws_s3_bucket.trail.id
}
