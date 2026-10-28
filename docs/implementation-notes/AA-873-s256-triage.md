# AA-873 (S256) — Access Analyzer triage, archive rules, IAM tag alerts, alert rule checks

Session S256 (28/10/2026), Claude Code Infra lane. Branch `chore/aa-873-access-analyzer-archive-rules`.
Root audit: `docs/audits/2026-10-28-S256-aa873-triage/README.md` (triage table). GuardDuty stays off (lesson S255).

## Decisions

- **Triage (live, read-only, 28/10 ~14:30 UTC):** one analyzer in the account (`aa-sec-dev-external-access`,
  us-west-1; no analyzer in any other region; all 16 buckets are in us-west-1). 12 findings: 11 ACTIVE, 1 RESOLVED
  (the retired account's batch role on the bronze bucket, removed by AA-998). All 11 ACTIVE are intended:
  9 GitHub OIDC roles, 1 Identity Center `AdministratorAccess` permission-set role, 1 bronze bucket statement for the
  LLM account's Bedrock batch role (prefix-scoped).
- **OIDC trusts checked in Terraform, not live:** the subagent hook blocks every `aws iam` call. Access Analyzer drops
  the GitHub claims (`"condition": {}` on every finding), so the finding itself cannot prove the pin. Every trust in
  `accounts/aa365` pins `aud` + an exact immutable subject (repo ids set in `terraform.tfvars`, no wildcard); most pin
  the ref too. Live == Terraform is the orchestrator's check (step in the PR body: `terraform plan` shows no change on
  the 9 roles, or `aws iam get-role` per role).
- **Archive by explicit role list**, not "any role trusted by the OIDC provider": a new OIDC role with a loose trust
  must raise an alert. Filter also pins `principal.Federated` = the OIDC provider, so a second trust (another account)
  on one of these roles stays ACTIVE.
- **Identity Center rule matches only `AWSReservedSSO_AdministratorAccess_*`** (+ `principal.Federated` contains
  `:saml-provider/AWSSSO_`): a new permission set assigned to the account still alerts.
- **Bronze rule pins resource + principal + `isPublic = false`.**
- **Filters dry-run live**: the same criteria passed to `list-findings-v2 --filter` (read-only) return exactly the
  9 + 1 + 1 ACTIVE findings, and AWS accepts the keys `principal.Federated`, `principal.AWS`, `resource`
  (`eq` and `contains`), `resourceType`, `isPublic` (root `.tmp-session/S256/aa873/filters.py`).
- **iam-change rule widened** with prefixes `Tag`, `Untag`, `Upload`, `Set`, `Reset`, `Change`, `Enable`,
  `Deactivate`, `Resync` (the three explicit MFA names and `SetDefaultPolicyVersion` are now covered by prefixes).
  Found while preparing the alert test: the live rule did not match `TagRole` / `UntagRole` / `TagPolicy` (live
  `test-event-pattern`: 7 misses). Tags drive access here (CRM break-glass reads `aws:PrincipalTag/tenant_id`; the
  apply boundary keys on `App`), so a silent tag change is a real gap. Read verbs (`Get`, `List`, `Simulate`,
  `Generate`) are not matched; the forwarder only forwards `readOnly = false` anyway.
- **Apply-role grant** `access-analyzer:*ArchiveRule` + `ListArchiveRules` joins Sid `AccessAnalyzerManage` in the
  bootstrap policy `cicd_sec.tf` (archive-rule ARNs sit under `analyzer/*`).

## Changed

- New `accounts/aa365/security_access_analyzer_archive.tf` (3 `aws_accessanalyzer_archive_rule`).
- `accounts/aa365/security_baseline.tf`: iam-change event names; header pointer to the triage.
- `accounts/aa365/cicd_sec.tf`: Sid `AccessAnalyzerManage` actions; header line.
- New `tools/terraform/sec_alert_check.py` (live, read-only `describe-rule` + `test-event-pattern`, 44 cases over the
  six `aa-sec-*` rules, both regions) and `tools/terraform/tests/test_sec_access_analyzer.py` (offline guards), run in
  `.github/workflows/alb-rule-order.yml`.

## Tradeoffs

- Explicit role list = one Terraform line per new OIDC role (the guard test names the missing role). Accepted: the
  alternative archives loose trusts silently.
- Widening iam-change means more e-mails on planned local MFA applies that tag IAM objects. Accepted (same contract
  as every other IAM change by a non-CI principal).
- Root alert is not exercised by a real change (needs the root password + MFA in a browser; the script lists it as an
  optional manual step). Its pattern is proven by `test-event-pattern` (3 cases).

## Should know

- **Cost: 0 USD/month.**
- **Order (orchestrator):** merge → targeted local MFA apply of `aws_iam_policy.tf_apply_sec` (cicd_sec.tf header
  steps) → CI apply (expect 3 to add, 1 in-place: `aws_cloudwatch_event_rule.sec_iam_change`) →
  `aws accessanalyzer apply-archive-rule` once per rule (archive rules only act on NEW findings) → `list-findings-v2`
  with status ACTIVE = 0 → `python3 tools/terraform/sec_alert_check.py` = 0 failed → root `alert_test.sh`.
- Before the apply, `sec_alert_check.py --skip-after-s256` = 0 failed (the 7 new verbs are the known gap).

## Review follow-up (S256)

- Rebased on main fd39cc4: main gained a 10th GitHub OIDC role, `aa-cis-infra-db-auto-apply` (AA-993 I1, PR #477;
  live finding created 28/10 14:48 UTC). Its trust pins aud, the immutable-id AA-CIS-Infra subject with
  `environment:dev-db-auto` and `ref = refs/heads/main`, so it is intended; added to `local.sec_aa_github_oidc_roles`.
  The guard test caught it (failed on the rebased branch before the addition). Live filter dry run: 10 + 1 + 1.
