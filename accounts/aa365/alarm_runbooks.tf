# =============================================================================
# AA-893 step 1 (S243) — runbook link in every CloudWatch alarm description.
#
# Each aws_cloudwatch_metric_alarm in this root (and module.eventbridge) ends its alarm_description with
# " Runbook: <url>". The alarm e-mail (SNS -> the topic's recipients: bootstrap + CIS admin page, AA-913) carries the description, so the first
# thing the reader sees is where the procedure lives. The pages are in the PRIVATE root repo
# (AA-Ecosys, docs/ops/, catalog OPS-01..OPS-11 in docs/README.md), written by AA-892; a link can point
# at a page that is still being written: the alarm text does not change when the page lands.
#
# Rules:
#   - One key per playbook/runbook. An alarm with no specific playbook uses `incident` (the SEV
#     ladder and first steps, docs/ops/incident-response.md).
#   - alarm_description max is 1024 characters (CloudWatch). The longest description plus link is
#     428 today (plan 19/10/2026); keep new ones short.
#   - Changing a URL here is an in-place update of the alarms (no replacement).
#   - The generated alarm catalog (AA-893: tools/docs/gen_docs.py, workflow docs-gen.yml, published
#     as root docs/generated/alarms.md) reads the link back from the description; keep the
#     " Runbook: " marker exactly, at the very end.
#   - EventBridge rules that notify an SNS topic (identity_alerts.tf) carry the same suffix in the rule
#     description (read by the generator) and in the target's input_template (the e-mail text).
#   - CI workflow docs-gen-test.yml (`gen_docs.py check-source accounts modules`) fails a PR that adds
#     an alarm or an SNS-notifying rule without a runbook suffix; the generator flags a link outside
#     root docs/ or to a file that does not exist there.
# =============================================================================

locals {
  runbook_base_url = "https://github.com/AdventureAsia365-Ecosys/AA-Ecosys/blob/master/docs/ops"

  runbook_url = {
    api_5xx        = "${local.runbook_base_url}/playbooks/5xx-spike.md"
    queue_stuck    = "${local.runbook_base_url}/playbooks/queue-stuck.md"
    llm_cost_spike = "${local.runbook_base_url}/playbooks/llm-cost-spike.md"
    cognito_login  = "${local.runbook_base_url}/playbooks/cognito-login.md"
    ses_bounce     = "${local.runbook_base_url}/runbooks/ses-bounce.md"
    restore_pitr   = "${local.runbook_base_url}/runbooks/restore-rds-pitr.md"
    database       = "${local.runbook_base_url}/database-operations.md"
    break_glass    = "${local.runbook_base_url}/runbooks/break-glass.md"
    incident       = "${local.runbook_base_url}/incident-response.md"
  }

  # Suffix appended to alarm_description, e.g. "${...}.${local.runbook_suffix.database}".
  runbook_suffix = { for k, v in local.runbook_url : k => " Runbook: ${v}" }
}
