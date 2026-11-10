# AA-1038 — TripPlanner tenant cells in the DB Isolation Probe (tp-028, FORCE slice)

Lane l1-tp-rls, S276. AA-TripPlanner-Web tp-028 makes the tenant row-level security of `tripplanner.sessions`,
`trip_drafts`, `trip_events` and `outbox` enforcing (FORCE, a strict `<table>_tenant` policy for `tripplanner`, a
`<table>_system` policy under the GUC `app.tenant_scope = 'system'` for the jobs Lambda, `<table>_owner_read` for the
owner views). This PR makes the nightly probe check it through the runtime role's own login.

## Decisions

- **Two cells, both expected from tp-028** (new state key `tp-028` in `VERSION_KEYS` / `KEY_TEXT`):
  - `tenant.tripplanner_isolation` (group tenant): the aa817 matrix of every RLS table of schema `tripplanner`
    through `tripplanner`'s own login (GUC unset / '' / forged / each tenant of `shared.tenants`), plus the four
    tables FORCE row-level security and all four matrixed. With no real tenant bound, every visible row counts as
    cross-tenant (matrix_count_sql with `$1` NULL), so "0 cross" means "no row".
  - `rls.tripplanner_system_scope` (group rls): the same login under `app.tenant_scope = 'system'` reads every row of
    the four (equal to one of the catalog login's reference counts taken before and after the logins, as
    `rls.force_parity.cis_app` does). A jobs path that lost its policy would leave the retention jobs silently empty.
- **Same matrix code as aa_app_user.** `tenant_matrix` is split into `_matrix(conn, tables, allowed, tenants)`;
  `tp_tenant_matrix` calls it with no shared constants (no TripPlanner row is shared between tenants). Any error on a
  TripPlanner table fails the cell (a 42501 on the runtime role's own table is a lost grant, not a skip as for the
  tenant pool).
- **Reference counts from the catalog login.** `db_migrator` is an INHERIT member of `tp_owner` (rl-002), so under
  FORCE it reads through `<table>_owner_read` with no tenant bound: every row (checked on a throwaway PostgreSQL
  with the tp-028 policies and a login granted `tp_owner`).
- **Matrix records** of the TripPlanner tables are emitted with `role: tripplanner`.

## Changed

- `db/isolation_probe.py`: `TP_RUNTIME`, `TP_SCHEMAS`, `TP_TENANT_TABLES`, `TP_SCOPE_SQL`; `tp_tenant_matrix`,
  `_matrix`, `tp_tenant_cells`; catalog list of the tripplanner RLS tables; reference counts; facts `tp_matrix`,
  `tp_system`; docstring.
- `db/tests/test_isolation_probe.py`: `TripPlannerTenantCellTest` (pending before tp-028 and ready once the policies
  are applied, pass with the tp-028 policies, FAIL with the tp-025 unset branch, another tenant's row, a table not
  forced or not matrixed, no system path, a failed login; a concurrent insert between the reference counts passes;
  matrix records name the role).
- `db/README.md` probe section.

## Tradeoffs

- The matrix runs 4 tables x (3 + tenants) small counts through one login (about 260 statements with 62 tenants,
  milliseconds each), inside the probe's read-only transaction; `set_config(..., true)` is undone by each savepoint.

## Should know

- Merge before the tripplanner/028 bot copy and Migration Apply, so the apply's blocking probe already judges the
  new cells; until tp-028 is registered they are pending (or ready), never red.
- The probe's SQL was run against a local tp-028 database (pass) and a tp-025 one (the isolation cell FAILs on the
  unset branch, as intended).
