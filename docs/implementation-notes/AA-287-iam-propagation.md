# AA-287 — IAM propagation race fix (S102 Phase 3f)

Repo/files: `accounts/aa365/versions.tf`, `accounts/aa365/observability.tf`

## Root-cause verification (before writing any fix)

Fetched the actual job logs for the three post-PR#13 apply failures rather
than trusting the task's premise at face value — the three runs are **not**
all the same bug:

- **Run #59** (2026-07-11 14:59-15:01): `budgets:ModifyBudget` and
  `cloudtrail:CreateTrail` both denied — `aa-cis-dev-role` had no
  Budgets/CloudTrail permissions at all yet. Fixed by PR #15.
- **Run #60** (15:23): CloudTrail created clean; Budget failed on
  `budgets:TagResource` specifically — the tagging API is separate from
  `ViewBudget`/`ModifyBudget`, missed in PR #15's research pass. Fixed by
  PR #16.
- **Run #61** (15:33): `aws_iam_role_policy.cicd_inline: Modifying...` and
  `aws_budgets_budget.total_monthly: Creating...` started within ~200
  microseconds of each other; the IAM modification reported
  `Modifications complete after 1s`, and ~130ms later the Budget creation
  failed with the **same** `budgets:TagResource ... no identity-based
  policy allows` error — even though the policy update (PR #16's fix) had
  already applied successfully by that point. This is the genuine race:
  Terraform's own bookkeeping says the policy update succeeded, but AWS's
  IAM/STS authorization propagation for the already-active assumed-role
  session hadn't caught up in that sub-second window.

Only run #61 is the propagation race this task fixes. Runs #59/#60 were
real, distinct permission gaps — already closed.

## Decisions

- Added `hashicorp/time` (`~> 0.11`, resolved 0.14.0) to
  `required_providers` — wasn't previously used anywhere in this root
  module.
- `time_sleep.wait_for_iam_propagation` — `depends_on =
  [aws_iam_role_policy.cicd_inline]`, `create_duration = "15s"`. Placed in
  `observability.tf` (not `cicd.tf`) since it exists to gate the two
  resources that consume it, both defined in this file — `cicd_inline`
  itself lives in `cicd.tf` but Terraform resolves the cross-file resource
  reference within the same root module without issue.
- 15s is a deliberately conservative wait — AWS document IAM changes as
  "eventually consistent" without a hard upper bound; the actual gap
  observed in run #61 was under a second, but STS/IAM propagation delay is
  known to occasionally reach many seconds under load. No mechanism to
  poll-and-confirm propagation exists for this specific case (unlike, say,
  waiting on a specific IAM role's `GetRole` availability), so a fixed
  sleep is the standard, documented pattern here.
- `depends_on = [time_sleep.wait_for_iam_propagation]` added to both
  `aws_budgets_budget.total_monthly` (previously had no `depends_on`) and
  `aws_cloudtrail.main` (appended to its existing
  `depends_on = [aws_s3_bucket_policy.cloudtrail_logs]`). CloudTrail's
  own resource already applied successfully in run #60, so this addition
  is purely defensive — protects a future clean-slate apply (e.g. disaster
  recovery, a fresh account rebuild) from hitting the same class of race,
  not fixing a live failure on this resource today.

## Should know

- This does not touch `modules/api_gateway`, `modules/alb`, or any other
  module — scoped entirely to `accounts/aa365/versions.tf` (provider
  addition) and `accounts/aa365/observability.tf` (the sleep resource +
  two `depends_on` edits).
- `terraform plan` after this change: `aws_budgets_budget.total_monthly`
  still shows "to add" (has never successfully landed in state across all
  three failed runs), `aws_cloudtrail.main` shows no diff (already settled
  from run #60), and `time_sleep.wait_for_iam_propagation` shows as a new
  resource to add.
