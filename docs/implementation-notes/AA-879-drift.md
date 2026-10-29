# AA-879 part B — scheduled Terraform drift check (S258)

Session S258 (29/10/2026), Claude Code lane "aa879-drift". Branch `chore/aa879-terraform-drift`. Refs AA-879. Evidence
that the job was missing: root `docs/audits/2026-10-29-S258-milestone-evidence/README.md`, section "Scheduled Terraform
drift job (not met)".

## Decisions

- **One new workflow, `terraform-drift.yml`, nightly at 05:37 UTC plus `workflow_dispatch`.** It plans the roots that
  `terraform-plan.yml` covers, which today is only `accounts/aa365` (key `dev/terraform.tfstate`). The roots are a
  matrix (`fail-fast: false`) so a second CI-planned root is one more entry. `accounts/acc3-bedrock` is left out: it
  is another account, applied only by a human with MFA, and the plan role cannot read it.
- **Plan role, no IAM change.** `aa-cis-infra-tf-plan` already trusts `<infra sub prefix>:ref:refs/heads/main`
  (`cicd_split.tf`, `aws_iam_role.tf_plan`, added for docs-gen in AA-893). The job has no `environment`, so its sub
  is exactly that, and `if: github.ref == 'refs/heads/main'` keeps it on main. The repo-level secret `AWS_ROLE_ARN` is
  the plan role (the apply role lives in the `prod` environment's secret). A step copied from
  `crm-key-policy-diff.yml` fails the run if the assumed role is anything else.
- **`-lock=false`, not `-lock-timeout`.** A plan never writes state. With the default lock the job would hold
  `dev/terraform.tfstate.tflock` for the whole refresh (PR plans take 1–2 minutes), and an apply or PR plan starting
  in that window fails at once with "Error acquiring the state lock" (lessons log, Vận hành: two CI plans/applies
  racing the S3 lock). `-lock-timeout` would only make *this* job wait, not the apply. The price: a run that overlaps
  an apply may read a half-written state and report false drift; rerun after the apply. The PR plan keeps its lock
  (unchanged), so the plan role's `StateLockfile` grant stays.
- **`-json` instead of a plan file.** `terraform plan -detailed-exitcode -json` streams one message per line
  (`resource_drift`, `planned_change`, `outputs`, `diagnostic`, `change_summary`). Those messages carry addresses
  and actions, never attribute values, and no `.tfplan` (which would hold secret values) is written at all, so
  there is nothing to upload or leak. The log goes to `RUNNER_TEMP` with `umask 077` and is removed by a `trap`.
- **Report in Python, stdlib only** (`tools/terraform/drift_report.py`), like the other tools here; no
  `setup-python`, no `pip install` next to the credentials. Exit 0 = in sync, exit 2 = red with the tables, exit 1 =
  red with the errors (summary + detail cut at 400 characters; snippets with expression values are never shown).
  Everything written goes through `tools/docs/aws_mask.py` and the script fails closed if `find_leaks` still sees an
  account id, ARN or EC2 id (public repo, public run logs; AccessDenied texts carry ARNs).
- **Exit 2 counts both kinds of difference.** Drift (changed outside Terraform) and "merged but never applied" both
  make `main` and the account differ; both turn the run red. The summary separates them ("Changed outside
  Terraform" vs "An apply of main would"), so the reader knows which fix applies.
- **Nightly, not weekly.** The S258 evidence page proposed weekly because one plan makes about 10k CloudTrail
  management events (S255 FinOps audit), which costs money only under GuardDuty (~4.40 USD per million: ~1.3 USD a
  month nightly, ~0.2 weekly). GuardDuty is on hold (S257), the trail's first copy of management events is free, so
  nightly costs $0 today. The workflow header says to make it weekly if GuardDuty is switched on.

## Changed

- New: `.github/workflows/terraform-drift.yml`, `tools/terraform/drift_report.py`,
  `tools/terraform/tests/test_drift_report.py`.
- `tf-plan-guard-test.yml` now also triggers on `terraform-drift.yml`, `terraform-plan.yml` and
  `tools/docs/aws_mask.py` (the new tests read the two workflows and import the mask).
- `CONTEXT.md`: new "Scheduled drift check (AA-879)" subsection under "How a change gets applied"; the role-split
  bullet lists the main-branch users of the plan role.
- Not changed: IAM, Terraform, `terraform-plan.yml` (the brief asked to reuse its setup; the PR plan still has no
  `-detailed-exitcode`, which is fine for a PR: changes are the point there).

## Tradeoffs

- `terraform validate` is not a separate step: plan validates the configuration anyway, and `main` already passed
  the PR plan.
- `init -lockfile=readonly` (as in docs-gen / crm diff): a provider lock change can only come through a PR.
- The workflow is red for "merged, not applied". That is intended (M1b wants `main` = account), but it means a PR
  merged late in the day without an apply gives a red nightly run. The answer is to apply, not to silence the job.

## Should know

- Shape test `test_drift_covers_every_root_the_pr_plan_covers` parses `terraform-plan.yml` (working directory +
  backend `key=`) and asserts the drift matrix is the same set. Add a root to both or the test goes red.
- First live proof (part B of M1b): after merge, one `workflow_dispatch` of "Terraform Drift" on main must end green.
  If it is red with exit 2, read the tables: the account may genuinely differ from `main` today.
- Tests (offline): `python3 -m pytest -p no:cacheprovider -q tools/terraform/tests` (216 passed with
  `tools/docs/tests`, locally on the CIS venv's pytest).
