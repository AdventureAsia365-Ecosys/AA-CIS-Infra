# AA-1096 (lane l10): billing-only spend ALERT on acc1 (Infra side)

Lane l10 of S279. Tech lead decision S279 (13/11/2026): acc1 Bedrock spend is **alert only**, never stopped: warnings
on the CIS gateway connection `acc1` (monthly budget 100 USD, alert 80 %, hard stop off, already switched) plus a free
AWS Budget with alert e-mails only. Root ADR 0001a, Note S279 records the billing-only exception on acc1.

## Decisions

- **New file `accounts/acc1-bedrock/cost_guard.tf`, 3 resources**: `aws_budgets_budget.acc1_monthly`
  (`aa1-llm-monthly-total`), `aws_ce_anomaly_monitor.acc1_spend` (`aa1-spend`) and
  `aws_ce_anomaly_subscription.acc1_daily` (`aa1-cost-anomaly-daily`). Names follow acc3's `aa3-` pattern.
- **Budget scoped to acc1's own usage** (`cost_filter LinkedAccount = var.account_id`). Since S277 acc1 is the payer
  of acc3's organization: an unfiltered budget on acc1 would also count acc3's Bedrock bill (about 250 USD a month)
  and send the 100 % mail in the first days of every month. Gross cost (credits and refunds excluded), as acc3 and the
  management root do.
- **Notifications**: ACTUAL at `var.budget_alert_actual_percents` (default 50, 80, 100) and FORECASTED at
  `var.budget_alert_forecast_percent` (default 100), built with one `dynamic "notification"` like
  `accounts/management/budgets.tf`. No budget action, no IAM for an action.
- **Anomaly monitor CUSTOM on LINKED_ACCOUNT, not DIMENSIONAL SERVICE** (the brief said DIMENSIONAL SERVICE): AWS
  allows one services monitor per account, and an AWS-created `Default-Services-Monitor` may already exist on acc1
  (acc3 had one, so acc3 references it); creating a second one fails at apply. A services monitor in a payer account
  would also watch acc3's spend. The management root uses the same CUSTOM LINKED_ACCOUNT shape for the same two
  reasons, with every expression key spelled out (a shorter document shows a permanent diff).
- **Subscription DAILY, direct e-mail, threshold `ANOMALY_TOTAL_IMPACT_ABSOLUTE >= var.anomaly_alert_usd`** (default
  10 USD, acc3's daily value). IMMEDIATE needs an SNS topic + policy on acc1: more resources on a personal account for
  little gain on an alert-only guard. So no SNS topic and no confirmation mail (direct Budgets / Cost Anomaly e-mail
  needs none).
- **Recipient**: `var.cost_alert_email`, required (no default), from the untracked `terraform.tfvars` like
  `account_id` and `aws_profile` (the brief: never committed). acc3 commits its address as a default; acc1 does not.
- **Tags**: provider `default_tags` (Component `llm`, Issue AA-1095) overridden per resource with
  `Component = "billing"`, `Issue = "AA-1096"` (tagging standard: `billing` = budgets, anomaly monitors; acc3 does the
  same).
- **Output `cost_guard`**: the effective values (budget, percentages, anomaly threshold, frequency, `hard_stop =
  false`) for lane L6's read-only Infra view of budget values.

## Changed

- `accounts/acc1-bedrock/versions.tf` header: the root now also holds the alert-only guard; the bootstrap commands
  add `cost_alert_email` to the untracked tfvars.
- `CONTEXT.md` (account table, acc1 paragraph, spend-guard paragraph, layout line) and `README.md` (acc1 row).
- `.github/workflows/tf-plan-guard-test.yml`: `accounts/acc1-bedrock/cost_guard.tf` triggers the guard tests.
- New static test `tools/terraform/tests/test_aa1096_acc1_cost_guard.py`: the root holds exactly the invoker role, its
  policy and the three billing resources; no action / SNS / IAM in the guard; LinkedAccount filter; gross cost;
  variables with the S279 defaults; recipient variable without default and no literal address; CUSTOM
  LINKED_ACCOUNT monitor; DAILY e-mail on the absolute impact; `billing` tags. `test_aa1095_acc1_no_id.py` already
  covers the new file (no 12-digit ID, no literal profile).

## Tradeoffs

- **Thresholds stay Terraform variables, not admin settings.** AWS Budgets is one of the exceptions that stay in
  Terraform (AA-1096 scope, S279 thresholds audit section 4). The values reach the admin page read-only through the
  `cost_guard` output once lane L6 builds the Infra view (follow-up, not this lane).
- **LINKED_ACCOUNT monitor needs acc1 to stay a management account.** If acc1's organization is closed (acc3 moving to
  the AA organization), switch the monitor to DIMENSIONAL SERVICE, or reference the AWS-created services monitor as
  acc3 does, in the same change.
- **DAILY instead of IMMEDIATE anomaly alerts**: up to ~24 h late, accepted for an alert-only guard on a 100 USD
  budget; the gateway's own 80 % warning on the `acc1` connection is the faster signal.

## Should know

- Applied by a human, locally, from the **main Infra checkout** after merge (hook TF-1 refuses an apply from a
  worktree; the `.terraform` dir and the untracked `terraform.tfvars` live there). Add `cost_alert_email` to that
  tfvars first, or the plan stops on a missing variable.
- Expected plan: `3 to add, 0 to change, 0 to destroy` (budget, monitor, subscription; the role and its policy
  unchanged). Pre-condition: Cost Explorer enabled on acc1 (it is: S277 read acc1's Cost Explorer).
- Cost: 0 USD a month (budgets without actions, Cost Anomaly Detection and AWS e-mails are free).
- Verified locally: `terraform fmt -check`, `terraform validate`, and a throwaway `terraform test` with a mocked
  provider (plan: 4 notifications, limit "100", monitor scoped to the given account, `hard_stop = false`; a bad
  e-mail fails validation). Not a real plan: no AWS access from the lane.
