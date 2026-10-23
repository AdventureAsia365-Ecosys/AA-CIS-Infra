# AA-896 (S248) — spend guards on acc3 (budget + anomaly e-mail)

Session S248 (23/10/2026), Claude Code lane `aa896-finops`. Branch `feat/aa896-cost-anomaly-detection`.

## Decisions

- **acc2 needed nothing new.** Cost Anomaly Detection on acc2 is live since 19/10/2026: Terraform Apply Prod
  run 39199328963 (merge of #213) imported `Default-Services-Monitor` and created
  `aws_ce_anomaly_subscription.alerts_sns` (IMMEDIATE, impact >= 5 USD, alerts topic). Checked from the run log;
  a live `aws ce get-anomaly-subscriptions` on acc2 was not possible in this lane (MFA session expired).
- **acc3 was the gap.** Read live 23/10 with `nghiep_aa365`: no budget at all, and only the AWS-created
  `Default-Services-Subscription` (DAILY e-mail, impact >= 100 USD AND >= 40 %). acc3 spent 51 USD in September
  and about 139 USD from 01/10 to 22/10, almost all Bedrock. So `accounts/acc3-bedrock/cost_guard.tf` adds:
  - `aws_budgets_budget.acc3_monthly`: 250 USD/month (= the AWS Lift tier 1 credit; October runs at about
    190 USD/month), e-mail at 80 % and 100 % actual and 100 % forecast;
  - `aws_ce_anomaly_subscription.acc3_daily`: DAILY e-mail for anomalies with impact >= 10 USD on the existing
    services monitor.
- **Credits excluded from the budget** (`include_credit = false`, `include_refund = false`): the Lift credit hides
  real usage and runs out; the budget must follow gross usage. Cost Explorer showed no Credit records on acc3 for
  Aug–Oct, so today gross = net.
- **The monitor is referenced, not imported.** An account holds one AWS services monitor; acc2 imports it only to
  tag it. Here a reference by ARN (account from `aws_caller_identity`, UUID in a variable) keeps the plan to two
  adds and never touches the AWS-created monitor or its default subscription.
- **E-mail, not the acc2 alerts topic.** IMMEDIATE accepts only SNS. A cross-account SNS subscriber needs a topic
  policy change on acc2 (budgets/costalerts service principals with `aws:SourceAccount` = acc3), a second PR for
  little gain at this volume. The recipient is the same bootstrap inbox as acc2 (`var.alert_email` there). The
  AA-913 admin-page recipient list therefore does not cover acc3 alerts.
- **acc1 unchanged.** It has two hand-made budgets (`AAA-Monthly-Total` 180 USD, `aa-practice-monthly` 150 USD) and
  spends cents a month since September.

## Changed

- `accounts/acc3-bedrock/cost_guard.tf` (new), `CONTEXT.md` (acc3 root description + spend guards bullet).

## Tradeoffs

- Threshold 10 USD on a DAILY summary: acc3 had single days of 20–34 USD in October (waves); the model learns per
  service, so the first weeks may e-mail on wave days. Raise `acc3_anomaly_alert_usd` rather than removing it.
- The budget limit is a variable; change it in a PR, not in the console.

## Should know

- This root is applied locally with MFA (`nghiep_aa365`), not by CI. Plan read in the lane (TF_DATA_DIR in a
  scratch dir, provider 6.69.1 from the aa365 cache): **2 to add, 0 to change, 0 to destroy**.
- Cost: 0 USD/month (Budgets without actions are free, Cost Anomaly Detection is free).
- Budget e-mails to an address need no confirmation; anomaly e-mail subscribers neither (the existing default
  subscription shows the same address as CONFIRMED).
