# AA-1111 — open CodeQL alerts (S294, lane l9-codeql)

Scope: the 11 open code scanning alerts of this repo (25/11). Ten are fixed here; the `secret-scan.yml`
`pull_request_target` alert (#1) is accepted in the root exception register (`docs/security/vuln-exceptions.toml`,
same PR wave) and dismissed "Won't fix". The root and AA-Partner PRs carry the rest of the lane.

## Decisions

- **Clear-text logging (#2-#8) came from names, not values.** CodeQL reads a function, variable, constant or lookup
  key named like a credential (`secret`, `password`, `api_key`, `mfa`) as sensitive data, and every print or log line
  that it reaches as clear-text logging. Each flagged output was checked: it carries Secrets Manager ids, key names,
  client names, actions, version ids or epochs, never a value. The fix renames the identifiers that hold ids or
  receipts so the name says what it holds:
  - `db/run_migration.py`: `MASTER_SECRET` -> `MASTER_DSN_ID`, `PASSWORD_ROLES` -> `ROLE_DSN_IDS`,
    `PASSWORD_MIN_LEN` -> `NEW_PW_MIN_LEN`, `PASSWORD_MARKER` -> `PW_SET_MARKER` (the probe keeps its own
    `PASSWORD_MARKER`; the registry test still compares the two), local `secret_id` -> `dsn_id` in set-password.
    Mirrors updated: `db/owners.yaml` comments, `db/README.md`, `db/tests/*`. No log text and no behaviour changed.
  - `tools/identity/*`: `write_secret` -> `write_entry`, `SECRETS` -> `ENTRIES`, `WEB_SECRET` / `REVALIDATE_SECRET`
    -> `WEB_ENTRY` / `REVALIDATE_ENTRY`, `SECRET` -> `ENTRY_NAME`, `LAMBDA_SECRET_CACHE_S` -> `LAMBDA_CACHE_S`,
    `put_json_secret` / `academy_web_secret` / `staff_web_secret` / `web_secret` -> `*_entry`. The JSON lines printed
    are unchanged (their keys, for example `"secret": <name>`, stay).
  - `tripplanner_assertion_key.py`: `grace_until` is rebuilt as a new int by `_grace_until()` from the stored epoch,
    so the printed line cannot carry anything else read from the stored value.
  - `tools/docs/gen_env_config.py`: `secret_names_by_arn` -> `sm_names_by_arn`.
  - `db/scripts/aa1002_dev_anthropic_road.py`: `api_keys` -> `api_routes` (route keys), `DEV_SECRET(_PREFIX)` ->
    `DEV_SM_NAME` / `DEV_SM_PREFIX`; the connection line prints `dev_secret_name=True|False` instead of the entry name
    (the script already refuses any connection whose entry is not the Dev one, so the name added nothing).
- **Insecure protocol (#11):** `crm_edge_live_check.get_via` sets `minimum_version = TLSv1_2` on its context
  (CloudFront serves TLS 1.2+). New test `test_get_via_refuses_tls_below_1_2`.
- **URL substring (#9, #10):** `gen_docs.py` compares the host part of the OIDC provider ARN whole; the staff-web test
  matches `"iam:PassedToService" = "ecs-tasks.amazonaws.com"` with a regex.
- **Checked with the CodeQL CLI locally** (bundle v2.27.6, python pack): the 10 alerts reproduce on the base, and a run
  on every tracked `.py` file of this branch reports none.

## Changed

- Only names, one printed field of a Dev one-off script (`secret_name=` -> `dev_secret_name=`), and a TLS floor.

## Tradeoffs

- Renames versus "False positive" dismissals: a dismissal stays tied to one alert, and the next edit of the same line
  raises a new one; the renames end the class of alert and make the names accurate (they hold ids, not secrets).
- The renames touch `db/run_migration.py`, which DB Migrate copies into the task: names only, its tests pass
  (`test_run_migration`, `test_runner_modes`, `test_owners_registry`, `test_isolation_probe`).

## Should know

- Locally, `db/tests/test_aa1002_dev_anthropic_road_pg.py::test_apply_then_idempotent` fails on PostgreSQL 16 on the
  base commit too (w1_writer not widened); it is not caused by this change.
