# AA-1023 — rename of the Dev apply environment `prod` -> `dev` (lane l4 of S265)

The issue's last bullet, left out of the S264 PRs (see `AA-1023.md`): the AA-CIS-Infra workflows that assume the Dev
apply role `aa-cis-infra-tf-apply` ran in a GitHub environment named `prod`, although Dev is the only environment.
Root ADR 0012 decision 6 gives the order. Three PRs, expand / contract:

| PR | Branch | What | Applied by |
|---|---|---|---|
| 1 | `chore/aa-1023-oidc-trust-dev-env` | the apply role trusts `environment:prod` **and** `environment:dev` | local MFA apply (bootstrap) |
| 2 | `chore/aa-1023-workflows-env-dev` | every workflow job on that role moves to `environment: dev`; the workflow "Terraform Apply Prod" becomes "Terraform Apply Dev" | merge (no apply) |
| 3 | `chore/aa-1023-oidc-trust-drop-prod` | `environment:prod` leaves the trust | local MFA apply, after one green run of each workflow on `dev` |

Between 1 and 2 the GitHub environment `dev` gets the `prod` environment's content (live 03/11/2026: one secret,
`AWS_ROLE_ARN`; no environment variables, no protection rule, no branch policy). The `dev` environment already
existed in AA-CIS-Infra, empty and unused by any workflow.

## Decisions

- **One invariant test instead of a test per step** (`tools/terraform/tests/test_aa1023_env_rename.py`): the trust
  names only `prod` / `dev`, always includes `dev`, and every environment an apply-role workflow job uses is trusted.
  It is green after each of the three PRs in merge order and red if PR 3 lands before PR 2 (checked by deleting the
  `prod` subject on the PR 1 branch: 1 failed). `tf-plan-guard-test.yml` now also runs on `accounts/aa365/cicd_split.tf`.
- **PR 2 has its own test file** (`test_aa1023_env_dev_workflows.py`: no job in `prod`, the six workflows in `dev`,
  the isolation probe's reusable input defaults to `dev`, the workflow name) so PR 2 does not edit a file PR 1 adds
  (independent branches from `origin/main`, no stacking).
- **`cicd_split.tf` comments and the role description change only in PR 3.** PR 2 does not touch the file PR 1 and
  PR 3 change; the role `description` is part of the bootstrap role, so it changes in the PR that is applied locally.
- **The concurrency group `terraform-apply-prod` keeps its name.** It only serialises applies; renaming it while a
  run is queued would allow two applies at once for one run. Cosmetic, left as is.
- **Same protection as `prod`**, as the lane asked: no reviewer, no branch rule (GitHub Free private-repo limits,
  root ADR 0014). Main-only stays enforced by the IAM `ref` condition and each job's `if`.

## Changed (vs. the issue text)

- The issue named three workflows; there are six with `environment: prod` on `main` (db-freshness-probe,
  db-isolation-probe, db-migrate, db-schema-dump, db-tour-liveness-gate, terraform-apply with 2 jobs). All move.
- The workflow display name changes too (ADR 0012 decision 6 step 2); the file name `terraform-apply.yml` does not,
  so `gh workflow run terraform-apply.yml` keeps working. The root repo docs that name "Terraform Apply Prod" are
  updated in the root PR of the same lane.

## Tradeoffs

- Both subjects trusted for a short window: the same role, the same ref condition; no new principal can assume it.
- Step 3 needs a second local MFA apply. It can be done in the same MFA window once each workflow has one green run
  on `dev` (the runs take minutes), or in a later session.

## Should know

- The environment secret `AWS_ROLE_ARN` (an ARN, not a credential) overrides the repo-level `AWS_ROLE_ARN` (the plan
  role). If `dev` lacks it, a job falls back to the plan role, whose trust does not accept `environment:dev`: the
  OIDC step fails closed (no wrong-role access).
- Setting an environment secret needs a GitHub token with environment secrets write: the tech lead's `gh` login if
  the aa-agent app lacks that permission.
- After PR 3: delete the `prod` environment's `AWS_ROLE_ARN` (ADR 0012 step 3). A future prod apply role (step 4)
  recreates `prod` with its own secret and branch rule.
