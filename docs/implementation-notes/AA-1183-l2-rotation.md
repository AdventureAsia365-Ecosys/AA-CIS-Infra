# AA-1183 part 2 — read-only metadata permission of the compliance evidence role (S297, lane l2-rotation)

The tool, its workflow and the CI bot key move are in the root repo (`docs/implementation-notes/AA-1183-l2-rotation.md`
there). This PR lets the root weekly "Secret rotation" workflow read secret METADATA with the compliance evidence role.

## Decisions

- **Same role, third trust statement** (`GitHubOidcRootRotation`): subject = the root repo's immutable master subject
  (`local.docs_sync_oidc_sub`), ref master, `job_workflow_ref` = `secret-rotation.yml@refs/heads/master`. The rotation
  job has no GitHub environment, so the subject is the ref form. No new role: the compliance role is already the
  read-only account reader, and the check's result is compliance evidence (AA-1173 reads it later).
- **Explicit grant of exactly the tool's 13 calls** (`local.compliance_evidence_rotation_read`, statement
  `RotationCheckMetadata`) although SecurityAudit / ViewOnlyAccess cover most of them: the check must not depend on
  what an AWS managed policy contains or drops (`cognito-idp:ListUserPoolClientSecrets` is recent). The root tool's
  allowlist (`AWS_CALLS`) and this list are pinned by a test in each repo.
- **Explicit deny of secret-value reads** (`DenySecretValueReads`: `secretsmanager:GetSecretValue`,
  `BatchGetSecretValue`, `cognito-idp:DescribeUserPoolClient`, `cognito-idp:DescribeIdentityProvider`,
  `acm:ExportCertificate`, `kms:Decrypt`) on this role. Review fix (S297): the first version left the two Cognito
  calls out because Prowler uses one of them, but the attached SecurityAudit policy grants `cognito-idp:Describe*`,
  so the role could read app client secrets and the external IdP client secret. Both are now denied.
- **Prowler keeps an honest result**: Prowler 5.48.0 calls `describe_user_pool_client` only for
  `cognito_user_pool_client_prevent_user_existence_errors` and `cognito_user_pool_client_token_revocation_enabled`
  (read from its source). With the call denied, its client objects keep the default values and both checks would
  report a false FAIL per client, so `compliance-aws.yml` passes `--excluded-check` for the two (Prowler discards
  unknown names, so a rename later cannot break the scan). The same two settings are pinned on every
  `aws_cognito_user_pool_client` by `test_every_user_pool_client_sets_what_the_excluded_prowler_checks_tested`.
  Prowler still logs one AccessDenied line per client in the sealed run log; that is expected.

## Changed

- `accounts/aa365/compliance_evidence.tf`: header paragraph, two locals, the trust statement, two policy statements,
  role description. `tools/terraform/tests/test_aa1183_rotation_metadata.py` (new);
  `test_aa1173_compliance_evidence.py` counts three trust statements. CONTEXT.md lines for the role.

## Tradeoffs

- One role for two jobs (evidence + rotation) keeps one ARN secret in the root repo (`COMPLIANCE_EVIDENCE_ROLE_ARN`)
  and one place to review; a separate role would add a bootstrap-style trust and a second secret for no gain in
  scope (the rotation reads are a subset of what the role already reads).

## Should know

- Known leftover, not changed here: Lambda environment values stay readable through `lambda:ListFunctions` /
  `lambda:GetFunctionConfiguration` (managed policies; Prowler's secrets-in-variables check needs them). The header
  comment now says so instead of "no Lambda environment".

- Apply with Terraform Apply (aa365): an in-place update of the role's trust policy and inline policy, 0 USD.
- Until it is applied, the root workflow cannot assume the role: its run still checks GitHub and the register dates and
  opens one RED issue "check could not read aws". Apply before Monday 30/11/2026 03:23 UTC to avoid it.
