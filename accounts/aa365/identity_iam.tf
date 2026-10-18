# =============================================================================
# AA-816 (Cognito Phase 1, root ADR 0006 "Ecosystem identity") — the CIS staff directory writes
# WORKFORCE users and groups from the CIS api / worker.
#
# ADR 0006 (IAM for the directory writer): an explicit allow-list on the WORKFORCE pool ARN only.
#   Allowed:  AdminCreateUser, AdminAddUserToGroup, AdminRemoveUserFromGroup, AdminDisableUser,
#             AdminEnableUser, AdminUserGlobalSignOut, ListUsers, ListUsersInGroup.
#   Excluded on purpose (not granted anywhere on this role):
#     - AdminSetUserPassword, AdminUpdateUserAttributes, AdminLinkProviderForUser,
#       AdminInitiateAuth, AdminRespondToAuthChallenge, AdminDeleteUser: with any of them a
#       compromised CIS API could point a staff account at an attacker mailbox or password and sign
#       in as that person. A staff email change is a manual, logged procedure.
#     - AdminGetUser: it counts as a Cognito MAU; reconcile and support tools use ListUsers.
#   The EXTERNAL pool (tenant invitations) is a later, separate grant; nothing here touches it.
#
# Fail-closed: a second statement explicitly DENIES the excluded takeover actions on BOTH pools, so
# a later broad grant on this role (e.g. cognito-idp:*) cannot silently undo the exclusions. It does
# not widen anything, and the post-apply AccessDenied probe then proves the Deny, not just a missing
# Allow. A future EXTERNAL invitation grant (AdminCreateUser/ListUsers/AdminDisableUser/
# AdminUserGlobalSignOut) does not overlap this Deny list.
#
# RESIDUAL RISK (not expressible in IAM; review finding, S242): AdminCreateUser accepts
# TemporaryPassword, and Cognito has no IAM condition key to force MessageAction=SUPPRESS or forbid
# TemporaryPassword. PASSWORD is a pool-wide first factor (identity.tf "DELIBERATE DEVIATIONS") and
# the pre-token trigger checks domain / email_verified / groups, not the auth method. So a
# compromised CIS task role can still
#   (1) create a new @adventure.asia user with email_verified=true, a password of its choosing and
#       SUPPRESS, add it to booking-admin / cis-admin, then sign in with that password and answer
#       NEW_PASSWORD_REQUIRED, getting staff tokens without any mailbox; and
#   (2) per the AdminCreateUser API reference ("RESEND ... reset the temporary-password duration
#       with a new temporary password"), call RESEND with its own TemporaryPassword on an existing
#       staff user still in FORCE_CHANGE_PASSWORD (every admin-created user while
#       identity_ses_enabled = false) and take that account over.
# The "SUPPRESS on every AdminCreateUser" rule holds only by procedure for an honest caller. The
# mitigations (CloudTrail/EventBridge alarm on WORKFORCE AdminCreateUser with a password or
# RESEND, reconcile flagging users outside the directory or with a password set) are tracked
# outside this file; the IAM grant itself cannot close the gap.
#
# Role: module.ecs task role (aa-cis-<env>-ecs-task-role). The api AND worker task definitions use
# the same role (modules/ecs/main.tf aws_ecs_task_definition.api / .worker, task_role_arn =
# aws_iam_role.ecs_task.arn), so the reconcile job on the worker gets the same grant. The role
# carries the AA-806 workload boundary, which allows cognito-idp (it only denies IAM writes and
# account/organization actions). Same root-level pattern as ses.tf cis_ecs_task_ses_send.
#
# After apply (takes effect within seconds; no redeploy or credential refresh needed): probe once
# from inside the container (LES:14, "role applied" != "role usable") via S3-mediated ECS exec with
# output returned through S3: list_users(Limit=1) succeeds, admin_set_user_password on a dummy name
# returns AccessDenied (explicit Deny).
# Cost: $0 (IAM; ListUsers/ListUsersInGroup do not count as MAU).
# =============================================================================

data "aws_iam_policy_document" "cis_workforce_directory" {
  statement {
    sid    = "WorkforceDirectoryWrite"
    effect = "Allow"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminRemoveUserFromGroup",
      "cognito-idp:AdminDisableUser",
      "cognito-idp:AdminEnableUser",
      "cognito-idp:AdminUserGlobalSignOut",
      "cognito-idp:ListUsers",
      "cognito-idp:ListUsersInGroup",
    ]
    resources = [aws_cognito_user_pool.workforce.arn]
  }

  statement {
    sid    = "DenyStaffTakeoverActions"
    effect = "Deny"
    actions = [
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminLinkProviderForUser",
      "cognito-idp:AdminInitiateAuth",
      "cognito-idp:AdminRespondToAuthChallenge",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminSetUserMFAPreference",
    ]
    resources = [
      aws_cognito_user_pool.workforce.arn,
      aws_cognito_user_pool.external.arn,
    ]
  }
}

resource "aws_iam_role_policy" "cis_ecs_task_workforce_directory" {
  name   = "aa-cis-${var.environment}-ecs-workforce-directory"
  role   = module.ecs.task_role_name
  policy = data.aws_iam_policy_document.cis_workforce_directory.json
}
