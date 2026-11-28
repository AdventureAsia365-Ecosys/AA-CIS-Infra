# AA-1110: a Slack chat alert channel through Amazon Q Developer in chat applications (lane l8 of S297)

Scope item 4 of AA-1110 ("a second alert channel"), the chat part. The e-mail fallback
(`var.alert_email_secondary`, lane l3 of S283, `AA-1110-l3-second-alert-channel.md`) is unchanged and stays the
fallback. The person-facing steps live in the root repo (`docs/ops/runbooks/chat-alert-channel.md`).

## Decisions

- **Amazon Q Developer in chat applications** (formerly AWS Chatbot, Terraform `aws_chatbot_slack_channel_configuration`)
  posting one alerts topic into one Slack channel. Free (AWS docs, "Amazon Q Developer in chat applications rename -
  Summary of changes", Pricing: notifications and commands at no additional cost; SNS HTTPS deliveries inside the
  100,000 free a month). Slack because the plan names "a free Slack/Teams channel"; Teams has the same resource shape
  (`aws_chatbot_teams_channel_configuration`) if the business owner prefers it later.
- **Two-step gate.** `var.chat_alerts_enabled` (bool, default false) in `terraform.tfvars` by a reviewed PR, plus the
  workspace and channel IDs from the repo secrets `CHAT_ALERTS_SLACK_TEAM_ID` / `CHAT_ALERTS_SLACK_CHANNEL_ID` (the
  `ALERT_EMAIL_SECONDARY` pattern: repo-level secrets so the PR plan and drift jobs see them). The IDs are not
  credentials, but this repo is public and the ecosystem keeps workspace identifiers out of it. Validations refuse a
  switch that is on while an ID is empty or malformed, so a half setup fails at plan.
- **Notification-only role + read-only guardrail.** Role `aa-ecosys-dev-chat-alerts` trusts `chatbot.amazonaws.com`,
  carries the workload boundary (required for every role the apply role creates) and reads CloudWatch only (the
  console template "Notification permissions"). Guardrail `CloudWatchReadOnlyAccess`, set explicitly (never the service
  default), caps what a channel member can run; no `AmazonQDeveloperAccess`, so no Amazon Q chat in the channel.
  `user_authorization_required = false` (one channel role).
- **Region us-west-2** through the existing `aws.us_west_2` provider: the chatbot API runs only in us-east-2, us-west-2,
  ap-southeast-1 and eu-west-1 (AWS CLI reference "chatbot").
- **Topic choice** `var.chat_alerts_topic`: `all` (alerts topic, default, as the lane asked) or `page`.
- **Logging NONE**: the service would create a log group in us-east-1 without retention (the repo rule is a set
  retention on every log group). Switch to `ERROR` in a PR while troubleshooting.
- **Apply role grants in `aa-cis-infra-tf-apply-sec`** (customer managed, bootstrap): `ChatAlertsConfigCreate`
  (create, describe, list tags: no resource type) and `ChatAlertsConfigManage` (update, delete, tag, untag on
  `chat-configuration/slack-channel/aa-ecosys-*`). Rendered size 4,873 of 6,144 characters (offline render,
  28/11/2026). PassRole is already in `IAMRoleManageStack`. No Slack OAuth verbs: authorising a workspace is a console
  step of a person.

## Changed

- New `accounts/aa365/chat_alerts.tf`; `accounts/aa365/variables.tf` (four variables); `accounts/aa365/cicd_sec.tf`
  (two statements + header bootstrap note); the three Terraform workflows (two `TF_VAR_` lines each);
  `tools/terraform/iam_trust_allowlist.json` (service `chatbot.amazonaws.com`); test
  `tools/terraform/tests/test_aa1110_chat_alert_channel.py`.

## Tradeoffs

- **Not every alert renders in Slack.** Q Developer renders the AWS notifications it supports (CloudWatch alarms,
  Budgets, Cost Anomaly Detection, raw EventBridge events) and drops other text. The alerts topic also carries plain
  text (CIS in-app checks, EventBridge rules with an input transformer that writes an e-mail sentence). Those reach
  e-mail only. Rewriting them as Q Developer custom notifications is possible later (a follow-up, not this slice).
- A Slack workspace is a third-party account; its owner must be the company (business owner), not a personal one.
- The SNS subscription the service creates is not in Terraform state. The CIS admin page only lists e-mail
  subscriptions (AA-CIS-App `shared/alert_recipients.py` filters `Protocol == "email"`), so it never removes it.

## Should know

- Default plan: no change in AWS (`count = 0` everywhere). The only AWS change of this PR after merge is the managed
  policy update, applied locally: `terraform plan` / `apply -target=aws_iam_policy.tf_apply_sec` (MFA admin).
- Turning it on: root runbook `docs/ops/runbooks/chat-alert-channel.md` (console authorisation, two secrets, flip PR,
  Terraform Apply Dev, test alarm). Expected apply after the flip: 3 to add (role, role policy, configuration).
- A local plan needs `TF_VAR_chat_alerts_slack_team_id` / `_channel_id` exported once the switch is on.
- The plan role reads the configuration through the AWS managed ReadOnlyAccess; check that the first PR plan after
  the flip refreshes it without AccessDenied.
