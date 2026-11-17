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

## Changed

- `accounts/aa365/observability.tf` (new resource), `accounts/aa365/variables.tf` (new variable),
  `accounts/aa365/alert_recipients.tf` (Deny statement resources), test
  `tools/terraform/tests/test_aa1110_second_alert_channel.py`.

## Tradeoffs

- The CIS admin page lists the second address as one it does not manage (its reconcile only unsubscribes addresses an
  admin removed on the page) and does not show it locked. Showing it locked would need a second bootstrap env on the
  app: not worth it for one address that the Deny statement already protects.
- The recipient is a Terraform input, not an admin setting: it is a destination, not a threshold, and the bootstrap
  works the same way.

## Should know

- Plan with the default: `0 to add, 0 to change, 0 to destroy`.
- To switch it on: add `alert_email_secondary = "<role inbox>"` to `accounts/aa365/terraform.tfvars` in a PR, plan
  (expect 1 to add + the CIS task role inline policy updated in place), apply with the Terraform Apply workflow, and
  have the recipient click the AWS confirmation e-mail. Then send a test alarm (`aws cloudwatch set-alarm-state`) and
  check both inboxes.
- Cost: 0 USD (SNS e-mail inside the 1,000 notifications/month free tier).
