# AA-902 (Infra side): satellite account IDs as environment

The public app repos must not carry AWS account IDs (AA-902). CIS and TripPlanner still need the acc3/acc1
Bedrock satellite account IDs to build the invoker role, inference profile, batch and Cost Explorer ARNs.

## Decisions

- One place for the IDs: `locals.bedrock_acct_primary` (acc3) / `bedrock_acct_fallback` (acc1) in
  `accounts/aa365/bedrock_satellite_assume.tf` (this repo is private).
- Same env names everywhere, the ones TripPlanner already used: `BEDROCK_ACCT_PRIMARY` = acc3,
  `BEDROCK_ACCT_FALLBACK` = acc1.
  - CIS api + worker task definitions (new module variables, `local.bedrock_satellite_env`).
  - TripPlanner assembly Lambda (literals → the locals, same values) and **browse** Lambda (new: the
    browse embed path falls through acc3 → acc1 like assembly, AA-862).

## Changed

- `accounts/aa365/bedrock_satellite_assume.tf`, `accounts/aa365/tripplanner.tf`, `accounts/aa365/main.tf`,
  `modules/ecs/main.tf`, `modules/ecs/variables.tf`.

## Tradeoffs

- Env, not Secrets Manager: account IDs are identifiers, not secrets; env keeps them out of the public
  repos at zero cost and with no new IAM read.

## Should know

- Apply order: this apply registers new CIS task-definition revisions (services ignore `task_definition`,
  so nothing rolls); the next CIS Deploy Dev takes the env with the new image. Merge the CIS AA-902 PR
  (code reads the env) only after this apply. The browse Lambda updates in place.
- TripPlanner AA-902 (code reads the env with an empty default) merges after this apply and after the repo
  secret for the deploy role is set.
