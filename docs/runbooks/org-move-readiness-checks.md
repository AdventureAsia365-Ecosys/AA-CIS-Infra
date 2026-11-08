# Nonprod account: read-only checks before the move into the AA organization (AA-1004)

The nonprod account (acc2, profile `aa365-admin`) moves from the reseller's AWS organization into the AA organization
on 01/12/2026 (Billing Transfer plan, S271; procedure in [`accounts/management/README.md`](../../accounts/management/README.md)
§6). This page lists what can be checked **from the member account, read only**, before 20/11, what a member account
cannot see at all, and the questions only the reseller can answer.

Rules for running it:

- Every command is one line and changes nothing (no `# WRITE` command on this page). Profile `aa365-admin`, region
  `us-west-1`. Run `aws sts get-caller-identity --profile aa365-admin --region us-west-1` first and check the account.
- Outputs hold the reseller's organization ID, its management account ID and e-mail. Paste them only into the private
  notes of the session, masked (`python3 tools/docs/aws_mask.py`) if they go anywhere in a repo; never into this public
  repo.
- `aws iam` reads are refused to agent subagents by a hook; the orchestrating session or the tech lead runs them.

## 1. What a member account can see

| # | Check | Command | Read the result |
|---|---|---|---|
| 1.1 | Organization membership | `aws organizations describe-organization --profile aa365-admin --region us-west-1` | `FeatureSet = ALL` and `SERVICE_CONTROL_POLICY` `ENABLED` in `AvailablePolicyTypes` mean the reseller **can** attach SCPs to this account (checked S273: both true). It does not say which SCPs are attached |
| 1.2 | Pending invitations | `aws organizations list-handshakes-for-account --profile aa365-admin --region us-west-1` | Empty before 01/12. After step 5 of README §6: one `INVITE` from the AA organization, state `OPEN` (it expires after 15 days) |
| 1.3 | Does `LeaveOrganization` pass the reseller's SCPs? | First the admin role: `aws sts get-caller-identity --profile aa365-admin --query Arn --output text` (an `assumed-role/<role>/<session>` ARN; the role ARN is `arn:aws:iam::<account>:role/<role>`). Then `aws iam simulate-principal-policy --policy-source-arn <admin role arn> --action-names organizations:LeaveOrganization account:CloseAccount --profile aa365-admin --region us-west-1 --query "EvaluationResults[].[EvalActionName,EvalDecision,OrganizationsDecisionDetail.AllowedByOrganizations]" --output text` | The policy simulator evaluates the SCPs that apply to a member account and reports them in `OrganizationsDecisionDetail`. `AllowedByOrganizations = False` for `LeaveOrganization` proves an SCP denies it: the account cannot leave by itself, the reseller must remove it (question R1). `True` is strong evidence but not proof: the simulator skips SCP conditions on context keys it is not given, and it does not evaluate resource control policies |
| 1.4 | Would the reseller's SCPs let us create the organization admin role? | `aws iam simulate-principal-policy --policy-source-arn <admin role arn> --action-names iam:CreateRole iam:AttachRolePolicy iam:PutRolePolicy iam:TagRole --resource-arns arn:aws:iam::<account>:role/OrganizationAccountAccessRole --profile aa365-admin --region us-west-1 --query "EvaluationResults[].[EvalActionName,EvalDecision,OrganizationsDecisionDetail.AllowedByOrganizations]" --output text` | All `allowed` + `True`: the local apply of README §6 step 2 can run before 20/11. Any `False`: an SCP protects that role name; ask R2 and plan the apply for after the move (the role then goes in while the account sits in `Transitional`, where SCP 2 does not apply) |
| 1.5 | Does a role with that name exist already? | `aws iam get-role --role-name OrganizationAccountAccessRole --profile aa365-admin --region us-west-1 --query "Role.[Arn,CreateDate]" --output text` | `NoSuchEntity` (expected; the S256 Access Analyzer triage saw no such trust): keep `org_access_adopt_existing_role = false`. If it exists, read its trust once (`--query Role.AssumeRolePolicyDocument`), mask it, and set the flag to `true` before the apply (the apply then imports it, replaces its trust and detaches every other policy) |
| 1.6 | Every role trusted from outside (all principal kinds) | `python3 -B tools/terraform/iam_trust_inventory.py live --profile aa365-admin --region us-west-1 --access-analyzer` | Lists the reseller's Identity Center role (`AWSReservedSSO_AdministratorAccess_*`, SAML) and anything else trusted from another account. These are the clean-up items for the first session from 02/12 (S271 plan) |
| 1.7 | Contact details the account needs to stand alone | `aws account get-contact-information --profile aa365-admin --region us-west-1` and `aws account get-alternate-contact --alternate-contact-type BILLING --profile aa365-admin --region us-west-1` | AWS lets an account leave an organization only with full contact details, a payment method and a support plan (Basic is fine). An `AccessDenied` here means the reseller manages the account's settings centrally: ask R4. The payment method has no read-only CLI: the root user checks Billing, Payment preferences in the console |
| 1.8 | Region inventory for SCP 3 (before leaving `Transitional`, not before the move) | `aws ec2 describe-regions --profile aa365-admin --region us-west-1 --query "Regions[].RegionName" --output text \| tr '\t' '\n' \| xargs -I{} sh -c 'echo {} $(aws resourcegroupstaggingapi get-resources --region {} --profile aa365-admin --query "length(ResourceTagMappingList)" --output text)'` | Any count above 0 outside `us-west-1`, `us-east-1`, `us-west-2` is a resource SCP 3 would cut off: move or delete it first. Untagged resources do not show here; the untagged report (`tools/finops/`) and Cost Explorer by region cover them (Cost Explorer API calls cost 0.01 USD each) |

## 2. What a member account cannot see

These calls are management-account (or delegated administrator) only. From the nonprod account they answer
`AccessDeniedException` ("You don't have permissions to access this resource"), whatever the admin role holds:

- `organizations list-policies-for-target`, `list-policies`, `describe-policy` (which SCPs exist, which apply here);
- `organizations list-parents`, `list-roots`, `list-organizational-units-for-parent` (where the account sits);
- `organizations describe-account`, `list-accounts` (its own entry as the reseller recorded it);
- `organizations describe-effective-policy` does not cover SCPs at all (only management policy types such as tag or
  backup policies);
- the reseller's billing settings: invoices, credits, the payer account's Cost and Usage Reports.

So the exact SCP text, and whether removal is done from the reseller's side, can only come from the reseller.

## 3. Questions for the reseller (in writing, before 20/11)

The business owner sends them; the answers go into the private session notes and drive README §6 steps 2 and 5.

| # | Question | Why we need it |
|---|---|---|
| R1 | Which SCPs apply to our account (root, OU and account level)? Does any of them deny `organizations:LeaveOrganization`? If yes, will you remove the account from your side (`RemoveAccountFromOrganization`) on 01/12, at an agreed hour? | Decides who performs the leave. A member cannot read the SCPs (section 2) |
| R2 | Does any SCP or permission boundary of yours deny IAM writes on a role named `OrganizationAccountAccessRole`, or on roles in general, in our account? | Decides whether the organization admin role is created before 20/11 or right after the move (check 1.4) |
| R3 | Which of your tools or access remain in the account after it leaves (Identity Center permission sets, StackSets, Config rules, delegated administrators, RAM shares, Marketplace subscriptions)? Will you remove them, or may we delete them from 02/12? | Clean-up list; nothing of theirs may keep a way in (check 1.6) |
| R4 | Are the account's contact details, payment method and support plan set so it can stand alone for the hours between leaving and joining? If you manage them centrally, who sets them and when? | AWS refuses the leave otherwise (check 1.7) |
| R5 | In what order do we do it on 01/12: our management account accepts your Billing Transfer invite first, then the account leaves your organization and accepts ours? Is the November usage billed by you in full, and from when does the transfer bill our organization? | Order of README §6 steps 4-6 and the November invoice reconciliation |
| R6 | After the move, can our management account activate cost allocation tags and use Cost Explorer and Cost Anomaly Detection under the Billing Transfer? | The S271 plan recreates budgets, alerts and tags in the management account from 02/12 |

## After the checks

Record the results (masked) in the session notes; then the orchestrator runs README §6 steps 1-3 (local applies by the
tech lead), or holds step 2 until after the move when check 1.4 or answer R2 says an SCP protects the role name.
