# AA-858 — Infra data PR: bk-017 / tp-015 copies, contract grants, keyed probe cells

Session S243 (19/10/2026), builder lane AA-858 step S3. Branch `chore/aa858-copy-bk017-tp015`. The IAM part
(CloudWatch read for the CIS task role) is a separate PR with its own notes file (`AA-858-infra-iam.md`).

## What this PR carries

- `db/migrations/booking/017_ops_overview_views.sql` — byte copy of AA-Booking `migrations/017_ops_overview_views.sql`
  (views `booking.v_ops_funnel_daily`, `booking.v_ops_case_status`, SELECT + schema USAGE to `cis_app`).
- `db/migrations/tripplanner/015_ops_overview_view.sql` — byte copy of AA-TripPlanner-Web
  `migrations/015_ops_overview_view.sql` (view `tripplanner.v_ops_traffic_daily`, SELECT + schema USAGE to `cis_app`).
- `db/owners.yaml`: three `consumer_grants` rows (`cis_app`, `USAGE, SELECT`, one per view, status `contract`), each
  with the new optional field `expected_from` (`bk-017` / `tp-015`).
- `db/isolation_probe.py`: `CONSUMER_GRANTS` gains a fourth field (the `expected_from` key); keyed grants get their own
  cell `consumer.contract_grants.<key>`; the consumer facts check that the object exists first.

## Decisions

- **Keyed probe cells, not the existing always-expected cell.** `consumer.contract_grants` has no state key: had the
  three grants been added to it, the nightly probe (04:13 UTC) would go red between this merge and the DB Migrate
  apply — worse, `has_table_privilege` on a missing view raises, so the whole consumer savepoint would error. Now:
  - a keyed grant is checked only in `consumer.contract_grants.bk-017` / `.tp-015`, `when = (key,)`: `pending` while
    the key is not registered (`ready` if it already holds), expected (pass/FAIL) once registered;
  - `bk-017` and `tp-015` join `VERSION_KEYS` (derived: `CONSUMER_GRANT_KEYS`), so the probe reads them from
    `shared.schema_versions` like the X1 keys; `KEY_TEXT` names them;
  - every grant (keyed or not) first checks `to_regclass` / `to_regprocedure`; an absent object is reported as
    `missing: ["absent"]` instead of an exception. For the unkeyed grants that is the same FAIL as before, but the
    other grants are still evaluated.
- **One registry row per view**: `test_isolation_probe_constants` mirrors only single-object rows into the probe.
- **`expected_from` must be the owner's own key** (`bk-` under `booking`, `tp-` under `tripplanner`) and appear in
  `source`; only `contract` rows may carry it (`test_consumer_grants_name_other_owners_runtime_roles`).
- **Cross-app cells unchanged.** `cis_app` / CIS runtime → `booking.customers` and → `tripplanner.sessions` stay
  42501: USAGE on the schema plus SELECT on two views does not reach any table (each owner's integration test checks
  it through `SET ROLE cis_app`). `runtime_grants.booking` / `.tripplanner` stay green: the runtime roles keep SELECT
  on the new views (default privileges FOR ROLE `bk_owner` / `tp_owner`; the files revoke only the writes).
  `ownership.*`: the views are created by the live owner (DB Migrate's SET ROLE), so they are owned by `bk_owner` /
  `tp_owner`.
- **No grant to `aa_cis_admin`.** The CIS runtime logs in as `aa_cis_admin` until X1 S18 and reads the views through
  its `bk_owner` / `tp_owner` membership (rl-001); from S18 the CIS runtime is `cis_app` and the grants apply.

## Changed (vs. the plan)

- Plan numbers bk-016 → **bk-017** (bk-016 is AA-680), tp-015 kept.
- Plan's single registry row "booking.v_ops_funnel_daily, booking.v_ops_case_status" → two rows (probe mirror needs
  single objects), plus `expected_from`.
- Probe change added (the plan assumed the existing cell would stay green; it would not before the apply).

## Tradeoffs

- A fourth tuple field touches every consumer grant line, but keeps one source list; a separate "pending grants" list
  would let a grant sit in two places.

## Should know (main session)

- **Merge order**: AA-Booking bk-017 PR and AA-TripPlanner-Web tp-015 PR (Nghiệp merges TripPlanner) first; this copy
  PR's Copy Guard compares with the owners' `main` and fails until both are merged. Rebuild the copies from the merged
  files then (`cmp` each), e.g. if a review changed them.
- **Apply order on Dev**: `booking/016_staff_cognito_identity.sql` (AA-680) **before** `booking/017_ops_overview_views.sql`;
  `tripplanner/015_ops_overview_view.sql` any time after merge. The runner does not enforce numeric order, so apply
  016 first by hand. Then dispatch `db-isolation-probe` (expect `consumer.contract_grants.bk-017` / `.tp-015` = pass,
  cross-app cells unchanged) and `db-schema-dump` (root PR regenerating `docs/architecture/db-schema-reference.md`).
- **Possible conflict**: the AA-680 lane may add its own `consumer_grants` row / probe entry (critic finding: Booking
  reading CIS staff identity). Both edit `CONSUMER_GRANTS` and `owners.yaml`; resolve by keeping both rows (4-tuple
  form, `""` or its own key).
- Local checks (S243): `python3 -m unittest discover -s db/tests` → 223 tests OK (4 new/changed probe tests,
  registry tests updated); `db/check_migration_files.py` → 55 files, 0 problems; `run_migration.py --inspect` on both
  copies → no errors/warnings; `check_migration_copies.py` → FAIL "not found on main" for both (expected before the
  owner merges). `cmp` with the owner branch files: identical.
- No AWS resource, no Terraform change, no new env var or secret, no cost.
