# accounts/management: the management account root (AA-1004)

> [!WARNING]
> UNTESTED - prepared for a brand-new management account; nothing here has been planned or applied. Do not follow
> a step without checking it, and read every plan for destroys.

Terraform root for the management account of the lean AWS model (root ADR 0018, Proposed; S258 blueprint
`docs/audits/2026-10-29-S258-aws-org-blueprint/` §0 in the root repo). It holds governance only. No workload ever
runs in the management account, because SCPs do not apply there.

| File | Holds |
|---|---|
| `organization.tf` | The organization (created by apply 1), OUs `NonProd` / `Prod` / `Suspended`, member accounts (invited ones imported, prod created), centralized root access |
| `scp.tf` + `policies/*.json.tftpl` | 3 SCPs, attached to the three OUs, never to the root |
| `identity_center.tf` | Groups `aa-admins` / `aa-developers` / `aa-billing`, permission sets `AA-Admin` / `AA-Developer` / `AA-ReadOnly` / `AA-Billing`, the group x account matrix, users from `sso_users` (all gated on `identity_center_enabled`) |
| `budgets.tf` | Organization budget, one budget per account, one Cost Anomaly Detection monitor + daily e-mail per account |
| `cost_anomaly_app_tag.tf` | One anomaly monitor per `App` tag value + one daily e-mail, off until the nonprod account joins and `App` is active here (`app_tag_anomaly_monitors_enabled`, AA-896) |
| `cloudtrail.tf` | Organization trail `aa-org-trail`, its KMS key and its bucket (Object Lock GOVERNANCE, 365 days) |
| `cicd.tf` | GitHub OIDC provider, CI roles `aa-terraform-plan` (read only) and `aa-terraform-apply` (+ boundary `aa-terraform-apply-boundary`); bootstrap objects, applied locally (§11) |
| `terraform.tfvars.example` | Every input; copy to `terraform.tfvars` (git-ignored: the repo is public, no account ID, name or e-mail is committed) |

Access matrix (permission sets per group and account):

| Group | aa-management | aa-nonprod | aa-ai | aa-prod |
|---|---|---|---|---|
| `aa-admins` (tech lead) | AA-Admin | AA-Admin, AA-Developer | AA-Admin, AA-Developer | AA-Admin, AA-ReadOnly |
| `aa-developers` (engineers) | none | AA-Developer | AA-Developer | AA-ReadOnly |
| `aa-billing` (business owner) | AA-Billing | none | none | none |

CI roles and the agent never get an Identity Center assignment: they use IAM roles inside each account (for this
account: `aa-terraform-plan` / `aa-terraform-apply`, `cicd.tf`, §11). The agent reaches the management account only
through the temporary `AA-Bootstrap` role during bootstrap (§2-§4), then through the tech lead's session or CI.

## 1. Before you start

- The tech lead created the management account on 2026-10-30 (fresh, empty). Its ID goes only into the local,
  git-ignored `terraform.tfvars` and the local `~/.aws/config` (and, for CI, the repository secrets `MGMT_ACCOUNT_ID`
  and `MGMT_TFVARS`, §11); never into a committed file.
- No root access key and no IAM user, ever. Bootstrap runs through a temporary IAM role `AA-Bootstrap` in the
  management account, assumed from the nonprod account's admin role (itself MFA-protected). Once an Identity Center
  sign-in works, the role is deleted and everyone signs in through Identity Center.
- Two FIDO2 security keys: one for the tech lead, one for the business owner's safe.
- The billing model (blueprint §5) decides whether, and when, the ai and nonprod accounts are invited (§6). Applies
  1 and 2 need no member account.
- One Terraform process at a time; Terraform `1.15.5` exactly (`versions.tf`).

## 2. Day 1: steps only a human can do

1. **Root user (tech lead with the business owner).** Sign in as root. Register both FIDO2 keys as MFA. Rename the
   account to `aa-management` (Account settings; it was created under another display name, and the name is what
   members and invoices show). Set the alternate contacts (billing, operations, security) to role mailboxes.
   The business owner adds the company card and tax details (Billing, Payment preferences, Tax settings).
   - Verify: IAM, Security credentials shows two MFA devices and no access key.
2. **Activate IAM access to billing.** Account settings, "IAM user and role access to Billing information",
   Activate. Without it `AA-Bootstrap` cannot create budgets and `AA-Billing` sees "access denied".
3. **Create the bootstrap role `AA-Bootstrap`** (root user, IAM console, Roles, Create role, custom trust policy).
   Attach `AdministratorAccess`, maximum session 1 hour. Trust only the nonprod account's admin role, the role the
   `aa365-admin` profile assumes (look its ARN up locally; never paste it into a repo):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "AWS": "<arn-of-the-nonprod-admin-role>" },
         "Action": "sts:AssumeRole"
       }
     ]
   }
   ```

   IAM is global, so the console's default region does not matter here. It does matter in step 4: a new account's
   console opens outside our region (this one showed eu-north-1).
4. **After apply 1 (§4): enable IAM Identity Center, one click.** Switch the region selector to **US West
   (N. California) us-west-1 first**: an instance lives where it is enabled, and moving it means deleting it with
   every user, group and assignment. Open IAM Identity Center, Enable, organization instance. Then in its settings:
   identity source stays the Identity Center directory; Authentication, MFA "every time they sign in", security
   keys and authenticator apps, users without MFA register one at sign-in.
   - Verify: the dashboard shows region us-west-1 and an AWS access portal URL.
5. **Open Cost Explorer once** (Billing and Cost Management, Cost Explorer, Launch), as root or through
   `AA-Bootstrap`. Anomaly monitors can be created only once it is ready (up to 24 hours); if apply 1 fails on
   `aws_ce_anomaly_monitor`, run it again the next day.

## 3. Local profile and state bucket (bootstrap, once)

The local profile chains from the nonprod admin profile into `AA-Bootstrap`. Role chaining caps a session at
1 hour. Add to `~/.aws/config` on the laptop (a local file, not a repo):

```ini
[profile aa-mgmt]
role_arn = arn:aws:iam::<management-account-id>:role/AA-Bootstrap
source_profile = aa365-admin
region = us-west-1
duration_seconds = 3600
```

Same bucket layout as the blueprint (§7 "Bố trí state"): one bucket per account, in that account.

```bash
aws sts get-caller-identity --profile aa-mgmt
aws s3api create-bucket --bucket aa-tfstate-<management-account-id>-usw1 --region us-west-1 --create-bucket-configuration LocationConstraint=us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-versioning --bucket aa-tfstate-<management-account-id>-usw1 --versioning-configuration Status=Enabled --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-public-access-block --bucket aa-tfstate-<management-account-id>-usw1 --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-ownership-controls --bucket aa-tfstate-<management-account-id>-usw1 --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region us-west-1 --profile aa-mgmt  # WRITE
aws s3api put-bucket-encryption --bucket aa-tfstate-<management-account-id>-usw1 --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}" --region us-west-1 --profile aa-mgmt  # WRITE
```

Verify: the first command prints the management account and an `assumed-role/AA-Bootstrap/...` ARN, and
`aws s3api get-bucket-versioning --bucket aa-tfstate-<management-account-id>-usw1 --region us-west-1 --profile aa-mgmt`
prints `"Status": "Enabled"`. Rollback: the bucket is empty, delete it.

## 3a. Day-to-day access after bootstrap (Identity Center, S261)

The bootstrap chain in §3 (`AA-Bootstrap`) was removed after day 1. Day-to-day access is through IAM Identity Center:

- AWS access portal: `https://d-9167778552.awsapps.com/start` (us-west-1). Permission set `AA-Admin` on `aa-management`.
- Local CLI (added S261, 31/10/2026), in `~/.aws/config`:

```ini
[sso-session aa-mgmt-sso]
sso_start_url = https://d-9167778552.awsapps.com/start
sso_region = us-west-1
sso_registration_scopes = sso:account:access

[profile aa-mgmt]
sso_session = aa-mgmt-sso
sso_account_id = <management account id>
sso_role_name = AA-Admin
region = us-west-1
```

- Sign in (device code, approve in the browser): `aws sso login --sso-session aa-mgmt-sso --no-browser --use-device-code`.
  Check: `aws sts get-caller-identity --profile aa-mgmt`. The session lasts about 8 hours.
- Local Terraform with this profile uses the same env-no-export recipe as §4 with `--profile aa-mgmt`.
- Done with this profile in S261: the Anthropic use-case form for the organization (raw JSON through
  `aws bedrock put-use-case-for-model-access --form-data fileb://ftu.json --region us-west-1 --profile aa-mgmt`).

## 4. Plan and apply order

All commands run from `accounts/management/`. Fill `terraform.tfvars` first (`cp terraform.tfvars.example terraform.tfvars`).

Terraform cannot answer the MFA prompt of the source profile, so export the chained session first and pass it as
environment credentials (the workspace pattern; it refuses to run when the export is empty). Leave `aws_profile`
unset in `terraform.tfvars` for this path. Each line is one command; the last word is the Terraform step
(`init -backend-config="bucket=aa-tfstate-<management-account-id>-usw1"`, then `plan -out=mgmt.tfplan`, then
`apply mgmt.tfplan`):

```bash
bash -c 'C=$(aws configure export-credentials --profile aa-mgmt --format env-no-export </dev/null) ; grep -q "^AWS_ACCESS_KEY_ID=" <<<"$C" || exit 1 ; env -u AWS_PROFILE $(tr "\n" " " <<<"$C") terraform init -backend-config="bucket=aa-tfstate-<management-account-id>-usw1"'
bash -c 'C=$(aws configure export-credentials --profile aa-mgmt --format env-no-export </dev/null) ; grep -q "^AWS_ACCESS_KEY_ID=" <<<"$C" || exit 1 ; env -u AWS_PROFILE $(tr "\n" " " <<<"$C") terraform plan -out=mgmt.tfplan'
```

Then the same wrapper with `terraform apply mgmt.tfplan` after reading the plan.

**Trusted access check before every apply after apply 1.** `aws_service_access_principals` replaces the whole
list. Run the command below. Every principal it prints that is not in the base list of `organization.tf` (and is
not `sso.amazonaws.com` once `identity_center_enabled = true`) goes into `extra_service_access_principals`, so the
plan only adds and never switches a service off.

```bash
aws organizations list-aws-service-access-for-organization --profile aa-mgmt --region us-west-1 --query "EnabledServicePrincipals[].ServicePrincipal" --output text
```

The organization is **created by Terraform** in apply 1: the account is new, so there is nothing to import, and this
is simpler than a CLI `create-organization` followed by an import. The Identity Center instance is not a Terraform
resource; after the console click, `data.aws_ssoadmin_instances` reads it.

| Apply | When | Expected plan | Check after |
|---|---|---|---|
| 1. Organization and guards | Day 1, `identity_center_enabled = false`, `member_accounts = {}` | About 32 to add (the organization, 3 OUs, root access features, 3 SCPs + 9 attachments, 2 budgets, 1 monitor + 1 subscription, KMS key + alias, trail bucket + 7 bucket settings, the trail), **0 to change, 0 to destroy** | Organizations shows "All features" with this account as management; `aws cloudtrail get-trail-status --name aa-org-trail --region us-west-1 --profile aa-mgmt` has an empty `LatestDeliveryError` |
| (human) | After apply 1 | §2 step 4: enable Identity Center in us-west-1 | Access portal URL shown |
| 2. Identity Center | Same day: `identity_center_enabled = true`, `sso_users` with the tech lead in group `admins` | No change on the organization when the trusted access check is clean (`sso.amazonaws.com` is now declared); 3 groups, 4 permission sets + 4 policy attachments, 2 assignments (management: `AA-Admin`, `AA-Billing`), 1 user + 1 membership per entry; 0 to destroy | Identity Center, Users, the tech lead, Reset password, send an e-mail. The tech lead signs in, registers MFA and opens the management account as `AA-Admin`. Then point `aa-mgmt` at that session (`aws configure sso`, role `AA-Admin`) and **delete the `AA-Bootstrap` role** |
| 3. Each invited account | After it accepted the invitation (§6) | 1 to import (the account, stays under the root), its budget, monitor, subscription and assignments; 0 to destroy | Developers and admins see the account in the access portal |
| 4. Move to its OU | One quiet week after apply 3: set `ou` to `nonprod` (the nonprod and ai accounts, open question in the PR) | 1 in-place change (`parent_id`) | The SCP tests in §7 |
| 5. Prod account | At go-live (ADR 0018): add `prod` with `account_id = null`, a new root e-mail, `ou = "prod"` | 1 account to create, its budget, monitor, subscription, assignments | Account in OU Prod; `OrganizationAccountAccessRole` exists in it |

After `AA-Bootstrap` is gone, the same wrapper works with `aa-mgmt` as an Identity Center `AA-Admin` session (run
`aws sso login --profile aa-mgmt` first). Other people are added as `sso_users` entries in `terraform.tfvars`.

A plan that wants to destroy the organization, an account or the trail bucket fails on `prevent_destroy`. That is
intended: stop and find out why.

## 5. Manual steps only the tech lead or the business owner can do

| Step | Who | Where |
|---|---|---|
| Root MFA (2 FIDO2 keys), alternate contacts, account name | Tech lead + business owner | §2 step 1 |
| Payment method and tax details of the management account | Business owner | §2 step 1 |
| Activate IAM access to billing | Tech lead | §2 step 2 |
| Create the `AA-Bootstrap` role trusting the nonprod admin role | Tech lead | §2 step 3 |
| Enable Identity Center in us-west-1 (one click) and its MFA settings | Tech lead | §2 step 4 |
| Launch Cost Explorer | Tech lead | §2 step 5 |
| MFA prompt of the `aa365-admin` session behind every chained command | Tech lead | §3, §4 |
| First sign-in, MFA registration, then delete `AA-Bootstrap` | Tech lead | §4 apply 2 |
| Send invitations, accept them in the member accounts, vendor and billing paperwork | Tech lead + business owner | §6 |

The local profile, the state bucket, applies 1-5 and the `OrganizationAccountAccessRole` of invited accounts can be
run by the tech lead or by the agent inside the tech lead's MFA session.

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
3. Add its entry to `member_accounts` with `account_id` and `ou = "root"`, then apply 3.
4. Create `OrganizationAccountAccessRole` in the invited account (it does not get one): trust the management
   account, AdministratorAccess. For the nonprod account this goes into `accounts/aa365` as a local MFA bootstrap
   apply (follow-up PR); for the ai account into `accounts/acc3-bedrock`. Do it **before apply 4**: once the account
   is in an OU, SCP 2 lets only the exempt roles create or change that role.
5. Smoke the account (blueprint §3 step 16 for nonprod; one real LLM call per route for ai), wait one week, then
   apply 4.

Rollback before apply 4: the account can leave (from the member, needs its own payment method) or be removed from
the management side. After apply 4, set `ou = "root"` again and apply.

## 7. Testing the SCPs

Run these once per account right after apply 4, with an `AA-Developer` session in that account (profile names
from blueprint §8, for example `aa-nonprod`). Positive controls first, so a failure means the SCP, not the session.
No test below changes anything when the SCP is missing.

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

4. **Leave-organization is denied, checked without calling it.** Never run `leave-organization` as a test: if the
   SCP were missing, the account would leave. Instead:
   - the account sits in the expected OU and the OU carries the SCP (management side):

     ```bash
     aws organizations list-parents --child-id <member-account-id> --profile aa-mgmt --region us-west-1
     aws organizations list-policies-for-target --target-id <ou-id> --filter SERVICE_CONTROL_POLICY --profile aa-mgmt --region us-west-1
     ```

     Expected: the parent is the `NonProd` (or `Prod`) OU from the `ou_ids` output, and the list holds
     `FullAWSAccess` plus the three `aa-scp-*` policies;
   - IAM console of the member account, Policy simulator, the `AWSReservedSSO_AA-Developer_*` role, action
     `organizations:LeaveOrganization`: expected "denied" by an Organizations SCP.
5. **Exempt roles are protected.** Same simulator, same role, action `iam:UpdateAssumeRolePolicy` on
   `OrganizationAccountAccessRole` and `iam:CreateRole` on a role named `aa-terraform-apply`: both denied by an
   Organizations SCP.
6. **Bedrock still answers (ai and nonprod).** One real call per route through `LLMClient` (stage
   `adhoc_aa1004`, logged in `shared.llm_call_log`), including a `global.` inference profile. AccessDenied naming a
   service control policy means the inference-profile exception of SCP 3 does not cover that route: set
   `ou = "root"` for that account, apply, fix.

Evidence (command output) goes into `docs/audits/<date>-S<nnn>-aa1004-scp-tests/` in the root repo.

## 8. After the organization trail runs

- After 7 days of clean delivery, remove the nonprod account's own trail `aa-cis-dev-trail` from `accounts/aa365`
  in a PR and apply it **through the CI apply role** (`aa-cis-infra-tf-apply`, Terraform Apply workflow): once the
  account is in an OU, SCP 2 denies `DeleteTrail` to every other principal. Until then the nonprod account pays the
  second copy of its management events (2 USD per 100k events). Keep its old bucket until its Object Lock retention
  ends. The plan guard refuses every `aws_cloudtrail` delete (§11), so dispatch that apply with
  `allow_guarded=true` and `allow_reason` naming this step.
- Later, optional: delete the root credentials of invited accounts through centralized root access, once their root
  e-mail is confirmed as company-owned.

## 9. Rollback

| Problem | Rollback |
|---|---|
| An SCP blocks real work in an account | Set that account's `ou = "root"` and apply (no SCP of ours there), or in the console detach the one policy from the OU. Then fix the policy text in a PR |
| An SCP breaks every account at once | Management console, Organizations, Policies: detach it from the three OUs (SCPs never bind the management account, so this always works) |
| Identity Center sign-in broken | Root of the management account (FIDO2), fix Identity Center; member accounts through `OrganizationAccountAccessRole` |
| Organization trail fails | Remove `aws_cloudtrail.organization` in a PR and apply; the bucket stays (`prevent_destroy`) |
| The trail bucket itself must go | Not within 365 days of the last log file without a GOVERNANCE bypass: every object version is locked, and deleting one needs `s3:BypassGovernanceRetention` plus the bypass header, object by object. Plan for the bucket to live a year after the last write |
| A member must leave the organization | Not through Terraform (`prevent_destroy`): remove it from the management side or leave from the member, then drop its entry and `terraform state rm` it |
| Abandon the whole root before members join | Possible while the organization has no member: remove the `prevent_destroy` lines deliberately in a PR, destroy, close the organization (the trail bucket stays until its locks expire) |

## 10. Cost

| Item | USD per month |
|---|---|
| Organizations, Identity Center, SCPs, budgets without actions, Cost Anomaly Detection | 0 |
| KMS key of the trail | 1 |
| Trail bucket (management events, a few GB a year) | under 0.5 |
| Second copy of the nonprod account's events until its own trail is removed | about 0-1 |
| **Total** | **about 1-2.5** |

## 11. CI wiring

Built in code (AA-1004): `cicd.tf` here, plus jobs in `terraform-plan.yml`, `terraform-apply.yml` and
`terraform-drift.yml`. It goes live after the one-time steps 11.1 and 11.2. Until then the plan and drift jobs of this
root warn and skip (they fail instead once the repo variable `MGMT_CI_LIVE` is `true`), and the root is applied as in
§4.

| Workflow | When | Role in the management account | OIDC subject (immutable form) |
|---|---|---|---|
| Terraform Plan, job "Terraform Plan (management)" | A PR touching `accounts/management/**`, `terraform-plan.yml` or `drift_report.py` | `aa-terraform-plan` (read only) | `...:pull_request` |
| Terraform Drift, matrix entry `accounts/management` | Nightly 05:37 UTC and by hand, from `main` | `aa-terraform-plan` | `...:ref:refs/heads/main` |
| Terraform Apply Prod, `root = management`, job "Terraform Plan (management, for review)" | Manual dispatch from `main` | `aa-terraform-plan` | `...:ref:refs/heads/main` |
| Same run, job "Terraform Apply (management)" | After the `org` environment's reviewer approves | `aa-terraform-apply` (boundary `aa-terraform-apply-boundary`) | `...:environment:org`, plus the `ref` claim `refs/heads/main` |

- **No blind approval.** The review-plan job writes the masked plan summary and a digest (SHA-256 of the sorted
  planned address/action list). The reviewer reads that summary, then approves the `org` deployment. The apply job
  first checks that `org` carries a required reviewer and a branch policy (an environment GitHub auto-creates on a first
  run has neither) and stops before any secret or credential if not; then it re-plans with the apply role and fails
  when the digest differs from the reviewed one; then the plan guard; then it applies exactly that saved plan. The
  digest covers addresses and actions, not attribute values: a value-only difference between the two plans (same
  resources, same actions) is not caught.
- **No plan text in the logs.** This root's plan holds e-mail addresses and member account IDs, and the repo's run
  logs are public. Terraform runs with `-json` into `RUNNER_TEMP`; `tools/terraform/drift_report.py` (`--mode plan`,
  `--mode apply`, drift) writes only resource addresses, actions and masked errors to the job summary; the index key
  of an `aws_identitystore_*` address is redacted (`[{key}]`), and `sso_users` keys must be handles `u1`, `u2`, ...
  (validated). Every 12-digit number and e-mail in the inputs is masked in the log before Terraform starts. No
  `terraform output` in CI.
- **Plan guard.** Besides the aa365 types, `plan_guard.py` refuses any delete, replace or forget of an organization,
  OU, member account, SCP or SCP attachment, trail, trail bucket policy, centralized root access, permission set (or its
  policy), account assignment, Identity Center user, group or membership, and an update of the organization that drops
  an enabled policy type or a trusted-access principal (or leaves either unknown). Create, other updates and import
  pass. An intended change (a user who leaves, README §8 trail removal) is dispatched with `allow_guarded=true` and an
  `allow_reason`.
- **Apply role scope.** Organizations, identity store, Identity Center (`sso:*` through AWS managed
  `AWSSSOMasterAccountAdministrator`), budgets, anomaly detection, CloudTrail, the trail key and bucket settings, this
  root's state objects, plus `ReadOnlyAccess` for refresh. Its boundary denies: **every IAM role write and PassRole**
  (`UpdateAssumeRolePolicy` included, on every role, the Identity Center `aws-reserved/sso.amazonaws.com/` roles too:
  Identity Center provisions those itself), every SAML / OIDC provider write, users, keys, groups and customer managed
  policies, leaving / closing / removing accounts, deleting the organization, invitations, delegated administrators,
  `account:*`, switching off centralized root access, `cloudtrail:StopLogging`, deleting the trail bucket or any log
  object, governance bypass, disabling, deleting or decrypting with the trail key, `sts:AssumeRole` and
  `sts:AssumeRoot`. If a CI apply of an account assignment in this (management) account ever fails with an IAM
  AccessDenied, that assignment change is a local apply (§4).
- **`account:*` is local only.** Alternate contacts, the account name and other Account Management settings (of this
  or a member account) are never changed by CI; they stay console or local-apply steps (§2 step 1). The trusted access
  for `account.amazonaws.com` in `organization.tf` only lets a local session set them from here.
- **Bootstrap objects.** Everything in `cicd.tf` (OIDC provider, both roles, their policies, the boundary) is changed
  only by a local apply (§4 wrapper). A CI apply of such a change fails with AccessDenied by design.

### 11.1 One-time bootstrap (local, tech lead's session)

After apply 2 of §4 (the organization exists; `AA-Bootstrap` or an `AA-Admin` session), from the commit that holds
`cicd.tf`, in `accounts/management/`, with the usual `terraform.tfvars`:

1. **Rename the `sso_users` key** of the tech lead from `techlead` to `u1` in the local `terraform.tfvars` (keys must
   match `^u[0-9]+$`, the plan fails otherwise). `identity_center.tf` carries `moved` blocks for exactly that rename, so
   the plan shows the user and its group membership as **moved**, not destroyed and created: the user keeps its ID,
   password and MFA device. Any other key needs its own `moved` block in a PR first.
2. Plan with the §4 wrapper (`plan -out=mgmt.tfplan`). Expected: **9 to add, 0 to change, 0 to destroy** (plus the two
   moves of step 1) when the rest of the root is in sync: `aws_iam_openid_connect_provider.github_actions`,
   `aws_iam_role.ci_plan`, `aws_iam_role_policy_attachment.ci_plan_readonly`, `aws_iam_role_policy.ci_plan`,
   `aws_iam_policy.ci_apply_boundary`, `aws_iam_role.ci_apply`, `aws_iam_role_policy_attachment.ci_apply_managed`
   (2: `ReadOnlyAccess`, `AWSSSOMasterAccountAdministrator`) and `aws_iam_role_policy.ci_apply`. Anything else in the
   plan: stop and find out why.
3. Apply that plan with the same wrapper (`apply mgmt.tfplan`).
4. Verify (one line each):

   ```bash
   aws iam get-role --role-name aa-terraform-apply --profile aa-mgmt --query "Role.[MaxSessionDuration,PermissionsBoundary.PermissionsBoundaryArn]" --output text
   aws iam list-open-id-connect-providers --profile aa-mgmt --output text
   ```

   Expected: `3600` and the `aa-terraform-apply-boundary` ARN; one provider ending in `token.actions.githubusercontent.com`.

Rollback: remove `cicd.tf` in a PR and apply that locally (a CI apply cannot remove the CI roles: bootstrap objects).

### 11.2 GitHub settings (once, repo AdventureAsia365-Ecosys/AA-CIS-Infra), in this order

The environment comes **first**: a dispatch that names a missing environment makes GitHub create it with no
protection rule, and the apply job would then run unreviewed (its own check stops it, but do not rely on one guard).

1. **Environment `org`** with a required reviewer (the tech lead) and deployment branches limited to `main`. The
   reviewer's numeric user ID comes from `gh api users/<login> --jq .id`. Write
   `{"reviewers":[{"type":"User","id":<user id>}],"prevent_self_review":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}`
   to a scratch file `env-org.json`, then:

   ```bash
   gh api -X PUT repos/AdventureAsia365-Ecosys/AA-CIS-Infra/environments/org --input env-org.json
   gh api -X POST repos/AdventureAsia365-Ecosys/AA-CIS-Infra/environments/org/deployment-branch-policies -f name=main -f type=branch
   gh api repos/AdventureAsia365-Ecosys/AA-CIS-Infra/environments/org --jq "[.protection_rules[].type, .deployment_branch_policy]"
   ```

   Expected from the last line: `required_reviewers` and `branch_policy` rules, custom branch policies on.
   `prevent_self_review` is off on purpose: the gate is there to stop an unattended (agent or bot) dispatch, and the
   tech lead may dispatch and approve their own run. No `org-plan` environment: a reviewer in front of every PR plan
   adds nothing to a read-only role.
2. **Repository secret `MGMT_ACCOUNT_ID`**: the 12-digit management account ID. CI builds both role ARNs and the
   state bucket name (`aa-tfstate-<id>-usw1`, §3) from it, so there is no bucket setting. The value is typed at the
   prompt, never on the command line:

   ```bash
   gh secret set MGMT_ACCOUNT_ID --repo AdventureAsia365-Ecosys/AA-CIS-Infra
   ```

3. **Repository secret `MGMT_TFVARS`**: the content of the local `terraform.tfvars` (with the `u1` key of 11.1) without
   the `aws_profile` line (CI refuses a secret that sets it). Run from `accounts/management/`:

   ```bash
   grep -vE '^[[:space:]]*aws_profile[[:space:]]*=' terraform.tfvars | gh secret set MGMT_TFVARS --repo AdventureAsia365-Ecosys/AA-CIS-Infra
   ```

   Set it again after every change of `terraform.tfvars` (users, member accounts, flags), before the next CI plan;
   otherwise CI plans against old inputs and shows changes that undo the local ones.

   Secrets, not variables: GitHub masks secrets in the public logs, not variables. Repository level, not environment:
   the PR plan, the drift run and the review plan have no environment (their OIDC subjects are `pull_request` and
   `ref:refs/heads/main`, which is what the plan role trusts), and an environment's secrets reach only jobs in that
   environment. Fork PRs get neither the secrets nor an OIDC token.
4. **Repository variable `MGMT_CI_LIVE` = `true`**, last: from then on a missing secret fails the management plan and
   drift jobs instead of warning.

   ```bash
   gh variable set MGMT_CI_LIVE --body true --repo AdventureAsia365-Ecosys/AA-CIS-Infra
   ```

### 11.3 First CI runs to expect

1. **Drift, by hand on `main`** (Actions, Terraform Drift, Run workflow) once the PR with `cicd.tf` is merged and
   11.1-11.2 are done. Expected: the `accounts/management` entry green, "In sync". The aa365 entry is unchanged.
2. **PR plan**: the next PR touching `accounts/management/**` shows job "Terraform Plan (management)" with
   **"No changes"** in its summary (or only that PR's changes).
3. If either shows changes nobody made: `MGMT_TFVARS` differs from the local `terraform.tfvars` (set it again, 11.2),
   or someone changed the account outside Terraform. Do not apply until the difference is explained. An AccessDenied
   during refresh names a read missing from `aa-terraform-plan` (`PlanRefreshReads` in `cicd.tf`): add it and repeat
   11.1 (local apply).
4. **First CI apply** only for a real change: Terraform Apply Prod, `root = management`. Read the summary of
   "Terraform Plan (management, for review)", then approve the `org` deployment; the apply job's summary shows the
   environment check, the re-plan (same digest), the guard result and what was applied.

