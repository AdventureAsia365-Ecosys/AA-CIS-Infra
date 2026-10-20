# Agent session role (AA-730)

Agent shells (Kiro, Claude Code on WSL) assume **`aa-cis-dev-agent-session`** instead of the MFA'd
`aa365-admin` session. The admin profile stays with Nghiệp; Terraform applies and prod migrations
stay in GitHub workflows (`Terraform Apply Prod`, `DB Migrate`).

Defined in `accounts/aa365/agent_session.tf`.

## What it can do

| Allowed | Why agents need it |
|---|---|
| `ecs:Describe*` / `List*` | find tasks, check revisions and rollout |
| `ecs:ExecuteCommand` on `aa-cis-dev-cluster` | the S3-mediated script runner (`skill/aa-cis-schema/references/ecs-exec.md`) |
| `ssm:StartSession` on dev tasks + `AWS-StartPortForwardingSessionToRemoteHost` | DBeaver port-forward to RDS |
| S3 get/put/delete on `aa-cis-bronze-<acct>/scripts/*`, list that prefix | upload scripts, presign, read results |
| CloudWatch Logs read (filter, get, Insights, live tail), CloudWatch alarms/metrics read | debugging, alarm checks |
| `rds:Describe*`, Scheduler/EventBridge read, API Gateway GET, SNS topic read | state checks |
| `lambda:InvokeFunction` on `aa-cis-dev-*`, `aa-tripplanner-dev-*` | TripPlanner extraction ops, probes |

Explicitly denied (stays denied even if an Allow is widened later): every IAM write and
`sts:AssumeRole`; reading Lambda configuration (`GetFunction*`, `ListFunctions` — Lambda env can
hold secrets); RDS delete/modify/restore/stop/start/reboot; EC2 stop/start/terminate;
`ecs:UpdateService` / `RunTask` / `StopTask`, autoscaling; `secretsmanager:GetSecretValue`,
`kms:Decrypt`; anything on the Terraform state bucket and lock table.

Known limit: ECS exec runs code inside the api container with the task's own `DATABASE_URL`, so SQL
through exec is still possible — that is what exec is for.

## WSL setup (once)

Get the role ARN from the Terraform output `agent_session_role_arn`
(`arn:aws:iam::005097885195:role/aa-cis-dev-agent-session`). Add to `~/.aws/config`, reusing the
same source credentials and MFA device as `aa365-admin`:

```ini
[profile aa365-agent]
role_arn       = arn:aws:iam::005097885195:role/aa-cis-dev-agent-session
source_profile = <same source_profile as aa365-admin>
mfa_serial     = <same mfa_serial as aa365-admin>
region         = us-west-1
duration_seconds = 43200
```

In an agent shell: `export AWS_PROFILE=aa365-agent` (never `aa365-admin`).

## Check (Done-when)

```bash
aws sts get-caller-identity --profile aa365-agent          # assumed-role/aa-cis-dev-agent-session/...
aws iam create-user --user-name x --profile aa365-agent    # AccessDenied
aws rds delete-db-snapshot --db-snapshot-identifier x --profile aa365-agent   # AccessDenied
aws ecs list-tasks --cluster aa-cis-dev-cluster --service-name aa-cis-dev-api --profile aa365-agent   # works
aws s3 ls s3://aa-cis-bronze-005097885195/scripts/ --profile aa365-agent  # works
```

Then run one ECS exec script end to end (upload → presign → execute-command → download).

## Caller must be allowed to assume the role (one-time, Nghiệp applies)

The role trusts `arn:aws:iam::005097885195:root` + MFA. With a `:root` trust principal, AWS also
requires the **caller's own identity policy** to grant `sts:AssumeRole` on the role ARN — a `:root`
trust alone is not sufficient (verified S226/S227: assume from `user/nghiep-admin` returned
`AccessDenied`; `nghiep-admin` has only AWS-managed ReadOnly policies, none grant `sts:AssumeRole`).

`nghiep-admin` is a hand-created user, **not** managed by this Terraform state, so attach the grant
directly (do not import the user into state). Policy document: `docs/agent-session-caller-assumerole.json`.

Nghiệp runs (MFA'd `aa365-admin`), one time:

```bash
aws iam put-user-policy --user-name nghiep-admin --policy-name assume-agent-session --policy-document file://docs/agent-session-caller-assumerole.json --profile aa365-admin --region us-west-1
```

Verify (should now succeed instead of AccessDenied):

```bash
aws sts assume-role --role-arn arn:aws:iam::005097885195:role/aa-cis-dev-agent-session --role-session-name probe --profile aa365-admin --region us-west-1
```

After that, the agent `~/.aws/config` profile `aa365-agent` (above) works and AA-730 can be verified
with the Done-when checks.
