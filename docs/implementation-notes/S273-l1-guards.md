# S273 fix: two red scheduled guards (Contract Copy Guard, Terraform Drift accounts/management)

Lane l1-guards of S273. Two of the three red scheduled guards at the session start are in this repo.

## Decisions

### Contract Copy Guard (nightly run 42466793306: 5 ok, 3 warnings, 3 failures)

- **Failures (3).** `tools/contracts/contract_copies.json` still registered AA-Booking's copies
  `backend/app/contracts/inquiry.submitted.v1.json`, `v1.1.json`, `v1.2.json`. The Booking B2C drop (AA-Booking #199)
  removed its inquiry intake and those copies, but nobody removed the manifest entries in the same change. The three
  Booking entries are removed. AA-Booking stays in `consumer_repos`, so the discovery scan still catches any new copy
  there (Booking produces `supply.*.v1`).
- **Canonical pins.** A local run with `--canonical-dir` (the root repo's `docs/contracts/`) failed on six canonical
  files nobody had pinned: `catalog.country.v1`, `catalog.tour.v1.3`, `inquiry.submitted.v1.3`, `inquiry.submitted.v1.4`,
  `supply.hotel.v1`, `supply.service.v1`. CI cannot see this (the root repo is not read by CI); the unit test
  `test_committed_pins_match_the_workspace_canonical_files` fails in the workspace. All six are pinned now with the
  sha256 of the canonical file (no copy for four of them).
- **Warnings (3), explained.** Before: TripPlanner's `backend/tests/contracts/inquiry.submitted.v1.3.json` and
  `v1.4.json` (byte copies of the canonical files, not pinned) and `lead.submitted.v1.json`. The two inquiry copies
  match the canonical files byte for byte, so they are registered now (TripPlanner's `test_handoff_contract.py`
  validates its payload against v1.4). One warning stays on purpose: TripPlanner's `lead.submitted.v1.json` is not a
  copy, it is generated from the canonical OpenAPI file `lead.submitted.v1.openapi.yaml` (its `$comment` says so), so
  there is no canonical JSON file to pin. A warning is what the guard is designed to say for such a file.
- **AA-Partner** joins `consumer_repos` (discovery only, no registered copy): it consumes `catalog.http.v1`,
  `crm.*` and `tenant.*` contracts and should be scanned like the other app repos.
- **The canonical contract** `inquiry.submitted` has no consumer any more. Per `docs/contracts` rule 2 a published
  file is never edited or deleted, so the root PR of this lane marks all five minors **retired** in the registry
  table; the pins stay while TripPlanner still keeps its test copies.

### Terraform Drift, job "Terraform drift (accounts/management)" (red since the 06/11 schedule run)

- **Not a plan error.** Init, OIDC into the management plan role and the role check pass; `terraform plan` ends with
  exit 2 (changes), not 1. Provider pin, variables and the plan role's permissions work (the same job was green on
  05/11).
- **Cause: `main` holds a change that was never applied.** PR #703 (tagging standard, merged 06/11 06:08 UTC, before
  the first red run at 13:10 UTC) added provider `default_tags` to `accounts/management/versions.tf` and `tags` blocks
  to the budgets, the anomaly monitor and subscription and the `cicd.tf` bootstrap objects. Its PR body only planned
  aa365 and acc3-bedrock ("management: terraform validate OK (no credentials for a plan)"). No Terraform Apply run with
  `root = management` happened since (every dispatch since 06/11 skipped both management jobs). Result: 21 planned
  in-place updates. The 21 "changed outside Terraform" entries are the same resources, the refresh noise of the
  `tags` / `tags_all` attributes once the provider default tags changed; the plan text is not printed for this root,
  so the local plan before the apply has to confirm that every change is a tag change.
- **No code change for it here.** Fix = apply `main` to the management account. The re-tag touches `cicd.tf`
  bootstrap objects (OIDC provider, both roles, the boundary policy); the CI apply role's boundary denies those
  writes by design (README section 11), so it is a local apply with the tech lead's `aa-mgmt` Identity Center session
  (README section 4), not a CI apply.

## Changed

- `tools/contracts/contract_copies.json` only (manifest data); no change to the guard code or its tests.

## Tradeoffs

- Pinning the six unpinned canonical files makes the workspace run green. Leaving them out would keep the workspace
  unit test red and let a later in-place edit of those files go unnoticed.
- Registering TripPlanner's v1.3 / v1.4 copies makes a TripPlanner edit of them a red guard; that is the guard's
  purpose and they are the copies its contract test reads.

## Should know

- After the management apply, rerun Terraform Drift by hand: both matrix entries must say "In sync".
- When TripPlanner removes its leftover inquiry hand-off code and its `inquiry.submitted.*` test copies, the same
  change must drop their entries here (the guard fails on a registered copy that disappears).
- Review fix (S273): the retired `inquiry.submitted` contract leaves the tp-009 grants to `booking` (`USAGE` on schema
  `tripplanner`, `SELECT` on `tripplanner.v_inquiry_outbox`) without a reason; the view's `payload` carries traveller
  personal data. The root PR marks them "retired, revoke pending". The revoke is a follow-up chain: a TripPlanner `tp-`
  migration with the two REVOKEs, then here the `owners.yaml` consumer grant, the two `rls_catalogue_rules.py`
  allowlist rows and the `isolation_probe.py` `CONSUMER_GRANTS` row removed (the nightly probe would go red if the
  probe row stayed after the revoke). Not done in this PR: it is a TripPlanner-owned contract migration.
