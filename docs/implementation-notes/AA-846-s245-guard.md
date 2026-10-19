# AA-846 (S245) part A: plan guard in front of the CI Terraform apply

One of three AA-846 branches in S245. Each branch keeps its own notes file (`-guard`, `-drift`,
`-iam`) so parallel PRs do not conflict on one notes file (lessons log, S242).

## Decisions

- **Guard logic in `tools/terraform/plan_guard.py`** (stdlib only), next to the other repo tools
  (`tools/secrets`, `tools/identity`) rather than a new `scripts/` dir. It reads the JSON of the saved
  plan and refuses (exit 1) when a `resource_changes` entry of type `aws_secretsmanager_secret_version`,
  `random_password` or `aws_db_instance` has actions other than `["no-op"]` / `["read"]`. Matching is
  on `type`, so `module.rds.aws_db_instance.main` is covered.
- **Also refused:** `forget` (a `removed` block) and an import of a guarded type (even when the
  action is `no-op`). Both change what Terraform owns; AA-878 I2 used `removed` for the Mapbox/ACP
  secrets, and such a change should be dispatched on purpose with a reason.
- **Fail closed:** missing file, invalid JSON (e.g. the setup-terraform wrapper's `[command]` line),
  or a JSON that is not a plan (no `format_version`, a state instead of a plan, malformed
  `resource_changes`) exits 2 and blocks the apply.
- **Never prints values:** the report lists address, type and action only. `terraform show -json`
  puts sensitive values in clear text, so the workflow writes it to `RUNNER_TEMP` with `umask 077`,
  never prints or uploads it, and deletes it right after the guard.
- **`terraform-bin show -json`:** the setup-terraform wrapper stays on (the plan step reads its
  `exitcode` output), and the wrapper writes a `[command]...` line to stdout. `terraform-bin` is the
  real binary the wrapper installs next to it; if it is missing the step fails (no apply).
- **Dispatch inputs:** `allow_guarded` (boolean, default false) + `allow_reason` (string; required
  and non-blank with `allow_guarded`, checked before any AWS step). The reason is passed via env,
  never interpolated into the script (no script injection), and is written to the job summary with
  the list of guarded changes.
- **`guard_selftest`:** runs the same "Plan guard" step on the committed fixture
  `tools/terraform/tests/fixtures/plan_guarded.json`; every AWS / Terraform step is skipped, and
  `allow_guarded` is ignored. Expected result: a red run at "Plan guard" with `REFUSED` (that run is
  the Done-when "rejects a test plan" link). If the guard ever accepted the fixture, a final
  "Self-test result" step fails with `SELF-TEST FAILED`, so a broken guard is red at a different,
  named step and never reaches the apply. The job-level `main` only condition still applies.
- **"Check plan exit code"** now fails on an unexpected exit code (it used to fall through silently).

## Changed

- `.github/workflows/terraform-apply.yml`: three `workflow_dispatch` inputs, input check, self-test
  plan selection, "Export plan JSON", "Plan guard", "Self-test result"; the AWS/Terraform steps and
  the apply are skipped in self-test mode.
- New `tools/terraform/plan_guard.py`, `tools/terraform/tests/test_plan_guard.py`, three synthetic
  fixtures (`plan_guarded`, `plan_clean`, `plan_noop`; placeholder addresses, no IDs or ARNs).
- New `.github/workflows/tf-plan-guard-test.yml` (pull_request + push on main, path filtered):
  pytest, plus the guarded fixture through the CLI must exit 1.
- `CONTEXT.md`: plan guard paragraph under "How a change gets applied".

## Tradeoffs

- The self-test is a red run by design (the guard refusing is the proof). A green "expected refusal"
  job would be friendlier but would not show the real step refusing.
- Guarding by type, not address: a future second RDS instance or a new `random_password` is guarded
  automatically. The price is that a deliberate rotation needs the dispatch inputs every time.
- Local admin applies are not guarded (bootstrap objects are applied that way). The CONTEXT.md text
  says so.

## Should know

- Tests: `python3 -m pytest -p no:cacheprovider -q tools/terraform/tests` (44 passed locally, needs
  pytest + PyYAML); ruff clean; actionlint clean on both workflows.
- Checked against a real full-root plan of the S245 drift branch (read-only, local): the plan holds
  `aws_db_instance`, `aws_secretsmanager_secret_version` and `random_password` entries, all `no-op`,
  and the guard returns `OK` (exit 0). The JSON was deleted afterwards.
- The test workflow also triggers on changes to `terraform-apply.yml`: the wiring tests assert the
  guard runs before the apply and that the apply is skipped in self-test mode.
- After merge: dispatch once with `guard_selftest=true` (expect red at "Plan guard") and once
  normally (expect "Plan guard: OK" or no changes) for the issue evidence.
