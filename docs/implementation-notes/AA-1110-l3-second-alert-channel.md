# AA-1110: a second alert channel on the alerts topic (lane l3 of S283)

Scope item 4 of AA-1110 ("a second alert channel"), Infra side only. The other items (second key-holder access,
"run without the agent" page, drills, tabletop) live in the root repo.

## Decisions

- **A second Terraform-managed e-mail subscription** `aws_sns_topic_subscription.alerts_email_secondary` on the
  existing alerts topic, behind `var.alert_email_secondary`. `count = 0` while the variable is `""` (the default): the
  PR changes nothing in AWS until the tech lead sets a recipient. E-mail, because it is free and needs no new service;
  SMS or a chat webhook would cost money or a new integration (a later choice).
- **Terraform-managed, not added from the CIS admin page.** The admin page can already add recipients (AA-913), but
  those live in the app's table and depend on the app and the database. The point of a second channel is to survive
  the first inbox being unread or the app being down, so it is a Terraform input next to the bootstrap.
- **Protected like the bootstrap.** The CIS task role's `DenyUnsubscribeBootstrap` statement now names
  `concat([bootstrap], secondary[*])`: an empty list while unset, so the policy JSON is unchanged.
- **Validation**: empty or one address, and never the bootstrap address (case-insensitive).
- **The recipient comes from a repo secret, never a committed file** (review fix, S283). This repo is public and the
  second inbox receives every alarm, so committing it to `terraform.tfvars` would hand a spam / phishing target to
  anyone. The repo secret `ALERT_EMAIL_SECONDARY` maps to `TF_VAR_alert_email_secondary` in `terraform-plan.yml`,
  `terraform-apply.yml` and `terraform-drift.yml` (the `BEDROCK_ACCT_PAYER_ID` pattern). A **repo-level** secret, not
  an environment secret: the PR plan and the drift jobs run without an environment and would not see an environment
  secret, so their plans would show the subscription being destroyed. All three mappings are needed for the same
  reason. The variable is `sensitive = true` (plan output hides it on top of GitHub's secret masking); `count` reads
  `nonsensitive(var.alert_email_secondary == "")`, since Terraform refuses a sensitive value in `count`.

## Changed

- `accounts/aa365/observability.tf` (new resource), `accounts/aa365/variables.tf` (new variable),
  `accounts/aa365/alert_recipients.tf` (Deny statement resources), the three Terraform workflows
  (`TF_VAR_alert_email_secondary` from `secrets.ALERT_EMAIL_SECONDARY`), test
  `tools/terraform/tests/test_aa1110_second_alert_channel.py` (also holds the workflow wiring, the sensitivity and
  "no tracked tfvars sets it").
- Root repo (same lane): a **planned** row for `ALERT_EMAIL_SECONDARY` in `docs/security/secrets-register.{md,yaml}`.

## Tradeoffs

- The CIS admin page lists the second address as one it does not manage (its reconcile only unsubscribes addresses an
  admin removed on the page) and does not show it locked. Showing it locked would need a second bootstrap env on the
  app: not worth it for one address that the Deny statement already protects.
- The recipient is a Terraform input, not an admin setting: it is a destination, not a threshold, and the bootstrap
  works the same way.

## Should know

- Plan with the default: `0 to add, 0 to change, 0 to destroy`.
- To switch it on (no PR needed): set the repo secret `ALERT_EMAIL_SECONDARY` on AA-CIS-Infra to the role inbox
  (`gh secret set ALERT_EMAIL_SECONDARY -R AdventureAsia365-Ecosys/AA-CIS-Infra`, value on stdin), then dispatch
  Terraform Apply (root aa365): expect 1 to add (the subscription) + the CIS task role inline policy updated in place.
  The recipient clicks the AWS confirmation e-mail; then send a test alarm (`aws cloudwatch set-alarm-state`) and
  check both inboxes. Flip the register row to **keep**. Never write the address into `terraform.tfvars` (the test
  `test_not_set_in_any_tracked_tfvars` fails).
- To switch it off: delete the secret and apply (1 to destroy). Deleting the secret without an apply makes the next
  drift run report the subscription as drift (to destroy): the signal to apply or restore it.
- A local plan of `accounts/aa365` needs `TF_VAR_alert_email_secondary` exported once the secret is set, or it shows
  the subscription being destroyed (like the other `TF_VAR_` inputs).
- Cost: 0 USD (SNS e-mail inside the 1,000 notifications/month free tier).
