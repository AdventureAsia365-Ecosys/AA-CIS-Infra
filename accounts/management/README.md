# accounts/management: the management account root (AA-1004)

> [!WARNING]
> UNTESTED - prepared before the management account ID exists; nothing here has been planned or applied. Do not
> follow a step without checking it, and read every plan for destroys.

Terraform root for the management account of the lean AWS model (root ADR 0018, Proposed; S258 blueprint
`docs/audits/2026-10-29-S258-aws-org-blueprint/` §0 in the root repo). It holds governance only. No workload ever
runs in the management account, because SCPs do not apply there.

| File | Holds |
|---|---|
| `organization.tf` | The organization (imported), OUs `NonProd` / `Prod` / `Suspended`, member accounts (invited ones imported, prod created), centralized root access |
| `scp.tf` + `policies/*.json.tftpl` | 3 SCPs, attached to the three OUs, never to the root |
| `identity_center.tf` | Groups `aa-admins` / `aa-developers` / `aa-billing`, permission sets `AA-Admin` / `AA-Developer` / `AA-ReadOnly` / `AA-Billing`, the group x account matrix |
| `budgets.tf` | Organization budget, one budget per account, one Cost Anomaly Detection monitor + daily e-mail per account |
| `cloudtrail.tf` | Organization trail `aa-org-trail`, its KMS key and its bucket (Object Lock GOVERNANCE, 365 days) |
| `terraform.tfvars.example` | Every input; copy to `terraform.tfvars` (git-ignored: the repo is public, no account ID is committed) |

Access matrix (permission sets per group and account):

| Group | aa-management | aa-nonprod | aa-ai | aa-prod |
|---|---|---|---|---|
| `aa-admins` (tech lead) | AA-Admin | AA-Admin, AA-Developer | AA-Admin, AA-Developer | AA-Admin, AA-ReadOnly |
| `aa-developers` (engineers) | none | AA-Developer | AA-Developer | AA-ReadOnly |
| `aa-billing` (business owner) | AA-Billing | none | none | none |

CI roles and the agent never get an Identity Center assignment: they use IAM roles inside each member account.

## 1. Before you start

- The tech lead has the management account ID and its root sign-in (the account was created by the tech lead on
  2026-10-30 as a fresh, empty account). The ID goes only into the local, git-ignored `terraform.tfvars` (and later
  into a GitHub environment variable for CI, §11); never into a committed file.
- No root access key, ever: the only credential Terraform uses is an IAM Identity Center session (§2 step 4).
- Two FIDO2 security keys: one for the tech lead, one for the business owner's safe.
- The billing model (blueprint §5) decides whether, and when, the ai and nonprod accounts are invited (§6). The
  first apply needs no member account.
- One Terraform process at a time; Terraform `1.15.5` exactly (`versions.tf`).

## 2. Day 1: console steps only a human can do

These cannot be Terraform: they happen before any credential for Terraform exists.

1. **Root user (tech lead with the business owner).** Sign in as root. Register both FIDO2 keys as MFA. Rename the
   account to `aa-management` (Account settings; it was created under another display name, and the name is what
   members and invoices show). Set the alternate contacts (billing, operations, security) to role mailboxes.
   The business owner adds the company card and tax details (Billing, Payment preferences, Tax settings).
   - Verify: IAM, Security credentials shows two MFA devices and no access key.
2. **Activate IAM access to billing.** Account settings, "IAM user and role access to Billing information",
   Activate. Without it the `AA-Billing` permission set shows "access denied" on every billing page.
3. **Enable IAM Identity Center in us-west-1.** A new account's console opens in another region (this one showed
   eu-north-1). **Switch the region selector to US West (N. California) us-west-1 first**: an Identity Center
   instance lives in the region where it is enabled, and moving it later means deleting it with every user,
   group and assignment. Then open IAM Identity Center, Enable, choose the organization instance. This creates
   the organization with all features. Note the organization ID (`o-...`) from Organizations, Settings.
   - Verify: the Identity Center dashboard shows region us-west-1 and an AWS access portal URL.
   - In Identity Center settings: identity source stays the Identity Center directory; Authentication, MFA
     "every time they sign in", allowed types security keys and authenticator apps, users without MFA must
     register one at sign-in.
   - Verify: Organizations shows the organization, feature set "All features", this account as management.
4. **Bootstrap sign-in for Terraform.** In Identity Center create the tech lead's user (register its MFA at first
   sign-in), then a temporary permission set `AA-Bootstrap` (AdministratorAccess, 1 hour) assigned to that user on
   this account. Do not create IAM users or access keys, and never a root access key. On the laptop, run
   `aws configure sso` with the access portal URL, SSO region us-west-1, the management account, role
   `AA-Bootstrap`, default region us-west-1, and name the profile `aa-mgmt`. Sign in again later with
   `aws sso login --profile aa-mgmt`.
   - Verify (expected: the management account ID and an `AWSReservedSSO_AA-Bootstrap_...` role):

     ```bash
     aws sts get-caller-identity --profile aa-mgmt
     ```

5. **Open Cost Explorer once** (Billing and Cost Management, Cost Explorer, Launch). AWS needs up to 24 hours
   before Cost Anomaly Detection monitors can be created. Do this on day 1, apply on day 2 if the first apply
   fails on `aws_ce_anomaly_monitor`.

## 3. State bucket (bootstrap, once)

Same layout as the blueprint (§7 "Bố trí state"): one bucket per account, in that account. Replace
`<management-account-id>` with the 12-digit ID from step 1.

```bash
aws sts get-caller-identity --profile aa-mgmt
aws s3api create-bucket --bucket aa-tfstate-<management-account-id>-usw1 --region us-west-1 --create-bucket-configuration LocationConstraint=us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-versioning --bucket aa-tfstate-<management-account-id>-usw1 --versioning-configuration Status=Enabled --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-public-access-block --bucket aa-tfstate-<management-account-id>-usw1 --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-ownership-controls --bucket aa-tfstate-<management-account-id>-usw1 --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-encryption --bucket aa-tfstate-<management-account-id>-usw1 --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}" --region us-west-1 --profile aa-mgmt  # WRITE
```

Verify: `aws s3api get-bucket-versioning --bucket aa-tfstate-<management-account-id>-usw1 --region us-west-1 --profile aa-mgmt`
prints `"Status": "Enabled"`. Rollback: the bucket is empty, delete it.

## 4. Plan and apply order

All commands run from `accounts/management/`. Fill `terraform.tfvars` first (`cp terraform.tfvars.example terraform.tfvars`;
leave `member_accounts` empty for apply 1).

What the console created is adopted, not recreated:

- **The organization** is imported by the `import` block in `organization.tf` (same effect as
  `terraform import aws_organizations_organization.this <organization-id>`, but reviewed in the plan and needing no
  separate command). The plan shows it as "1 to import".
- **The Identity Center instance** is not a Terraform resource (the provider can only read it), so there is nothing
  to import: `data.aws_ssoadmin_instances` finds it, and the plan stops with a clear error if step 3 was skipped.
- The manual `AA-Bootstrap` permission set and the tech lead's user stay outside Terraform; delete the permission
  set after apply 1.

```bash
terraform init -backend-config="bucket=aa-tfstate-<management-account-id>-usw1" -backend-config="profile=aa-mgmt"
terraform plan -out=mgmt.tfplan
terraform apply mgmt.tfplan
```

| Apply | When | Expected plan | Check after |
|---|---|---|---|
| 1. Governance | Day 1-2, no member account yet | 1 to import (the organization), 1 in-place change (its trusted access list), about 44 to add (3 OUs, 3 SCPs + 9 attachments, 3 groups, 4 permission sets + 4 policy attachments, 2 assignments, 2 budgets, 1 monitor + 1 subscription, KMS key + alias, trail bucket + 7 bucket settings, the trail, root access features), **0 to destroy** | Trail delivers (`aws cloudtrail get-trail-status --name aa-org-trail --region us-west-1 --profile aa-mgmt`, `LatestDeliveryError` empty); sign in through the access portal with `AA-Admin`, then delete the manual `AA-Bootstrap` permission set |
| 2. Each invited account | After it accepted the invitation (§6) | 1 to import (the account, stays under the root), its budget, monitor, subscription and assignments to add, 0 to destroy | Developers and admins see the account in the access portal |
| 3. Move to its OU | One quiet week after apply 2: set `ou` to `nonprod` (the nonprod and ai accounts, open question in the PR) | 1 in-place change (`parent_id`) | The SCP tests in §7 |
| 4. Prod account | At go-live (ADR 0018): add `prod` with `account_id = null`, a new root e-mail, `ou = "prod"` | 1 account to create, its budget, monitor, subscription, assignments | Account in OU Prod; `OrganizationAccountAccessRole` exists in it |

After apply 1, add people: Identity Center, Users, create each person, add to `aa-admins`, `aa-developers` or
`aa-billing`. Membership is not in Terraform, so no personal e-mail lands in the public repo.

A plan that wants to destroy the organization, an account or the trail bucket fails on `prevent_destroy`. That is
intended: stop and find out why.

## 5. Manual steps only the tech lead or the business owner can do

| Step | Who | Where |
|---|---|---|
| Root MFA (2 FIDO2 keys), alternate contacts, account name | Tech lead + business owner | §2 step 1 |
| Payment method and tax details of the management account | Business owner | §2 step 1 |
| Activate IAM access to billing | Tech lead | §2 step 2 |
| Enable Identity Center in us-west-1 (creates the organization), MFA settings | Tech lead | §2 step 3 |
| Bootstrap permission set and `aws configure sso` | Tech lead | §2 step 4 |
| Launch Cost Explorer | Tech lead | §2 step 5 |
| State bucket | Tech lead | §3 |
| Applies 1-4 (MFA session) | Tech lead | §4 |
| Users and group membership | Tech lead | §4 |
| Send invitations, accept them in the member accounts, vendor and billing paperwork | Tech lead + business owner | §6 |
| `OrganizationAccountAccessRole` in each invited account | Tech lead | §6 |

## 6. Inviting the existing accounts

Order and preconditions are in blueprint §3 (root e-mail owned by the company, root MFA, own payment method, cost
data exported, no running wave). Both invitations wait for the business owner's billing decision. The ai account
goes first, and only if the billing model allows it; the nonprod account is today a member of a reseller's
organization and goes only after that reseller has released it (an account belongs to one organization at a time).

1. Send the invitation from the management account (replace the ID; one line):

   ```bash
   aws organizations invite-account-to-organization --target Id=<member-account-id>,Type=ACCOUNT --profile aa-mgmt --region us-west-1  # WRITE
   ```

2. Accept in the member account (console: Organizations, Invitations; or `aws organizations accept-handshake --handshake-id <handshake-id>`
   with that account's profile). The account lands under the root: no SCP of ours applies, so it can still leave.
3. Add its entry to `member_accounts` with `account_id` and `ou = "root"`, then apply 2.
4. Create `OrganizationAccountAccessRole` in the invited account (it does not get one): trust the management
   account, AdministratorAccess. For the nonprod account this goes into `accounts/aa365` as a local MFA bootstrap
   apply (follow-up PR); for the ai account into `accounts/acc3-bedrock`.
5. Smoke the account (blueprint §3 step 16 for nonprod; one real LLM call per route for ai), wait one week, then
   apply 3.

Rollback before apply 3: the account can leave (`aws organizations leave-organization` from the member, needs its
own payment method) or be removed from the management side. After apply 3, set `ou = "root"` again and apply.

## 7. Testing the SCPs

Run these once per account right after apply 3, with an `AA-Developer` session in that account (profile names
from blueprint §8, for example `aa-nonprod`). Positive controls first, so a failure means the SCP, not the session.

1. **Positive control.** `aws sts get-caller-identity --profile aa-nonprod` and
   `aws ec2 describe-vpcs --region us-west-1 --profile aa-nonprod` both succeed.
2. **Region outside the list is denied.** Expected: `UnauthorizedOperation` naming "an explicit deny in a service
   control policy".

   ```bash
   aws ec2 describe-vpcs --region eu-west-1 --profile aa-nonprod
   ```

   Also `aws sts get-caller-identity --region eu-west-1 --profile aa-nonprod` must still succeed (global service).
3. **Trail protection, with no side effect.** Use a trail name that does not exist: with the SCP the call is
   denied before the lookup (`AccessDeniedException`, service control policy); without it you get
   `TrailNotFoundException` and nothing changes.

   ```bash
   aws cloudtrail stop-logging --name aa-scp-test-does-not-exist --region us-west-1 --profile aa-nonprod
   ```

4. **Leave-organization is denied.** Check without side effects first: IAM console of the member account, Policy
   simulator, action `organizations:LeaveOrganization` for the `AWSReservedSSO_AA-Developer_*` role, expected
   "denied" by an Organizations SCP. Then, only if the simulator says denied, the live call (expected
   `AccessDeniedException` naming a service control policy):

   ```bash
   aws organizations leave-organization --profile aa-nonprod
   ```

   If it ever succeeds, the account has left: invite it again (§6) and file an incident.
5. **Bedrock still answers (ai and nonprod).** One real call per route through `LLMClient` (stage
   `adhoc_aa1004`, logged in `shared.llm_call_log`), including a `global.` inference profile. AccessDenied naming a
   service control policy means `bedrock_extra_regions` is wrong: set `ou = "root"` for that account, apply, fix.

Evidence (command output) goes into `docs/audits/<date>-S<nnn>-aa1004-scp-tests/` in the root repo.

## 8. After the organization trail runs

- After 7 days of clean delivery, remove the nonprod account's own trail `aa-cis-dev-trail` in `accounts/aa365`
  (a PR). Until then the nonprod account pays the second copy of its management events (2 USD per 100k events).
  Keep its old bucket until its Object Lock retention ends.
- Later, optional: delete the root credentials of invited accounts through centralized root access, once their root
  e-mail is confirmed as company-owned.

## 9. Rollback

| Problem | Rollback |
|---|---|
| An SCP blocks real work in an account | Set that account's `ou = "root"` and apply (no SCP of ours there), or in the console detach the one policy from the OU. Then fix the policy text in a PR |
| An SCP breaks every account at once | Management console, Organizations, Policies: detach it from the three OUs (SCPs never bind the management account, so this always works) |
| Identity Center sign-in broken | Root of the management account (FIDO2), fix Identity Center; member accounts through `OrganizationAccountAccessRole` |
| Organization trail fails | Remove `aws_cloudtrail.organization` in a PR and apply; the bucket stays (`prevent_destroy`, Object Lock) |
| A member must leave the organization | Not through Terraform (`prevent_destroy`): remove it from the management side or leave from the member, then drop its entry and `terraform state rm` it |
| Abandon the whole root before members join | Possible while the organization has no member: remove the `prevent_destroy` lines deliberately in a PR, destroy, close the organization |

## 10. Cost

| Item | USD per month |
|---|---|
| Organizations, Identity Center, SCPs, budgets without actions, Cost Anomaly Detection | 0 |
| KMS key of the trail | 1 |
| Trail bucket (management events, a few GB a year) | under 0.5 |
| Second copy of the nonprod account's events until its own trail is removed | about 0-1 |
| **Total** | **about 1-2.5** |

## 11. CI wiring (not enabled)

The root is applied by the tech lead until these exist, each in its own PR:

1. Bootstrap in the management account (local MFA apply): GitHub OIDC provider, roles `aa-terraform-plan`
   (read-only, trusts `pull_request` and `ref:refs/heads/main` of AA-CIS-Infra by the immutable subject, see
   `CONTEXT.md` "CI/CD and OIDC") and `aa-terraform-apply` (trusts only `environment:org` and `main`), each with a
   permissions boundary, max session 2 hours.
2. GitHub environments `org` (apply) and `org-plan` with the tech lead as required reviewer; environment variables
   for the management account ID, organization ID, state bucket and alert e-mails (masked in logs).
3. `terraform-plan.yml`: a second job (or matrix entry) for `accounts/management`, run only when
   `accounts/management/**` changes, with the plan role of the management account; summary only, no plan file.
4. `terraform-apply.yml`: a `root` input (`aa365` or `management`); `management` runs in environment `org`.
5. `tools/terraform/plan_guard.py`: refuse any delete or replace of `aws_organizations_organization`,
   `aws_organizations_account`, `aws_organizations_policy_attachment` (detaching an SCP), `aws_cloudtrail` and the
   trail bucket unless `allow_guarded=true` with a reason.
6. `terraform-drift.yml`: add the root to the matrix; `tools/terraform/tests/test_drift_report.py` compares it with
   `terraform-plan.yml`.
