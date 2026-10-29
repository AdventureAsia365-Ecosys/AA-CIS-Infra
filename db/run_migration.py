"""Runs ONE migration inside a one-off ECS task on the CIS api image (RDS is VPC-private).

Started by .github/workflows/db-migrate.yml, which uploads this file and the migration to S3 and
passes presigned URLs. The task is a revision of the migrator task definition aa-cis-dev-db-migrate
(X1 S12: container migrate, own roles, the image the api service runs). Uses only the image's own
Python + asyncpg (+ boto3 for the secret reads) and the task's DATABASE_URL (Secrets Manager, task
definition) — nothing from the app code.

Logins (X1 S22, plan XD8 / S242 amendment): the task's DATABASE_URL is the login of check / apply of
cis/, booking/, tripplanner/ files — db_migrator from S22 (the RDS master before), switched per file
to the live owner (below). Three things still need the RDS master: roles/ files (roles, extensions,
undo files), mode=set-password (ALTER ROLE … PASSWORD needs CREATEROLE; db_migrator is NOCREATEROLE)
and mode=run-script (master-level scripts since X1 S19). For those the runner uses DATABASE_URL when
it already logs in as the master (before S22), and otherwise reads the master DSN itself, in the
task, from MASTER_SECRET (aa-cis/dev/rds: readable by the migrator task role only, never injected
since S22) and connects with ssl=require. It logs `master login: …` either way and never prints the DSN.

Modes (MIGRATION_MODE): check, apply (below), and two X1 S12 modes whose argument is folded into the
same value, so no new environment variable reaches the task:
  set-password:<role>   role in PASSWORD_ROLES (owners.yaml password_roles: cis_app, db_migrator). Plan
                        XD2: reads the role's DSN secret in the task (boto3), checks the DSN user is the
                        role and the password is >= 32 printable ASCII characters, computes a
                        SCRAM-SHA-256 verifier locally (RFC 5802/7677, 4096 iterations, random 16-byte
                        salt), runs ALTER ROLE <role> PASSWORD '<verifier>' as the master, test-connects
                        with the DSN (prints only current_user and rolconnlimit), then COMMENT ON ROLE
                        <role> IS 'x1:password-set <UTC> by DB Migrate set-password (run <id>)'. Never logs
                        the DSN, the password or the verifier (error texts are redacted).
  run-script:<path>     path = db/scripts/<name>.py (see db/scripts/README.md). The file arrives like a
                        migration (MIGRATION_URL + MIGRATION_SHA256, MIGRATION_FILE = the path), must
                        define a top-level async def main(conn), and runs as the master after the same idle
                        check as apply; its output goes to the log as is.
  apply-pending         AA-993 M3 (migration-apply.yml, root ADR 0017 d5): MIGRATION_URL is a JSON bundle of
                        owner-dir copies with the runner's verdicts (db/apply_pending.py); per owner, in number
                        order, every unregistered expand file is applied (apply lock held for the whole run)
                        until the first file a person must apply. See run_apply_pending below.

Every migration self-registers in shared.schema_versions (repo convention), so:
  check — print whether the version is applied, change nothing
  apply — run the file unless the version is already registered, then require the row exists

Safety defaults (AA-807 N5; data standards MIG-9, MIG-10, MIG-12):
  * every session runs with lock_timeout = '5s', statement_timeout = '15min' and
    application_name = 'db-migrate'. An ALTER queued behind a job transaction then fails after 5 s
    instead of blocking every reader of the table for all three apps;
  * header directives, one per line, in the file's leading comment block:
        -- migrate: lock_timeout=30s            (override; us/ms/s/min/h/d)
        -- migrate: statement_timeout=1h        (override)
        -- migrate: no-transaction              (statements run one by one, outside a transaction,
                                                  e.g. CREATE INDEX CONCURRENTLY; idempotent, the
                                                  schema_versions INSERT last)
        -- migrate: destructive                 (DROP TABLE/SCHEMA/COLUMN, TRUNCATE: DB Migrate
                                                  takes a manual RDS snapshot first and passes its
                                                  id in MIGRATION_SNAPSHOT; apply refuses without it)
  * a lint runs before any connection: unknown or misplaced directives, CONCURRENTLY (not REFRESH …
    CONCURRENTLY) or VACUUM outside a no-transaction file, destructive statements without the header, transaction control inside a
    no-transaction file. A lint error stops check and apply alike.

Idle check (AA-751, ADR 0003a decision 5, data standards C6.3b): every run reports, per owner job
table (every `<schema>.job` with a `status` column, found in the catalog) and for open
`shared.rerun_wave` rows, whether it is busy. Busy = any running row, or queued row due within
BUSY_HORIZON_S (no lower time bound: overdue rows count), of a kind not in IDLE_EXEMPT_KINDS, or an open
wave. A queued row due later is reported as `later` and does not block (AA-990: the place_geocode run
queued for the next Geoapify credit reset sits up to ~24 h ahead). check only reports. apply (once the version is known
to be unapplied) re-checks up to IDLE_WAITS times, IDLE_WAIT_S apart, and refuses with exit 7 while
anything is still busy, unless MIGRATION_IDLE_OVERRIDE carries a reason (workflow input
override_busy_jobs, Nghiệp only). lock_timeout stays the backstop for the check-then-apply race.

Role per file (X1, plan S1 / XD8; registry db/owners.yaml): before anything else the task reads the
**live owner of the dir's anchor schema** (`cis/` → `shared`, `booking/` → `booking`, `tripplanner/`
→ `tripplanner`). Owner = login role (today, for every dir) → the file runs exactly as before, no
switch. Owner ≠ login role → the login role must be a member of the owner and the owner must be able to
register the version (USAGE on shared + INSERT on shared.schema_versions, CIS 243), else exit 8 before
anything runs; the file then runs as the owner: right after the file's `BEGIN` a snapshot of every
owned object and of the role catalog, `SET LOCAL ROLE <owner>`, the body (registration included, as
the owner), then, still inside the transaction and as the owner, the settle step (`SET CONSTRAINTS ALL
IMMEDIATE` in savepoint rounds until a round writes nothing, `CLOSE ALL`: deferred trigger events and
WITH HOLD cursors would otherwise run at COMMIT, after the check, as the login role), `RESET ROLE`, a
pinned search_path and the ownership post-check, then the file's `COMMIT`. Post-check (any schema, any object kind with an owner, default
privileges): an object created or re-owned during the file must belong to the owner (or the dir's
view owner, catalog_owner), the login role may own nothing in a transferred owner's schemas, and
roles / memberships / role settings must not change — else ROLLBACK and exit 9. A no-transaction
file runs statement by statement under `SET ROLE <owner>`, except its last statement (the
registration, a plain literal INSERT): that one runs as the owner in the runner's own transaction,
settled and post-checked before its COMMIT, so a failed check leaves the version unregistered. Both
paths snapshot once more after COMMIT (exit 9 if anything still ran at COMMIT).
The switch follows an owner transfer (bk-014, tp-013, 245) on the very next file, with no flip PR.
`roles/` files (Infra-native, key `rl-NNN`: role bootstrap, extensions, undo files) always run as
the RDS master (from S22 through the in-task master DSN above) and are refused under any other
login. The idle check and the registry reads run as
the login role. Every run logs `ran as: <role>`.

Role lint (files above today's heads, role_lint_from; applied files never re-run): in an owner dir no
`RESET ROLE`, `SET ROLE` without `LOCAL` (quoted "role" too), SESSION AUTHORIZATION in any form,
`set_config('role', …)` or a set_config() whose name is not a plain literal (E'', U&'' and quoted
names included), role switches in dynamic SQL (EXECUTE: every string piece of the statement, the
pieces joined, format() filled in, and half-keyword pieces such as 'RESET ' || 'ROLE'),
`CREATE/ALTER/DROP EXTENSION` or `ROLE` (→ `roles/`), no role membership GRANT/REVOKE; `SET LOCAL
ROLE` only to the dir's allowlist (cis: catalog_owner, cis_owner, cis_app; booking/tripplanner:
none); DDL on a catalog.* view only after `SET LOCAL ROLE catalog_owner` (the S22 catalog recipe);
no DEFERRABLE / INITIALLY DEFERRED constraint trigger and no `SET CONSTRAINTS … DEFERRED` (also
inside string literals: '…' function bodies, dynamic SQL). Such a file is also one BEGIN … COMMIT
block, or a `-- migrate: no-transaction` file whose last statement is a plain literal
`INSERT INTO shared.schema_versions … VALUES (…)`, the shapes the switch needs, so a wrong shape fails
in the PR rather than with exit 8 at apply. Obfuscated dynamic
SQL (chr(), reverse(), …) is beyond a lint; the post-check is the backstop.
Before running such a file (check and apply), the login role must be a member of every `SET LOCAL
ROLE` target (PostgreSQL checks the session user), else exit 8: this is where the catalog.* view
freeze from S1 to S22 bit (the master is not a member of catalog_owner and never becomes one; since
S22 the login db_migrator is, which ended the freeze), and where a db_migrator without cis_app would
show up.

Exit codes (10–13: X1 S12): 10 mode input refused (unknown MIGRATION_MODE, role or script path outside the
allowlists, MIGRATION_FILE not the script, script without async def main(conn)) · 11 set-password refused
before any change (role missing or NOLOGIN, secret unreadable/empty/not a DSN of that role, weak password) ·
12 set-password: password set but the test login failed (role not marked) · 13 run-script raised or
returned non-zero · 8 also covers set-password / run-script under a login other than the master, and (X1 S22)
a roles/ file, set-password or run-script whose in-task master DSN (MASTER_SECRET) is unreadable, empty or
fails to log in, or logs in as someone other than the master.
Exit codes: 0 ok · 2 sha256 mismatch · 3 file ran but did not register · 4 lint error ·
5 destructive apply without a snapshot · 6 PostgreSQL error (lock/statement timeout included) ·
7 apply refused: a job table is busy or a rerun wave is open · 8 role refused (roles/ under a
non-master login, login not a member of the live owner, the owner cannot register the version,
unknown dir, a file that cannot run under the switch, or a `SET LOCAL ROLE` target the login role
is not a member of) · 9 ownership post-check failed (rolled
back; for a no-transaction file the statements before the registration stay committed and the
version is not registered), or the check after COMMIT found something that ran at COMMIT (committed
and registered: clean up by hand).
Exit codes (AA-993 M2a/M2b, root ADR 0017): 14 the expand runtime post-check found a change outside the allowed set
(an existing object changed or dropped, a new policy / trigger / constraint / unique index on an existing table, an
overload, default privileges, rows written to an existing table, a column on a hot table, a new table needing RLS
without ENABLE + FORCE): rolled back, not registered, the log names each object · 15 lock risk: an expand
file would lock an existing table above EXPAND_MAX_ROWS or of unknown size (non-concurrent CREATE INDEX, ALTER TABLE),
or creates with IF NOT EXISTS a relation that already exists — nothing ran, make it a contract file (or use
CONCURRENTLY) · 16 an expand CREATE INDEX CONCURRENTLY left a missing or INVALID index —
the statements ran, the version is NOT registered, drop the index named in the log and re-run · 17 the apply lock
(session advisory lock shared by every applying mode) stayed taken by another run for APPLY_LOCK_WAIT_S — nothing ran.

`-- migrate: expand` (AA-993 M2a): the file only adds (new objects; on an existing table a nullable column or one with
a non-volatile default, or a non-unique index). It runs with statement_timeout 30s (CIC files keep the default), skips
the job-table idle wait (it still waits for an open wave when it names a hot table, Q5), is size-checked before any
statement (exit 15) and, for a CIC file, index-validity-checked before its registration (exit 16). The static lint
(expand_lint) refuses what the text shows; no header = contract, DB Migrate behaves exactly as before.
M2b: a transactional expand file is one BEGIN … COMMIT block; between them the runner snapshots the catalog of every
non-system schema and the transaction's row counters before and after the body (expand_snapshot) and diffs them
(expand_findings): anything outside the allowed set is ROLLBACK + exit 14. A CIC file gets the same diff before its
registration. In check mode a transactional expand file is rehearsed: the body and the post-check run, then ROLLBACK
(it takes the apply lock, since its statements run). db/expand_check.py --classify runs the same code on a replayed
CI PostgreSQL.

Local, no database and no asyncpg needed (CI lint and the DB Migrate "Validate input" step):
  python3 db/run_migration.py --inspect db/migrations/cis/230_x.sql
prints the parsed directives as JSON and exits 1 on a lint error;
  python3 db/run_migration.py --inspect-script db/scripts/session_info.py
prints {"errors": [...]} for a run-script file and exits 1 on any.
"""
import ast
import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone

DEFAULT_SETTINGS = {"lock_timeout": "5s", "statement_timeout": "15min", "application_name": "db-migrate"}
OVERRIDABLE = ("lock_timeout", "statement_timeout")
FLAGS = ("no-transaction", "destructive", "expand")

DIRECTIVE_RE = re.compile(r"^\s*--\s*migrate:\s*(.*?)\s*$", re.IGNORECASE)
DURATION_RE = re.compile(r"^[0-9]+(us|ms|s|min|h|d)?$")
DOLLAR_TAG_RE = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")

# Statement shapes, matched on the statement's code (comments removed, string bodies blanked,
# whitespace collapsed, upper case).
TX_CONTROL_RE = re.compile(r"^(BEGIN|START TRANSACTION|COMMIT|END|ROLLBACK|ABORT)\b")
PREPARE_TX_RE = re.compile(r"^PREPARE TRANSACTION\b")      # ends the transaction too (two-phase commit)
CONCURRENTLY_RE = re.compile(r"\bCONCURRENTLY\b")
# REFRESH MATERIALIZED VIEW CONCURRENTLY is allowed inside a transaction block; the other
# CONCURRENTLY forms (CREATE/DROP INDEX, REINDEX, DETACH PARTITION) are not.
TX_SAFE_CONCURRENTLY_RE = re.compile(r"^REFRESH MATERIALIZED VIEW CONCURRENTLY\b")
# Statements PostgreSQL refuses inside a transaction block (the whole-file path runs in one).
NO_TX_ONLY_RE = re.compile(r"^VACUUM\b")
DESTRUCTIVE_RES = (
    (re.compile(r"^DROP (TABLE|SCHEMA|MATERIALIZED VIEW)\b"), "DROP {0}"),
    (re.compile(r"^TRUNCATE\b"), "TRUNCATE"),
    # ALTER TABLE … DROP [COLUMN] x — but not DROP CONSTRAINT/DEFAULT/NOT NULL/IDENTITY/EXPRESSION.
    (re.compile(r"^ALTER TABLE\b.*\bDROP (?!CONSTRAINT\b|DEFAULT\b|NOT\b|IDENTITY\b|EXPRESSION\b)"),
     "ALTER TABLE … DROP COLUMN"),
)
DELETE_RE = re.compile(r"^(WITH\b.*\b)?DELETE FROM\b")

# Idle check (AA-751). Kinds that are always queued or running by design and only run short
# transactions; a busy row of any other kind blocks apply. Mirrors the owners' sources until X1
# (owners.yaml): CIS registry `deploy_gate_exempt`; Booking backend/app/inquiry/intake.py RECURRING
# (bk_inquiry_pull, every 60 s) - Booking's DEPLOY_GATE_EXEMPT registry arrives with B4, point here
# at it then. Daily retention kinds are deliberately NOT exempt.
# shared: none since AA-751 (S240). ops_rds_role_connections (every 5 min, AA-832) was removed
# from the CIS registry when the CIS api started publishing AA/RDS from an in-process sampler.
IDLE_EXEMPT_KINDS = {
    "shared": frozenset(),
    "booking": frozenset({"bk_inquiry_pull"}),            # always queued at +60 s (bk-002 intake)
    # AA-932: AA-Partner worker liveness kind (AA-933); AA-978: the CIS membership feed pull, every 20 s;
    # AA-947: the AA outage queue + Booking feed (crm_booking_sync), every 60 s
    "crm": frozenset({"crm_heartbeat", "crm_membership_pull", "crm_booking_sync"}),
    # AA-861 (tp-021): the TripPlanner jobs Lambda runs once a day; no always-queued kind, so nothing is exempt.
    "tripplanner": frozenset(),
}
# AA-990: mirrors the CIS deploy gate (AA-CIS-App shared/jobs/queue.py DEPLOY_GATE_HORIZON_S). A queued row due
# more than this far ahead is not touched by a migration that takes minutes; whichever schema it then meets is the one
# its claim sees. Every scheduled run_after in the owners' runners is <= 20 min except that credit-reset row.
BUSY_HORIZON_S = 3600
IDLE_WAITS = 3          # apply re-checks this many times before it refuses …
IDLE_WAIT_S = 20        # … this many seconds apart
JOB_TABLES_SQL = """
SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relname = 'job' AND c.relkind IN ('r', 'p')
   AND EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = c.oid AND a.attname = 'status' AND NOT a.attisdropped)
 ORDER BY n.nspname"""
JOB_BUSY_SQL = """
SELECT kind, status,
       count(*) FILTER (WHERE status = 'running' OR run_after <= now() + make_interval(secs => $2))::int AS n,
       count(*) FILTER (WHERE status = 'queued' AND run_after <= now())::int AS due,
       count(*) FILTER (WHERE status = 'queued' AND run_after > now() + make_interval(secs => $2))::int AS later
  FROM {table} WHERE status IN ('queued', 'running') AND NOT (kind = ANY($1::text[]))
 GROUP BY kind, status ORDER BY kind, status"""
WAVE_TABLE_SQL = "SELECT to_regclass('shared.rerun_wave') IS NOT NULL"
OPEN_WAVES_SQL = "SELECT count(*)::int FROM shared.rerun_wave WHERE status = 'open'"


# ── X1 owner registry mirror (db/owners.yaml; db/tests/test_owners_registry.py keeps them equal) ──
# The task gets only this file and the SQL (presigned URLs), so the registry facts it needs are
# constants here, not a YAML read (no PyYAML in the runner, no new env var).
MASTER_ROLE = "aa_cis_admin"      # RDS master: runs roles/ files, set-password, run-script; break-glass after X1 S22
# owners.yaml master_secret: the master DSN the runner reads in the task (migrator task role) when DATABASE_URL is
# not the master (X1 S22: db_migrator), for roles/ files, set-password and run-script only.
MASTER_SECRET = "aa-cis/dev/rds"
ROLES_DIR = "roles"               # Infra-native files, key rl-NNN
# AA-853: every db/replay_baseline/ file (lost lineage the drift replay recreates, db/gen_replay_baseline.py) carries
# this marker; lint refuses it, so a baseline copied into db/migrations/ can never be checked or applied.
BASELINE_MARKER = "aa-853-replay-baseline"
# owners.yaml password_roles: LOGIN roles whose password mode=set-password sets from their DSN secret (XD2).
PASSWORD_ROLES = {"cis_app": "aa-cis/dev/rds-cis-app", "crm_app": "crm/dev/database-url",
                  "db_migrator": "aa-cis/dev/db-migrator"}


@dataclass(frozen=True)
class OwnerDir:
    anchor_schema: str            # its live owner decides the role a file runs as (XD8)
    schemas: tuple                # every schema of the owner (ownership post-check, 244/245 lists)
    set_local_roles: frozenset    # the only `SET LOCAL ROLE` targets the lint allows in the dir
    role_lint_from: int           # first file number the role lint applies to (> today's head)
    view_owner_roles: frozenset = frozenset()   # may own objects a switched file creates, besides the owner
    dropped_schemas: tuple = ()   # schemas the owner dropped (owners.yaml dropped_schemas): lint only, never live
    # AA-993 M2a: owners.yaml runtime_roles + nologin_roles, the only grantees an expand file may name.
    grant_roles: frozenset = frozenset()


OWNER_DIRS = {
    "cis": OwnerDir("shared",
                    ("acp_contract", "acp_deliver", "acp_shared", "catalog", "geo", "gold_aa_internal",
                     "retired",            # AA-850 (CIS 294): DM-3.9 quarantine schema, no runtime grant
                     "shared", "silver_aa_internal"),
                    frozenset({"catalog_owner", "cis_owner", "cis_app"}), 243, frozenset({"catalog_owner"}),
                    # AA-850 (CIS 299): the four empty ACP v1 stage schemas, dropped
                    ("acp_gold_output", "acp_silver_s2", "acp_silver_s3", "acp_silver_s4"),
                    grant_roles=frozenset({"cis_app", "aa_app_user"})),
    "booking": OwnerDir("booking", ("booking",), frozenset(), 14, grant_roles=frozenset({"booking"})),
    "tripplanner": OwnerDir("tripplanner", ("tripplanner",), frozenset(), 13, grant_roles=frozenset({"tripplanner"})),
    # AA-932: born under crm_owner (rl-003), lint from crm-001
    "crm": OwnerDir("crm", ("crm",), frozenset(), 1,
                    grant_roles=frozenset({"crm_app", "crm_ai_reader", "crm_eraser", "crm_insights",
                                           "crm_support_reader"})),
}
OWNER_SCHEMAS = tuple(sorted({s for o in OWNER_DIRS.values() for s in o.schemas}))
MIGRATION_PATH_RE = re.compile(r"(?:^|/)([a-z]+)/([0-9]{3})_[^/]*\.sql$")

SESSION_USER_SQL = "SELECT session_user::text"
SCHEMA_OWNER_SQL = "SELECT pg_get_userbyid(nspowner)::text FROM pg_namespace WHERE nspname = $1"
IS_MEMBER_SQL = "SELECT pg_has_role(session_user, $1, 'MEMBER')"
# Registration under the switch: the file's INSERT INTO shared.schema_versions runs as the owner
# (plan S4: 243 grants USAGE on shared + SELECT, INSERT on shared.schema_versions to bk_owner/tp_owner).
CAN_REGISTER_SQL = ("SELECT pg_catalog.has_schema_privilege($1, 'shared', 'USAGE') "
                    "AND pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'INSERT')")
# `SET LOCAL ROLE r` inside a file: PostgreSQL checks the SESSION user's membership in r, not the role
# the runner switched to. The roles of $1 the login role cannot SET ROLE to (missing or not a member).
SET_ROLE_REACH_SQL = ("SELECT t.role FROM pg_catalog.unnest($1::text[]) AS t(role) "
                      "LEFT JOIN pg_catalog.pg_roles r ON r.rolname OPERATOR(pg_catalog.=) t.role "
                      "WHERE r.oid IS NULL OR NOT pg_catalog.pg_has_role(session_user, r.oid, 'MEMBER') "
                      "ORDER BY 1")
# Ownership post-check (plan S1 item 5, hardened after review). Snapshot of everything that has an
# owner (every schema but pg_catalog, information_schema, pg_toast and temp schemas) plus the role
# catalog, taken before the file (as the login role) and again after the runner's RESET ROLE.
# A row is identified by (kind, id, owner), so a new object and an ownership change both show up.
# Rows owned by the role the file runs as ($2) are left out: they are always fine. All catalog
# names are schema-qualified and the runner pins search_path first, so a file cannot shadow them.
OBJECTS_SQL = """
WITH s AS (
  SELECT n.oid, n.nspname, n.nspowner, n.nspname = ANY($1::text[]) AS mine
    FROM pg_catalog.pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
     AND n.nspname !~ '^pg_(toast_)?temp_'),
o AS (
  SELECT 'relation' AS kind, c.oid::text AS id, s.nspname || '.' || c.relname AS name, c.relowner AS owner,
         s.mine, s.nspowner
    FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
  UNION ALL
  SELECT 'function', p.oid::text,
         s.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
         p.proowner, s.mine, s.nspowner
    FROM pg_catalog.pg_proc p JOIN s ON s.oid = p.pronamespace
  UNION ALL
  SELECT 'type', t.oid::text, s.nspname || '.' || t.typname, t.typowner, s.mine, s.nspowner
    FROM pg_catalog.pg_type t JOIN s ON s.oid = t.typnamespace
   WHERE t.typrelid = 0 AND t.typcategory <> 'A'
  UNION ALL
  SELECT 'schema', s.oid::text, s.nspname, s.nspowner, s.mine, s.nspowner FROM s
  UNION ALL
  SELECT 'operator', x.oid::text, s.nspname || '.' || x.oprname, x.oprowner, s.mine, s.nspowner
    FROM pg_catalog.pg_operator x JOIN s ON s.oid = x.oprnamespace
  UNION ALL
  SELECT 'operator class', x.oid::text, s.nspname || '.' || x.opcname, x.opcowner, s.mine, s.nspowner
    FROM pg_catalog.pg_opclass x JOIN s ON s.oid = x.opcnamespace
  UNION ALL
  SELECT 'operator family', x.oid::text, s.nspname || '.' || x.opfname, x.opfowner, s.mine, s.nspowner
    FROM pg_catalog.pg_opfamily x JOIN s ON s.oid = x.opfnamespace
  UNION ALL
  SELECT 'collation', x.oid::text, s.nspname || '.' || x.collname, x.collowner, s.mine, s.nspowner
    FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
  UNION ALL
  SELECT 'conversion', x.oid::text, s.nspname || '.' || x.conname, x.conowner, s.mine, s.nspowner
    FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
  UNION ALL
  SELECT 'text search dictionary', x.oid::text, s.nspname || '.' || x.dictname, x.dictowner, s.mine, s.nspowner
    FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
  UNION ALL
  SELECT 'text search configuration', x.oid::text, s.nspname || '.' || x.cfgname, x.cfgowner, s.mine, s.nspowner
    FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace
  UNION ALL
  SELECT 'statistics', x.oid::text, s.nspname || '.' || x.stxname, x.stxowner, s.mine, s.nspowner
    FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace
  UNION ALL
  SELECT 'default privileges', d.oid::text || ':' || COALESCE(d.defaclacl::text, ''),
         COALESCE(s.nspname, '(all schemas)') || ' ' || d.defaclobjtype::text, d.defaclrole, COALESCE(s.mine, false),
         s.nspowner
    FROM pg_catalog.pg_default_acl d LEFT JOIN s ON s.oid = d.defaclnamespace
  UNION ALL
  SELECT 'extension', x.oid::text, x.extname::text, x.extowner, false, NULL FROM pg_catalog.pg_extension x
  UNION ALL
  SELECT 'language', x.oid::text, x.lanname::text, x.lanowner, false, NULL FROM pg_catalog.pg_language x
  UNION ALL
  SELECT 'foreign data wrapper', x.oid::text, x.fdwname::text, x.fdwowner, false, NULL
    FROM pg_catalog.pg_foreign_data_wrapper x
  UNION ALL
  SELECT 'foreign server', x.oid::text, x.srvname::text, x.srvowner, false, NULL FROM pg_catalog.pg_foreign_server x
  UNION ALL
  SELECT 'publication', x.oid::text, x.pubname::text, x.pubowner, false, NULL FROM pg_catalog.pg_publication x
  UNION ALL
  SELECT 'event trigger', x.oid::text, x.evtname::text, x.evtowner, false, NULL FROM pg_catalog.pg_event_trigger x
  UNION ALL
  SELECT 'large object', x.oid::text, x.oid::text, x.lomowner, false, NULL FROM pg_catalog.pg_largeobject_metadata x
  UNION ALL
  SELECT 'database', x.oid::text, x.datname::text, x.datdba, false, NULL FROM pg_catalog.pg_database x
  UNION ALL
  SELECT 'role', pg_catalog.md5(r::text), r.rolname::text, NULL, false, NULL FROM pg_catalog.pg_roles r
  UNION ALL
  SELECT 'role membership', pg_catalog.md5(m::text),
         pg_catalog.pg_get_userbyid(m.member)::text || ' in ' || pg_catalog.pg_get_userbyid(m.roleid)::text,
         NULL, false, NULL
    FROM pg_catalog.pg_auth_members m
  UNION ALL
  SELECT 'role setting', pg_catalog.md5(x::text),
         COALESCE(pg_catalog.pg_get_userbyid(NULLIF(x.setrole, 0))::text, 'every role') || ' ' || x.setconfig::text,
         NULL, false, NULL
    FROM pg_catalog.pg_db_role_setting x)
SELECT o.kind, o.id, o.name, pg_catalog.pg_get_userbyid(o.owner)::text AS owner, o.mine,
       pg_catalog.pg_get_userbyid(o.nspowner)::text AS schema_owner
  FROM o
 WHERE o.owner IS NULL OR o.owner IS DISTINCT FROM (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = $2)"""
ROLE_KINDS = ("role", "role membership", "role setting")
PIN_SEARCH_PATH_SQL = "SET {scope}search_path TO pg_catalog, pg_temp"
# Settle (review S241, round 2), run while the owner role is still current, right before RESET ROLE:
# SET CONSTRAINTS ALL IMMEDIATE fires every pending deferred trigger event (DEFERRABLE constraint
# triggers, deferred FK / unique checks) now instead of at COMMIT, and CLOSE ALL closes every cursor (a
# WITH HOLD cursor's query runs at COMMIT). A fired trigger can re-defer (SET CONSTRAINTS … DEFERRED + a
# row write queues a new event), so each round runs in a savepoint and is repeated until a round writes
# nothing: queueing an event takes a row write, a write assigns the savepoint a transaction id, and the
# backend holds a lock on each id it has assigned (count by XACT_IDS_SQL, no search_path lookup).
SETTLE_ROUNDS = 10
SETTLE_SAVEPOINT = "x1_settle"
XACT_IDS_SQL = ("SELECT pg_catalog.count(*) FROM pg_catalog.pg_locks l "
                "WHERE l.locktype OPERATOR(pg_catalog.=) 'transactionid' "
                "AND l.pid OPERATOR(pg_catalog.=) pg_catalog.pg_backend_pid()")

# Role lint (plan S1 item 6), matched on the code view of _role_view(): comments removed, string
# literals (E'', U&'' included) replaced by '#<n>' placeholders, plain quoted names unquoted ("role"
# is the GUC role), dollar-quoted bodies (DO blocks, functions) lexed as code.
PLAIN_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
SET_ROLE_RE = re.compile(r"\bSET\s+(?:(SESSION|LOCAL)\s+)?ROLE\b(?:\s+TO\b|\s*=)?\s*(\"[^\"]*\"|'#[0-9]+'|[A-Z0-9_$]+)?")
ROLE_SWITCH_RES = (
    (re.compile(r"\bRESET\s+ROLE\b"), "RESET ROLE returns to the login role (after X1 S22 that is "
                                      "db_migrator): go back with `SET LOCAL ROLE <dir owner>` instead"),
    (re.compile(r"\b(?:SET|RESET)\s+(?:(?:SESSION|LOCAL)\s+)?(?:SESSION\s+AUTHORIZATION|SESSION_AUTHORIZATION)\b"),
     "SET/RESET SESSION AUTHORIZATION is not allowed in a migration"),
    (re.compile(r"\b(?:CREATE|ALTER|DROP)\s+EXTENSION\b"),
     "CREATE/ALTER/DROP EXTENSION belongs in db/migrations/roles/ (runs as the master)"),
    (re.compile(r"\b(?:CREATE|ALTER|DROP)\s+(?:ROLE|USER|GROUP)\b(?!\s+MAPPING\b)"),
     "CREATE/ALTER/DROP ROLE belongs in db/migrations/roles/ (role bootstrap, MIG-6, DM-8.1)"),
)
# set_config(name, …): name must be a plain string literal, so the lint can see it is not role.
SET_CONFIG_RE = re.compile(r"\bSET_CONFIG\s*\(\s*(?:'#([0-9]+)'\s*(?=,))?")
ROLE_GUCS = ("role", "session_authorization")
# plpgsql dynamic SQL: EXECUTE <expression> (not GRANT EXECUTE ON …, EXECUTE FUNCTION/PROCEDURE in a
# trigger). The expression runs to the end of the statement, or to USING / INTO.
DYNAMIC_EXECUTE_RE = re.compile(r"\bEXECUTE\b(?!\s+(?:ON|FUNCTION|PROCEDURE)\b)")
EXPRESSION_END_RE = re.compile(r"\b(?:USING|INTO)\b|;")
FORMAT_SPEC_RE = re.compile(r"%(?:[0-9]+\$)?-?[0-9]*([sIL%])")
# A role switch assembled from pieces: a piece that starts with ROLE / SESSION AUTHORIZATION or ends
# with SET / RESET, or a format() placeholder right before ROLE.
SWITCH_FRAGMENT_RE = re.compile(
    r"^\s*(?:ROLE|SESSION(?:\s+|_)AUTHORIZATION)\b|\b(?:SET|RESET)\s*$|%[0-9$]*[SIL]\s+(?:ROLE|SESSION)\b",
    re.IGNORECASE)
GRANT_RE = re.compile(r"\b(GRANT|REVOKE)\b")
# catalog.* views belong to catalog_owner (CIS 225). DDL on one runs only as catalog_owner (the S22
# catalog recipe), and only once the DB Migrate login is a member of catalog_owner (db_migrator, X1
# S22). The master is not a member since 225 and must never become one (X1 plan §1.4), so from S1 to
# S22 catalog.* view changes were frozen (X1 review, S241, XD9). The lint asks for the recipe; the
# runner's membership pre-check (SET_ROLE_REACH_SQL) refuses it at `check` time under any login that is
# not a member of catalog_owner (the master, i.e. a migrator task definition rolled back before S22).
CATALOG_VIEW_DDL_RE = re.compile(
    r"\b(?:CREATE(?:\s+OR\s+REPLACE)?(?:\s+(?:TEMP|TEMPORARY|RECURSIVE))*|ALTER|DROP)\s+(?:MATERIALIZED\s+)?"
    r"VIEW\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?CATALOG\s*\.")
CATALOG_FREEZE = ("catalog.* view changes need the catalog recipe: a cis/ file changes a catalog view only with "
                  "GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE catalog_owner; …; SET LOCAL "
                  "ROLE cis_owner; REVOKE CREATE … (never RESET ROLE), and only under a DB Migrate login that is a "
                  "member of catalog_owner — db_migrator since X1 S22 (the S1–S22 freeze, XD9, is over); the "
                  "master never is (X1 plan §1.4, AA-CIS-App CONTEXT.md)")
# The recipe's GRANT CREATE ON SCHEMA catalog TO catalog_owner must be revoked again in the same file (review S244):
# a file that forgets the REVOKE commits a standing CREATE on schema catalog for catalog_owner, which no post-check
# sees (it checks owners, not ACLs). Code views are upper case; ALL [PRIVILEGES] grants CREATE too.
CATALOG_CREATE_GRANT_RE = re.compile(
    r"\bGRANT\s+(?:ALL(?:\s+PRIVILEGES)?|(?:\w+\s*,\s*)*CREATE(?:\s*,\s*\w+)*)\s+ON\s+SCHEMA\s+(?:[\w\"]+\s*,\s*)*"
    r"\"?CATALOG\b\"?[^;]*?\bTO\b[^;]*\"?CATALOG_OWNER\b")
CATALOG_CREATE_REVOKE_RE = re.compile(
    r"\bREVOKE\s+(?:ALL(?:\s+PRIVILEGES)?|(?:\w+\s*,\s*)*CREATE(?:\s*,\s*\w+)*)\s+ON\s+SCHEMA\s+(?:[\w\"]+\s*,\s*)*"
    r"\"?CATALOG\b\"?[^;]*?\bFROM\b[^;]*\"?CATALOG_OWNER\b")
# Work queued for COMMIT runs after the post-check, as whatever role is current then (review S241,
# round 2). The runner settles it under the owner role before RESET ROLE (SETTLE_ROUNDS); the lint
# refuses the deferral itself in files that may run under the switch (belt and braces).
DEFERRAL_RES = (
    (re.compile(r"\bCREATE\s+(?:OR\s+REPLACE\s+)?CONSTRAINT\s+TRIGGER\b[^;]*?"
                r"(?:(?<!NOT )\bDEFERRABLE\b|\bINITIALLY\s+DEFERRED\b)"),
     "a DEFERRABLE / INITIALLY DEFERRED constraint trigger fires at COMMIT, after the role switch's "
     "post-check: make it NOT DEFERRABLE (X1)"),
    (re.compile(r"\bSET\s+CONSTRAINTS\b[^;]*\bDEFERRED\b"),
     "SET CONSTRAINTS … DEFERRED postpones trigger work to COMMIT, after the role switch's post-check (X1)"),
)
# The registration of a no-transaction file under the switch runs in the runner's own transaction,
# checked like the rest; the lint keeps it a plain literal INSERT so no code hides in it.
REGISTRATION_LITERAL = r"(?:E?''|[0-9]+(?:\.[0-9]+)?|NULL|TRUE|FALSE|DEFAULT|NOW\s*\(\s*\)|CURRENT_TIMESTAMP)"
REGISTRATION_RE = re.compile(
    r"^INSERT\s+INTO\s+SHARED\.SCHEMA_VERSIONS\s*(?:\(\s*[A-Z_]+(?:\s*,\s*[A-Z_]+)*\s*\)\s*)?"
    rf"VALUES\s*\(\s*{REGISTRATION_LITERAL}(?:\s*,\s*{REGISTRATION_LITERAL})*\s*\)"
    r"(?:\s*ON\s+CONFLICT(?:\s*\(\s*VERSION\s*\))?\s+DO\s+NOTHING)?$")


def log(msg: str) -> None:
    print(f"MIGRATE {msg}", flush=True)


@dataclass
class Directives:
    no_transaction: bool = False
    destructive: bool = False
    expand: bool = False                                    # AA-993 M2a: `-- migrate: expand`
    settings: dict = field(default_factory=lambda: dict(DEFAULT_SETTINGS))
    errors: list = field(default_factory=list)
    explicit: set = field(default_factory=set)              # settings the header set

    def as_json(self) -> dict:
        return {"no_transaction": self.no_transaction, "destructive": self.destructive, "expand": self.expand,
                "settings": self.settings}


@dataclass
class Statement:
    text: str      # raw SQL as written (leading comments included), sent as is
    code: str      # no comments, string/dollar bodies blanked, whitespace collapsed, upper case, no ";"
    line: int      # 1-based line of the statement's first code character


def parse_directives(sql: str) -> Directives:
    """Reads `-- migrate:` directives from the leading comment block (blank and `--` lines)."""
    d = Directives()
    seen: dict = {}
    in_header = True
    for lineno, line in enumerate(sql.splitlines(), 1):
        stripped = line.strip()
        if in_header and stripped and not stripped.startswith("--"):
            in_header = False
        m = DIRECTIVE_RE.match(line)
        if not m:
            continue
        if not in_header:
            d.errors.append(f"line {lineno}: `-- migrate:` directive after the first statement is not "
                            f"honoured — move it into the leading comment block")
            continue
        value = re.split(r"\s+--", m.group(1), maxsplit=1)[0].strip()    # allow a trailing `-- note`
        flag = value.lower()
        if flag in FLAGS:
            if flag == "no-transaction":
                d.no_transaction = True
            elif flag == "expand":
                d.expand = True
            else:
                d.destructive = True
            continue
        if "=" in value:
            key, raw = (p.strip() for p in value.split("=", 1))
            key, raw = key.lower(), raw.strip("'\"").replace(" ", "")
            if key == "application_name":
                d.errors.append(f"line {lineno}: application_name is fixed to 'db-migrate' "
                                f"(standards C1.1a: load attribution)")
            elif key not in OVERRIDABLE:
                d.errors.append(f"line {lineno}: unknown setting '{key}' (allowed: {', '.join(OVERRIDABLE)})")
            elif not DURATION_RE.match(raw):
                d.errors.append(f"line {lineno}: {key}={raw!r} is not a duration like 5s, 500ms, 15min, 1h")
            elif key in seen and seen[key] != raw:
                d.errors.append(f"line {lineno}: {key} set twice ({seen[key]} and {raw})")
            else:
                seen[key] = d.settings[key] = raw
            continue
        d.errors.append(f"line {lineno}: unknown directive {value!r} (known: {', '.join(FLAGS)}, "
                        f"{'=…, '.join(OVERRIDABLE)}=…)")
    d.explicit = set(seen)
    # AA-993 M2a (ADR 0017 d4): an expand file in a transaction runs with a 30 s statement_timeout unless its header
    # sets a lower one (expand_lint refuses a higher one); a CIC (no-transaction) file keeps the default.
    if d.expand and not d.no_transaction and "statement_timeout" not in seen:
        d.settings["statement_timeout"] = EXPAND_STATEMENT_TIMEOUT
    return d


def split_statements(sql: str) -> list:
    """Splits SQL on top-level `;`, aware of comments, quotes, E'' strings and dollar quotes."""
    out: list = []
    n = len(sql)
    i = start = 0
    code: list = []
    first = -1          # index of the current statement's first code character

    def flush(end: int) -> None:
        text = sql[start:end].strip()
        norm = " ".join("".join(code).split()).upper()
        if norm:
            out.append(Statement(text, norm, sql.count("\n", 0, first) + 1))

    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if c == "-" and nxt == "-":                           # line comment
            j = sql.find("\n", i)
            i = n if j == -1 else j
            code.append(" ")
            continue
        if c == "/" and nxt == "*":                           # block comment (nests in PostgreSQL)
            depth, j = 1, i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            i = j
            code.append(" ")
            continue
        if first == -1 and not c.isspace():
            first = i
        if c == "'":                                          # string literal ('' escapes; E'' backslashes)
            backslash = i > 0 and sql[i - 1] in "eE" and not (i > 1 and (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            j = i + 1
            while j < n:
                if backslash and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            code.append("''")
            i = j + 1
            continue
        if c == '"':                                          # quoted identifier
            j = i + 1
            while j < n:
                if sql[j] == '"':
                    if j + 1 < n and sql[j + 1] == '"':
                        j += 2
                        continue
                    break
                j += 1
            code.append(sql[i:j + 1])
            i = j + 1
            continue
        if c == "$" and not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
            m = DOLLAR_TAG_RE.match(sql, i)
            if m:                                             # dollar-quoted body
                end = sql.find(m.group(0), m.end())
                i = n if end == -1 else end + len(m.group(0))
                code.append("$$")
                continue
        if c == ";":
            flush(i + 1)
            start, code, first = i + 1, [], -1
            i += 1
            continue
        code.append(c)
        i += 1
    flush(n)
    return out


def _role_view(sql: str, strings: list) -> str:
    """Code view for the role lint: comments removed, each string literal replaced by '#<n>' (its text
    appended to `strings`), dollar-quoted bodies lexed as code too (role switches hide in DO blocks),
    whitespace collapsed, upper case."""
    out: list = []
    n = len(sql)
    i = 0
    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if c == "-" and nxt == "-":
            j = sql.find("\n", i)
            i = n if j == -1 else j
            out.append(" ")
            continue
        if c == "/" and nxt == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            i = j
            out.append(" ")
            continue
        word_start = not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] in "_$"))
        if word_start and c in "eE" and nxt == "'":           # E'…' string: drop the prefix
            i += 1
            continue
        if word_start and c in "uU" and nxt == "&" and i + 2 < n and sql[i + 2] in "'\"":   # U&'…' / U&"…"
            i += 2
            continue
        if c == "'":
            backslash = i > 0 and sql[i - 1] in "eE" and not (i > 1 and (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            j, buf = i + 1, []
            while j < n:
                if backslash and sql[j] == "\\":
                    buf.append(sql[j:j + 2])
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(sql[j])
                j += 1
            strings.append("".join(buf))
            out.append(f" '#{len(strings) - 1}' ")
            i = j + 1
            continue
        if c == '"':
            j = i + 1
            while j < n:
                if sql[j] == '"':
                    if j + 1 < n and sql[j + 1] == '"':
                        j += 2
                        continue
                    break
                j += 1
            ident = sql[i + 1:j]
            # "role", "set_config": a plain quoted name is the same keyword or GUC to PostgreSQL
            # (GUC names are case-insensitive), so the lint sees it unquoted.
            out.append(f" {ident} " if PLAIN_IDENT_RE.match(ident) else sql[i:j + 1])
            i = j + 1
            continue
        if c == "$" and not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
            m = DOLLAR_TAG_RE.match(sql, i)
            if m:
                end = sql.find(m.group(0), m.end())
                body = sql[m.end():] if end == -1 else sql[m.end():end]
                out.append(" " + _role_view(body, strings) + " ; ")
                i = n if end == -1 else end + len(m.group(0))
                continue
        out.append(c)
        i += 1
    return " ".join("".join(out).split()).upper()


def _membership_grants(code: str) -> list:
    """GRANT/REVOKE statements without ON, i.e. role membership (`GRANT r TO x`, `REVOKE r FROM x`)."""
    found = []
    for m in GRANT_RE.finditer(code):
        if code[max(0, m.start() - 5):m.start()].rstrip().endswith("WITH"):   # WITH GRANT OPTION
            continue
        rest = code[m.end():].split(";", 1)[0]
        stop = re.search(r"\bTO\b" if m.group(1) == "GRANT" else r"\bFROM\b", rest)
        if stop and not re.search(r"\bON\b", rest[:stop.start()]):
            found.append(f"{m.group(1)}{rest[:stop.end()]}".strip())
    return found


def _switches(code: str, strings: list) -> bool:
    """True when a code view switches or defines a role (any SET ROLE, RESET ROLE, SESSION
    AUTHORIZATION, set_config('role') or a non-literal set_config name, EXTENSION/ROLE DDL)."""
    for m in SET_ROLE_RE.finditer(code):
        if not re.search(r"\bUPDATE\b", code[:m.start()].rsplit(";", 1)[-1]):
            return True
    if any(rx.search(code) for rx, _ in ROLE_SWITCH_RES):
        return True
    return any(m.group(1) is None or strings[int(m.group(1))].strip().lower() in ROLE_GUCS
               for m in SET_CONFIG_RE.finditer(code))


def _format_text(expr: str, strings: list) -> str:
    """format('…', args) of an EXECUTE expression with its literal args filled in ('?' when an
    arg is not a literal), so `format('%s ROLE', 'RESET')` reads as `RESET ROLE`."""
    m = re.search(r"\bFORMAT\s*\(\s*'#([0-9]+)'", expr)
    if not m:
        return ""
    args = iter(strings[int(k)] for k in re.findall(r"'#([0-9]+)'", expr[m.end():]))
    return FORMAT_SPEC_RE.sub(lambda f: "%" if f.group(1) == "%" else next(args, "?"), strings[int(m.group(1))])


def _dynamic_errors(code: str, strings: list, here: str) -> list:
    """Role switches in plpgsql dynamic SQL (EXECUTE): every string piece of the statement, the
    pieces of each EXECUTE expression joined, and its format() text are linted as SQL, and a piece
    that is half of a role keyword is refused. The pieces of the whole statement are used because the
    SQL often reaches EXECUTE through a variable. Obfuscation (chr(), reverse(), decode()) is out of
    reach of a lint: the ownership post-check is the backstop."""
    executes = list(DYNAMIC_EXECUTE_RE.finditer(code))
    if not executes:
        return []
    candidates = list(strings) + ["".join(strings), " ".join(strings)]
    for m in executes:
        rest = code[m.end():]
        stop = EXPRESSION_END_RE.search(rest)
        expr = rest[:stop.start()] if stop else rest
        pieces = [strings[int(k)] for k in re.findall(r"'#([0-9]+)'", expr)]
        candidates += ["".join(pieces), " ".join(pieces), _format_text(expr, strings)]
    errors, switch, member = [], None, None
    for text in candidates:
        if not text.strip():
            continue
        sub: list = []
        view = _role_view(text, sub)
        if switch is None and (_switches(view, sub) or SWITCH_FRAGMENT_RE.search(text)):
            switch = text
        if member is None and re.match(r"\s*(GRANT|REVOKE)\b", view) and _membership_grants(view):
            member = text
    if switch is not None:
        errors.append(f"{here}: dynamic SQL {switch.strip()[:60]!r} switches or defines a role: not allowed "
                      f"in a migration (roles/ or a literal `SET LOCAL ROLE`)")
    if member is not None:
        errors.append(f"{here}: dynamic SQL {member.strip()[:60]!r} grants a role membership: "
                      f"belongs in db/migrations/roles/")
    return errors


def _deferral_errors(code: str, strings: list, here: str) -> list:
    """Work deferred to COMMIT (DEFERRAL_RES) in the statement or in its string literals, nested ones
    included: function and DO bodies written as '…' strings and dynamic SQL are not lexed as code
    otherwise. Each level's pieces are also read joined ('SET CONSTRAINTS ALL ' || 'DEFERRED')."""
    views, level = [code], strings
    for _ in range(3):                                   # string in a string in a string
        texts = [t for t in level + [" ".join(level)] if t.strip()]
        level = []
        for text in texts:
            views.append(_role_view(text, level))
    return [f"{here}: {why}" for rx, why in DEFERRAL_RES if any(rx.search(v) for v in views)]


def registration_error(sql: str) -> str:
    """'' when the last statement of a no-transaction file is a plain literal registration
    (REGISTRATION_RE). Under the role switch it runs in the runner's transaction, right before the
    post-check: a function call or subquery there could run code as the owner the check never sees
    a statement for (review S241, round 2)."""
    stmts = split_statements(sql)
    if stmts and REGISTRATION_RE.match(stmts[-1].code):
        return ""
    line = stmts[-1].line if stmts else 1
    return (f"line {line}: under the role switch the last statement of a no-transaction file must be a plain "
            f"`INSERT INTO shared.schema_versions [(version, …)] VALUES (<literals>) [ON CONFLICT (version) DO "
            f"NOTHING]`: string/number literals, NULL, DEFAULT, now() or CURRENT_TIMESTAMP only — no function "
            f"call, subquery or cast (X1)")


def _set_role_matches(code: str, strings: list) -> list:
    """[(position, scope, role name lower case)] of the SET [SESSION|LOCAL] ROLE statements of a code
    view; `UPDATE … SET role = …` (a column) is not one."""
    found = []
    for m in SET_ROLE_RE.finditer(code):
        segment = code[:m.start()].rsplit(";", 1)[-1]
        if re.search(r"\bUPDATE\b", segment):              # UPDATE … SET role = … (a column)
            continue
        raw = m.group(2) or ""
        name = strings[int(raw[2:-1])] if raw.startswith("'#") else raw.strip('"')
        found.append((m.start(), m.group(1), name.lower()))
    return found


def set_local_role_targets(sql: str) -> list:
    """Every role a file switches to with `SET LOCAL ROLE` (literal targets; the lint refuses the rest)."""
    names = set()
    for s in split_statements(sql):
        strings: list = []
        names.update(n for _p, scope, n in _set_role_matches(_role_view(s.text, strings), strings)
                     if scope == "LOCAL" and n)
    return sorted(names)


def role_lint(sql: str, owner_dir: str) -> list:
    """X1 role rules for one file of an owner dir (cis/, booking/, tripplanner/), plan S1 item 6."""
    allowed = OWNER_DIRS[owner_dir].set_local_roles
    allowed_txt = ", ".join(sorted(allowed)) or "none"
    errors = []
    current = None                         # the last SET LOCAL ROLE target, in file order
    open_grant = None                      # line of a catalog recipe GRANT CREATE not yet revoked (review S244)
    for s in split_statements(sql):
        strings: list = []
        code = _role_view(s.text, strings)
        here = f"line {s.line}"
        events = [(pos, "set", scope, name) for pos, scope, name in _set_role_matches(code, strings)]
        events += [(m.start(), "ddl", None, None) for m in CATALOG_VIEW_DDL_RE.finditer(code)]
        for _pos, what, scope, name in sorted(events, key=lambda e: e[0]):
            if what == "ddl":
                if current != "catalog_owner":
                    errors.append(f"{here}: DDL on a catalog.* view runs only as catalog_owner, after `SET LOCAL "
                                  f"ROLE catalog_owner` — {CATALOG_FREEZE}")
                continue
            if scope != "LOCAL":
                errors.append(f"{here}: `SET {scope + ' ' if scope else ''}ROLE` outlives the transaction: only "
                              f"`SET LOCAL ROLE` is allowed in a migration (X1)")
            elif name not in allowed:
                errors.append(f"{here}: `SET LOCAL ROLE {name or '?'}` is not allowed in {owner_dir}/ "
                              f"(allowed: {allowed_txt}; db/owners.yaml set_local_roles)")
            if scope == "LOCAL":
                current = name
        for rx, why in ROLE_SWITCH_RES:
            if rx.search(code):
                errors.append(f"{here}: {why}")
        for m in SET_CONFIG_RE.finditer(code):
            if m.group(1) is None:
                errors.append(f"{here}: set_config() whose parameter name is not a plain string literal: the "
                              f"lint cannot tell it is not 'role' — write the name as a literal")
            elif strings[int(m.group(1))].strip().lower() in ROLE_GUCS:
                errors.append(f"{here}: set_config('{strings[int(m.group(1))].strip()}', …) switches the role: "
                              f"not allowed in a migration")
        for g in _membership_grants(code):
            hint = f" — {CATALOG_FREEZE}" if re.search(r"\bCATALOG_OWNER\b", g) else ""
            errors.append(f"{here}: role membership `{g[:80]}` belongs in db/migrations/roles/ (DM-8.1){hint}")
        errors.extend(_dynamic_errors(code, strings, here))
        errors.extend(_deferral_errors(code, strings, here))
        if CATALOG_CREATE_GRANT_RE.search(code):
            open_grant = here
        if CATALOG_CREATE_REVOKE_RE.search(code):
            open_grant = None
    if open_grant:
        errors.append(f"{open_grant}: `GRANT CREATE ON SCHEMA catalog TO catalog_owner` is never revoked later in "
                      f"the file: the catalog recipe ends with `SET LOCAL ROLE cis_owner; REVOKE CREATE ON SCHEMA "
                      f"catalog FROM catalog_owner` (X1 S22), else catalog_owner keeps CREATE on schema catalog")
    return errors


def migration_path(path: str) -> tuple:
    """(dir, number) from a path ending in <dir>/<NNN>_name.sql, else (None, None)."""
    m = MIGRATION_PATH_RE.search(path.replace("\\", "/")) if path else None
    return (m.group(1), int(m.group(2))) if m else (None, None)


def lint(sql: str, d: Directives, path: str = None) -> tuple:
    """Returns (errors, warnings) for one migration file, given its parsed directives.

    With `path` (…/<dir>/<NNN>_name.sql) the X1 role lint runs too, for owner-dir files numbered at
    or above the dir's role_lint_from, plus the switch's shape rule: such a file is one BEGIN … COMMIT
    block, or a `-- migrate: no-transaction` file whose last statement is a plain literal registration."""
    errors, warnings = list(d.errors), []
    if BASELINE_MARKER in sql:
        errors.append(f"this is a schema drift replay baseline ({BASELINE_MARKER}, db/replay_baseline/): it only "
                      f"feeds db/replay_migrations.py and is never applied to a database (AA-853)")
    owner_dir, number = migration_path(path)
    if owner_dir in OWNER_DIRS and number >= OWNER_DIRS[owner_dir].role_lint_from:
        errors.extend(role_lint(sql, owner_dir))
        if d.no_transaction:
            reg_error = registration_error(sql)
            if reg_error:
                errors.append(reg_error)
        else:
            # It may run under the role switch (XD8), which needs one BEGIN … COMMIT block: caught
            # here, in the PR, instead of exit 8 at apply time.
            shape_error = transaction_parts(sql)[3]
            if shape_error:
                errors.append(f"{shape_error} (X1: a file above the {owner_dir}/ head may run under the role "
                              f"switch — SET LOCAL ROLE after BEGIN, ownership post-check before COMMIT)")
    stmts = split_statements(sql)
    for s in stmts:
        if (CONCURRENTLY_RE.search(s.code) and not TX_SAFE_CONCURRENTLY_RE.search(s.code)
                and not d.no_transaction):
            errors.append(f"line {s.line}: CONCURRENTLY cannot run inside a transaction — put it in its own "
                          f"file with `-- migrate: no-transaction` (MIG-10)")
        if NO_TX_ONLY_RE.search(s.code) and not d.no_transaction:
            errors.append(f"line {s.line}: VACUUM cannot run inside a transaction — put it in a file with "
                          f"`-- migrate: no-transaction` (MIG-10)")
        for rx, label in DESTRUCTIVE_RES:
            m = rx.search(s.code)
            if m and not d.destructive:
                what = label.format(*m.groups()) if m.groups() else label
                errors.append(f"line {s.line}: {what} needs the `-- migrate: destructive` header, so DB "
                              f"Migrate takes an RDS snapshot first (MIG-12)")
        if DELETE_RE.search(s.code) and not d.destructive:
            warnings.append(f"line {s.line}: DELETE in a migration — if it removes real data, add "
                            f"`-- migrate: destructive` (MIG-12); large deletes belong in a job (MIG-13)")
        if d.no_transaction and TX_CONTROL_RE.search(s.code):
            errors.append(f"line {s.line}: no-transaction file must not contain BEGIN/COMMIT/ROLLBACK "
                          f"(every statement runs on its own)")
    if d.no_transaction:
        if not stmts:
            errors.append("no-transaction file has no statements")
        elif "SHARED.SCHEMA_VERSIONS" not in stmts[-1].code:
            errors.append("no-transaction file must register its version in shared.schema_versions as "
                          "its LAST statement, so a failed run is retried instead of marked applied")
    if d.expand:
        errors.extend(expand_lint(sql, d, owner_dir))
    return errors, warnings


# ── AA-993 Phase E slice M2a: expand files (root ADR 0017 decisions 3-5) ──
# `-- migrate: expand` marks a file that only ADDS: new objects, a new nullable column (or one with a non-volatile,
# non-generated default) or a new non-unique index on an existing table. No header = contract (manual DB Migrate,
# MIG-4 unchanged). The static lint below refuses what the text shows; the runtime post-check (M2b, exit 14) will be
# the authority. Until M2b ships nothing applies expand files automatically (migration-apply.yml is M3).
EXPAND_STATEMENT_TIMEOUT = "30s"            # ADR 0017 d4: expand files, CREATE INDEX CONCURRENTLY excepted
EXPAND_MAX_STATEMENT_TIMEOUT_MS = 30_000
EXPAND_MAX_ROWS = 100_000                   # MIG-10: above this, a lock-taking statement is "lock risk -> contract"
# owners.yaml expand_hot_tables (db/tests/test_owners_registry.py keeps them equal). Running code reads these with
# SELECT * / RETURNING * inside transactions (critic 6): a changed row type breaks its prepared statements, so any
# statement naming one is contract, except a non-unique CREATE INDEX CONCURRENTLY (which waits for an open wave).
EXPAND_HOT_TABLES = ("acp_shared.acp_quota_ledger", "booking.job", "crm.job", "shared.job", "shared.job_worker")
EXPAND_HOT_SCHEMAS = ("catalog",)           # catalog.* (views over CIS base tables, consumed by every app)
EXPAND_VOLATILE_DEFAULT_RE = re.compile(
    r"\bDEFAULT\b.*\b(RANDOM|GEN_RANDOM_UUID|UUID_GENERATE_V[1-5]|CLOCK_TIMESTAMP|TIMEOFDAY|NEXTVAL|SETSEED)\s*\(")
EXPAND_ALLOWED_HEAD_RE = re.compile(
    r"^(BEGIN|START TRANSACTION|COMMIT|END|CREATE|ALTER TABLE|ALTER (FUNCTION|PROCEDURE|SEQUENCE|VIEW|TYPE|INDEX|"
    r"MATERIALIZED VIEW|DOMAIN)\b|GRANT|COMMENT ON|INSERT INTO|SET)\b")
CREATED_RE = re.compile(
    r"^CREATE (?:UNLOGGED |TEMP |TEMPORARY )?(?:UNIQUE )?(TABLE|VIEW|MATERIALIZED VIEW|SEQUENCE|TYPE|DOMAIN|FUNCTION|"
    r"PROCEDURE|INDEX|SCHEMA)(?: CONCURRENTLY)?(?: IF NOT EXISTS)? ([^\s(]+)")
CIC_RE = re.compile(r"^CREATE INDEX CONCURRENTLY IF NOT EXISTS ([^\s(]+) ON (?:ONLY )?([^\s(]+)")
INDEX_TARGET_RE = re.compile(r"^CREATE (UNIQUE )?INDEX (?:CONCURRENTLY )?(?:IF NOT EXISTS )?(?:[^\s(]+ )?ON (?:ONLY )?"
                             r"([^\s(]+)")
ALTER_TABLE_RE = re.compile(r"^ALTER TABLE (?:IF EXISTS )?(?:ONLY )?([^\s(*]+)\*? (.+)$")
ALTER_OTHER_RE = re.compile(r"^ALTER (?:FUNCTION|PROCEDURE|SEQUENCE|VIEW|TYPE|INDEX|MATERIALIZED VIEW|DOMAIN) "
                            r"(?:IF EXISTS )?([^\s(]+)")
ON_TARGET_RE = re.compile(r"^CREATE (?:OR REPLACE )?(?:CONSTRAINT )?(TRIGGER|POLICY|RULE) \S+ .*?\bON ([^\s(]+)")
WRITE_TARGET_RE = re.compile(r"^(?:WITH\b.*?\b)?(?:INSERT INTO|UPDATE(?: ONLY)?|DELETE FROM(?: ONLY)?|MERGE INTO) "
                             r"([^\s(]+)")
GRANT_ON_RE = re.compile(r"^GRANT .*? ON (?:(TABLE|SEQUENCE|FUNCTION|PROCEDURE|ROUTINE|TYPE|DOMAIN|SCHEMA|"
                         r"ALL TABLES IN SCHEMA|ALL SEQUENCES IN SCHEMA|ALL FUNCTIONS IN SCHEMA|ALL ROUTINES IN SCHEMA"
                         r"|DATABASE|LANGUAGE|FOREIGN [A-Z ]+?|LARGE OBJECT|TABLESPACE|PARAMETER) )?(.+?) TO (.+)$")
EXPAND_FORBIDDEN_RES = (
    (re.compile(r"\bCREATE OR REPLACE\b"), "CREATE OR REPLACE changes an existing definition when the object exists: "
     "use plain CREATE in an expand file (a replaced view or function is contract)"),
    (re.compile(r"\bALTER DEFAULT PRIVILEGES\b"), "ALTER DEFAULT PRIVILEGES changes grants of objects created later "
     "(contract)"),
    (re.compile(r"^REVOKE\b"), "REVOKE changes existing grants (contract)"),
    (re.compile(r"\bSET (?:LOCAL |SESSION )?ROLE (?:TO |= )?\"?CATALOG_OWNER\b"), "SET ROLE catalog_owner is the "
     "catalog.* recipe (contract)"),
    (re.compile(r"^CREATE EXTENSION\b"), "extensions belong to roles/ files (master), never an expand file"),
)


def _ident(tok: str) -> str:
    """Normalised object name from statement code (already upper case): quotes and a trailing `(` removed."""
    return tok.strip().rstrip("(").replace('"', "")


def _same_object(a: str, b: str) -> bool:
    if a == b:
        return True
    if "." in a and "." in b:
        return False
    return a.rsplit(".", 1)[-1] == b.rsplit(".", 1)[-1]


def _created(stmts: list) -> list:
    out = []
    for s in stmts:
        m = CREATED_RE.match(s.code)
        if m:
            out.append(_ident(m.group(2)))
    return out


def _is_new(name: str, created: list) -> bool:
    return any(_same_object(_ident(name), c) for c in created)


def _split_actions(text: str) -> list:
    """ALTER TABLE actions, split on top-level commas (numeric(10,2) stays one action)."""
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur).strip())
    return [p for p in parts if p]


def _add_column_error(action: str) -> str:
    """'' when `action` is an expand-safe ADD COLUMN on an existing table, else why it is not."""
    if re.match(r"^ADD (CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE)\b", action) or not action.startswith("ADD "):
        return "only ADD COLUMN is expand on an existing table (constraints, RLS flags, owners, defaults, types, " \
               "renames and drops are contract)"
    for word, why in (("GENERATED", "a GENERATED column rewrites the table"),
                      ("REFERENCES", "an FK added to an existing table is contract (validation scans and locks)"),
                      ("PRIMARY KEY", "a key on an existing table is contract"),
                      ("UNIQUE", "a unique column on an existing table is contract"),
                      ("CHECK", "a CHECK on an existing table is contract"),
                      ("COLLATE", "a collated column add is reviewed as contract")):
        if re.search(rf"\b{word}\b", action):
            return why
    if re.search(r"\bNOT NULL\b", action) and not re.search(r"\bDEFAULT\b", action):
        return "a NOT NULL column without a default fails on existing rows (contract)"
    if re.search(r"\b(SMALL|BIG)?SERIAL[248]?\b", action):
        return "a serial column adds a nextval() default, which rewrites the table (contract)"
    if EXPAND_VOLATILE_DEFAULT_RE.search(action):
        return "a volatile default rewrites the table (contract)"
    return ""


EXPAND_SET_RE = re.compile(r"^SET (?:LOCAL |SESSION )?([A-Z_]+)\b")


def _expand_set_error(s) -> str:
    """'' when a SET in a transactional expand file is allowed: ROLE (catalog_owner is refused separately),
    search_path, and lock_timeout / statement_timeout between 1 ms and EXPAND_STATEMENT_TIMEOUT. A body SET must not
    undo the 30 s cap (ADR 0017 d4) or disable a timeout (0), and nothing else is set (session_replication_role …)."""
    m = EXPAND_SET_RE.match(s.code)
    name = m.group(1) if m else ""
    if name in ("ROLE", "SEARCH_PATH"):
        return ""
    if name in ("LOCK_TIMEOUT", "STATEMENT_TIMEOUT"):
        v = re.search(rf"(?i)\b{name}\s*(?:=|\bTO\b)\s*'?\s*([0-9]+\s*[a-z]*)\s*'?", s.text)
        ms = _duration_ms(v.group(1).replace(" ", "").lower()) if v else float("inf")
        if 0 < ms <= EXPAND_MAX_STATEMENT_TIMEOUT_MS:
            return ""
        return (f"SET {name.lower()} in an expand file must be between 1ms and {EXPAND_STATEMENT_TIMEOUT} "
                f"(0 disables it; a slower statement is contract)")
    return (f"SET {name.lower() or '…'} is not allowed in an expand file (allowed: SET [LOCAL] ROLE, search_path, "
            f"lock_timeout / statement_timeout up to {EXPAND_STATEMENT_TIMEOUT})")


def names_hot_table(code: str) -> str:
    """The first hot table (or hot schema) a statement names, '' when none."""
    for t in EXPAND_HOT_TABLES:
        sch, rel = t.upper().split(".")
        if re.search(rf'(?<![A-Z0-9_$."]){sch}"?\s*\.\s*"?{rel}(?![A-Z0-9_$"])', code):
            return t
    for sch in EXPAND_HOT_SCHEMAS:
        if re.search(rf'(?<![A-Z0-9_$."]){sch.upper()}"?\s*\.', code):
            return f"{sch}.*"
    return ""


def _duration_ms(raw: str) -> float:
    m = re.match(r"^([0-9]+)(us|ms|s|min|h|d)?$", raw)
    if not m:
        return float("inf")
    n, unit = int(m.group(1)), m.group(2) or "ms"
    return n * {"us": 0.001, "ms": 1, "s": 1000, "min": 60_000, "h": 3_600_000, "d": 86_400_000}[unit]


def expand_lint(sql: str, d: "Directives", owner_dir: str = None) -> list:
    """Errors for a `-- migrate: expand` file (ADR 0017 d3 static part). The file still passes every normal lint."""
    errors = []
    if d.destructive:
        errors.append("`-- migrate: expand` and `-- migrate: destructive` exclude each other")
    if owner_dir not in OWNER_DIRS:
        errors.append(f"`-- migrate: expand` is only for owner dirs ({', '.join(sorted(OWNER_DIRS))}); "
                      f"{owner_dir or 'this path'} files are applied by hand")
    if not d.no_transaction and transaction_parts(sql)[3]:
        # M2b: the runtime post-check runs between the file's BEGIN and COMMIT, so it needs exactly that shape.
        errors.append(f"an expand file is one BEGIN … COMMIT block (the post-check runs inside it): "
                      f"{transaction_parts(sql)[3]}")
    stmts = split_statements(sql)
    created = _created(stmts)
    grant_roles = OWNER_DIRS[owner_dir].grant_roles if owner_dir in OWNER_DIRS else frozenset()
    reg = len(stmts) - 1 if stmts and "SHARED.SCHEMA_VERSIONS" in stmts[-1].code else None
    if reg is None:
        # A transactional file registers before COMMIT.
        for k in range(len(stmts) - 1, -1, -1):
            if "SHARED.SCHEMA_VERSIONS" in stmts[k].code:
                reg = k
                break
    for k, s in enumerate(stmts):
        code, here = s.code, f"line {s.line}"
        if k == reg or TX_CONTROL_RE.search(code):
            continue
        if d.no_transaction:
            m = CIC_RE.match(code)
            if not m:
                errors.append(f"{here}: an expand no-transaction file holds only non-unique `CREATE INDEX CONCURRENTLY "
                              f"IF NOT EXISTS` statements and its registration")
            continue
        if not EXPAND_ALLOWED_HEAD_RE.match(code):
            head = " ".join(code.split()[:2])
            errors.append(f"{here}: `{head}` is not allowed in an expand file (allowed: CREATE, ALTER TABLE … ADD "
                          f"COLUMN, GRANT and COMMENT on new objects, INSERT into a table the file creates, SET); "
                          f"DO blocks and SELECT calls are opaque to the lint: drop the expand header")
            continue
        for rx, why in EXPAND_FORBIDDEN_RES:
            if rx.search(code):
                errors.append(f"{here}: {why}")
        if code.startswith("SET "):
            why = _expand_set_error(s)
            if why:
                errors.append(f"{here}: {why}")
            continue
        hot = names_hot_table(code)
        if hot:
            errors.append(f"{here}: names hot table {hot} (owners.yaml expand_hot_tables: running code reads it with "
                          f"SELECT * / RETURNING * inside transactions); only a non-unique CREATE INDEX CONCURRENTLY "
                          f"may name it, in its own no-transaction file")
            continue
        m = WRITE_TARGET_RE.match(code)
        if m and not _is_new(m.group(1), created):
            errors.append(f"{here}: writes rows of {_ident(m.group(1)).lower()}, a table this file does not create "
                          f"(config and routing rows included: contract)")
            continue
        m = ALTER_TABLE_RE.match(code)
        if m:
            if not _is_new(m.group(1), created):
                for action in _split_actions(m.group(2)):
                    why = _add_column_error(action)
                    if why:
                        errors.append(f"{here}: ALTER TABLE {_ident(m.group(1)).lower()}: {why}")
            continue
        m = ALTER_OTHER_RE.match(code)
        if m and not _is_new(m.group(1), created):
            errors.append(f"{here}: alters {_ident(m.group(1)).lower()}, an object this file does not create (contract)")
            continue
        m = INDEX_TARGET_RE.match(code)
        if m and m.group(1) and not _is_new(m.group(2), created):
            errors.append(f"{here}: a UNIQUE index on an existing table breaks old-code writes (contract)")
            continue
        m = ON_TARGET_RE.match(code)
        if m and not _is_new(m.group(2), created):
            errors.append(f"{here}: a new {m.group(1).lower()} on {_ident(m.group(2)).lower()}, a table this file does "
                          f"not create, changes how existing rows are read or written (contract)")
            continue
        if code.startswith("GRANT "):
            g = GRANT_ON_RE.match(code)
            if not g:
                errors.append(f"{here}: role membership grants belong to roles/ files (contract)")
                continue
            kind, objs, grantees = g.group(1) or "", g.group(2), g.group(3)
            if "SCHEMA" in kind or kind in ("DATABASE", "LANGUAGE", "TABLESPACE", "PARAMETER", "LARGE OBJECT") \
                    or kind.startswith("FOREIGN"):
                errors.append(f"{here}: GRANT ON {kind} changes an existing object's grants (contract)")
                continue
            for o in _split_actions(objs):
                if not _is_new(o, created):
                    errors.append(f"{here}: GRANT on {_ident(o).lower()}, an object this file does not create (contract)")
            roles = [r.strip().replace('"', "").lower() for r in
                     re.split(r",", re.sub(r"\s+WITH GRANT OPTION.*$|\s+GRANTED BY .*$", "", grantees))]
            for r in roles:
                if r not in grant_roles:
                    errors.append(f"{here}: GRANT TO {r}: an expand file grants only to the {owner_dir or '?'} owner's "
                                  f"runtime / nologin roles in owners.yaml ({', '.join(sorted(grant_roles)) or 'none'})")
    for key in ("statement_timeout", "lock_timeout"):
        # 0 disables the timeout (an ACCESS EXCLUSIVE wait without lock_timeout queues every reader behind it).
        if not d.no_transaction and key in d.explicit \
                and not 0 < _duration_ms(d.settings[key]) <= EXPAND_MAX_STATEMENT_TIMEOUT_MS:
            errors.append(f"{key}={d.settings[key]}: an expand file runs with a {key} between 1ms and "
                          f"{EXPAND_STATEMENT_TIMEOUT} (ADR 0017 d4); a slower statement is contract")
    return errors


def lock_risk_targets(sql: str, d: "Directives") -> list:
    """(table, what) pairs the pre-execution size check reads: every existing table an expand file takes a lock on
    by ALTER TABLE (ACCESS EXCLUSIVE) or a non-concurrent CREATE INDEX (SHARE). Tables the file creates are empty."""
    stmts = split_statements(sql)
    created = _created(stmts)
    out = []
    for s in stmts:
        m = ALTER_TABLE_RE.match(s.code)
        if m and not _is_new(m.group(1), created):
            out.append((_ident(m.group(1)).lower(), "ALTER TABLE (ACCESS EXCLUSIVE lock)"))
            continue
        m = INDEX_TARGET_RE.match(s.code)
        if m and not CIC_RE.match(s.code) and "CONCURRENTLY" not in s.code.split(" ON ", 1)[0] \
                and not _is_new(m.group(2), created):
            out.append((_ident(m.group(2)).lower(), "CREATE INDEX without CONCURRENTLY (SHARE lock for the build)"))
    return out


# reltuples is -1 until the first VACUUM / ANALYZE (PostgreSQL 14+), and a partitioned parent has no rows of its own
# (autovacuum never analyzes it): -1 = unknown and not empty (lock risk), a parent = the sum of its leaf partitions.
RELTUPLES_SQL = (
    "SELECT CASE WHEN c.relkind = 'p' THEN ("
    "SELECT CASE WHEN bool_or(l.reltuples < 0 AND pg_catalog.pg_relation_size(l.oid) > 0) THEN -1 "
    "ELSE COALESCE(sum(GREATEST(l.reltuples, 0)), 0) END::bigint "
    "FROM pg_catalog.pg_partition_tree(c.oid) t JOIN pg_catalog.pg_class l ON l.oid = t.relid WHERE t.isleaf) "
    "WHEN c.reltuples >= 0 THEN c.reltuples::bigint "
    "WHEN pg_catalog.pg_relation_size(c.oid) = 0 THEN 0 ELSE -1 END "
    "FROM pg_catalog.pg_class c "
    "WHERE c.oid = pg_catalog.to_regclass($1) AND c.relkind IN ('r', 'p', 'm')")
REL_EXISTS_SQL = "SELECT pg_catalog.to_regclass($1) IS NOT NULL"
IFNE_REL_RE = re.compile(r"^CREATE (?:UNLOGGED |TEMP |TEMPORARY )?(?:TABLE|SEQUENCE|MATERIALIZED VIEW) IF NOT EXISTS "
                         r"([^\s(]+)")
IFNE_INDEX_RE = re.compile(r"^CREATE (?:UNIQUE )?INDEX IF NOT EXISTS ([^\s(]+) ON (?:ONLY )?([^\s(]+)")


def if_not_exists_relations(sql: str, d: "Directives") -> list:
    """Relations a transactional expand file creates with IF NOT EXISTS (lower case; an index qualified with its
    table's schema). The lint treats them as new, so ALTER / GRANT / INSERT / policies on them pass; if one already
    exists the CREATE is a no-op and those statements change an existing object."""
    if d.no_transaction:
        return []               # CIC files: the index validity check covers IF NOT EXISTS (exit 16)
    out = []
    for s in split_statements(sql):
        m = IFNE_REL_RE.match(s.code)
        if m:
            out.append(_ident(m.group(1)).lower())
            continue
        m = IFNE_INDEX_RE.match(s.code)
        if m:
            index, table = _ident(m.group(1)).lower(), _ident(m.group(2)).lower()
            out.append(f"{table.rsplit('.', 1)[0]}.{index}" if "." not in index and "." in table else index)
    return out


async def lock_risk_findings(conn, sql: str, d: "Directives") -> list:
    """ADR 0017 d4: read the size of every table an expand file locks, BEFORE any statement runs. A table above
    EXPAND_MAX_ROWS (pg_class.reltuples, the planner estimate) is lock risk -> contract (exit 15)."""
    found = []
    for table, what in lock_risk_targets(sql, d):
        rows = await conn.fetchval(RELTUPLES_SQL, table)
        if rows is not None and rows < 0:
            found.append(f"{table}: row count unknown (never vacuumed or analyzed; ANALYZE it first), {what}")
        elif rows is not None and rows > EXPAND_MAX_ROWS:
            found.append(f"{table}: ~{rows} rows > {EXPAND_MAX_ROWS}, {what}")
    for rel in if_not_exists_relations(sql, d):
        if await conn.fetchval(REL_EXISTS_SQL, rel):
            found.append(f"{rel} already exists: its CREATE … IF NOT EXISTS is a no-op, so the file's later statements "
                         f"on it would change an existing object (contract)")
    return found


INDEX_VALID_SQL = ("SELECT i.indisvalid FROM pg_catalog.pg_index i "
                   "WHERE i.indexrelid = pg_catalog.to_regclass($1)")


def cic_index_names(stmts: list) -> list:
    """schema-qualified (when the table is) lower-case names of the indexes the CIC statements build."""
    out = []
    for s in stmts:
        m = CIC_RE.match(s.code)
        if m:
            index, table = _ident(m.group(1)).lower(), _ident(m.group(2)).lower()
            if "." not in index and "." in table:
                index = f"{table.rsplit('.', 1)[0]}.{index}"
            out.append(index)
    return out


async def invalid_cic_indexes(conn, stmts: list) -> list:
    """ADR 0017 d4: after the CIC statements of an expand no-transaction file, every index they name must exist and be
    valid; `IF NOT EXISTS` silently skips an INVALID index left by an earlier failed build (critic 5)."""
    bad = []
    for name in cic_index_names(stmts):
        valid = await conn.fetchval(INDEX_VALID_SQL, name)
        if valid is not True:
            bad.append(f"{name} ({'missing' if valid is None else 'INVALID'})")
    return bad


# ── AA-993 Phase E slice M2b: the expand runtime post-check (root ADR 0017 d3, exit 14) ──
# The static lint above refuses what the text shows; this is the authority. Inside the file's own transaction the runner
# snapshots the catalog of every non-system schema (objects owned by the owner role included: OBJECTS_SQL keys on
# owners and drops those, so it is not reused) before and after the body, plus the transaction's row counters
# (pg_stat_xact_user_tables), and diffs them against the allowed set. Anything else rolls the file back with exit 14.
# The same code runs in check mode as a rehearsal (the body, the post-check, then ROLLBACK) and in db/expand_check.py
# --classify against a replayed CI PostgreSQL. It lives in this file because DB Migrate ships this one file to the task.
# owners.yaml expand_rls_schemas (test_owners_registry keeps them equal): a new table there must ENABLE and FORCE RLS.
# A new table with a tenant_id column needs both in any schema (RLS catalogue rule a).
EXPAND_RLS_SCHEMAS = ("crm",)
EXPAND_REGISTRY_TABLE = "shared.schema_versions"      # the file's own registration: the one existing table it writes


# One row per object: (kind, key, rel, value, aux). `value` is what must not change on an existing object (fields
# joined by '|', names in EXPAND_FIELDS), `rel` the relation a column / index / constraint / policy / trigger / rule
# belongs to, `aux` what the allowed-change rules read. Definitions are md5'd: a changed view or function shows as a
# changed hash. Every pg_get_*def call depends on search_path, so expand_snapshot pins it around the query.
def _fields(*exprs: str) -> str:
    """SQL text joining the expressions with '|' (NULL as ''), so every field keeps its position (concat_ws would
    drop NULLs and shift the names of EXPAND_FIELDS)."""
    return "pg_catalog.array_to_string(ARRAY[" + ", ".join(f"({e})::text" for e in exprs) + "], '|', '')"


EXPAND_SNAPSHOT_SQL = f"""
WITH ns AS (
  SELECT n.oid, n.nspname::text AS nsp FROM pg_catalog.pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp_)'),
rel AS (
  SELECT c.oid, ns.nsp || '.' || c.relname::text AS name FROM pg_catalog.pg_class c JOIN ns ON ns.oid = c.relnamespace)
SELECT 'schema'::text AS kind, ns.nsp AS key, NULL::text AS rel,
       {_fields("pg_catalog.pg_get_userbyid(n.nspowner)", "n.nspacl")} AS value, NULL::text AS aux
  FROM ns JOIN pg_catalog.pg_namespace n ON n.oid = ns.oid
UNION ALL
SELECT 'relation', r.name, r.name,
       {_fields("c.relkind", "pg_catalog.pg_get_userbyid(c.relowner)", "c.relacl", "c.relrowsecurity",
                "c.relforcerowsecurity", "c.relfilenode", "c.reloptions", "c.relpersistence", "c.relispartition",
                "SELECT pg_catalog.concat_ws(',', s.seqtypid, s.seqincrement, s.seqmin, s.seqmax, s.seqstart, "
                "s.seqcycle) FROM pg_catalog.pg_sequence s WHERE s.seqrelid = c.oid",
                "CASE WHEN c.relkind IN ('v', 'm') THEN pg_catalog.md5(pg_catalog.pg_get_viewdef(c.oid)) END")},
       {_fields("c.relkind", "c.relrowsecurity", "c.relforcerowsecurity",
                "EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = c.oid "
                "AND a.attname = 'tenant_id' AND NOT a.attisdropped)",
                "SELECT p.name FROM pg_catalog.pg_inherits i JOIN rel p ON p.oid = i.inhparent "
                "WHERE i.inhrelid = c.oid ORDER BY p.name LIMIT 1")}
  FROM rel r JOIN pg_catalog.pg_class c ON c.oid = r.oid WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
UNION ALL
SELECT 'column', r.name || '.' || a.attname::text, r.name,
       {_fields("pg_catalog.format_type(a.atttypid, a.atttypmod)", "a.attnotnull",
                "pg_catalog.md5(pg_catalog.pg_get_expr(d.adbin, d.adrelid))", "a.attgenerated", "a.attidentity",
                "a.attcollation", "a.attacl")},
       {_fields("a.attnotnull", "d.adbin IS NOT NULL", "a.attgenerated <> ''", "a.attidentity <> ''")}
  FROM rel r JOIN pg_catalog.pg_class c ON c.oid = r.oid
  JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'c')
UNION ALL
SELECT 'index', ir.name, tr.name,
       {_fields("pg_catalog.md5(pg_catalog.pg_get_indexdef(i.indexrelid))", "i.indisunique", "i.indisprimary",
                "i.indisexclusion")},
       (i.indisunique OR i.indisprimary OR i.indisexclusion)::text
  FROM pg_catalog.pg_index i JOIN rel ir ON ir.oid = i.indexrelid JOIN rel tr ON tr.oid = i.indrelid
UNION ALL
SELECT 'constraint', COALESCE(tr.name, ns.nsp || '.' || t.typname::text) || ':' || co.conname::text,
       COALESCE(tr.name, ns.nsp || '.' || t.typname::text),
       {_fields("co.contype", "pg_catalog.md5(pg_catalog.pg_get_constraintdef(co.oid))", "co.convalidated",
                "co.condeferrable", "co.condeferred")},
       co.contype::text
  FROM pg_catalog.pg_constraint co JOIN ns ON ns.oid = co.connamespace
  LEFT JOIN rel tr ON tr.oid = co.conrelid LEFT JOIN pg_catalog.pg_type t ON t.oid = co.contypid
 WHERE co.conrelid <> 0 OR co.contypid <> 0
UNION ALL
SELECT 'policy', r.name || ':' || p.polname::text, r.name,
       {_fields("p.polcmd", "p.polpermissive", "p.polroles",
                "pg_catalog.md5(pg_catalog.pg_get_expr(p.polqual, p.polrelid))",
                "pg_catalog.md5(pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid))")},
       NULL
  FROM pg_catalog.pg_policy p JOIN rel r ON r.oid = p.polrelid
UNION ALL
SELECT 'trigger', r.name || ':' || t.tgname::text, r.name,
       {_fields("pg_catalog.md5(pg_catalog.pg_get_triggerdef(t.oid))", "t.tgenabled")}, NULL
  FROM pg_catalog.pg_trigger t JOIN rel r ON r.oid = t.tgrelid WHERE NOT t.tgisinternal
UNION ALL
SELECT 'rule', r.name || ':' || w.rulename::text, r.name, pg_catalog.md5(pg_catalog.pg_get_ruledef(w.oid)), NULL
  FROM pg_catalog.pg_rewrite w JOIN rel r ON r.oid = w.ev_class WHERE w.rulename <> '_RETURN'
UNION ALL
SELECT 'function',
       ns.nsp || '.' || p.proname::text || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')', NULL,
       {_fields("pg_catalog.pg_get_userbyid(p.proowner)", "p.proacl",
                "pg_catalog.md5(CASE WHEN p.prokind = 'a' THEN p.prosrc ELSE pg_catalog.pg_get_functiondef(p.oid) END)",
                "p.prosecdef", "p.proconfig", "p.provolatile", "p.proleakproof")},
       ns.nsp || '.' || p.proname::text
  FROM pg_catalog.pg_proc p JOIN ns ON ns.oid = p.pronamespace
UNION ALL
SELECT 'type', ns.nsp || '.' || t.typname::text, NULL,
       {_fields("t.typtype", "pg_catalog.pg_get_userbyid(t.typowner)", "t.typacl", "t.typbasetype", "t.typnotnull",
                "pg_catalog.md5(t.typdefault)",
                "SELECT pg_catalog.string_agg(e.enumlabel::text, ',' ORDER BY e.enumsortorder) "
                "FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid")},
       NULL
  FROM pg_catalog.pg_type t JOIN ns ON ns.oid = t.typnamespace WHERE t.typrelid = 0 AND t.typcategory <> 'A'
UNION ALL
SELECT 'default privileges',
       'for ' || pg_catalog.pg_get_userbyid(d.defaclrole) || ' in ' || COALESCE(n.nspname::text, '(all schemas)')
         || ' on ' || d.defaclobjtype::text,
       NULL, d.defaclacl::text, NULL
  FROM pg_catalog.pg_default_acl d LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
UNION ALL
SELECT 'rows', s.schemaname::text || '.' || s.relname::text, s.schemaname::text || '.' || s.relname::text,
       {_fields("s.n_tup_ins", "s.n_tup_upd", "s.n_tup_del")}, NULL
  FROM pg_catalog.pg_stat_xact_user_tables s
"""
EXPAND_FIELDS = {
    "schema": ("owner", "grants"),
    "relation": ("kind", "owner", "grants", "RLS enabled", "RLS forced", "storage (relfilenode: a table rewrite)",
                 "options", "persistence", "partition flag", "sequence parameters", "view definition"),
    "column": ("type", "NOT NULL", "default", "generated", "identity", "collation", "column grants"),
    "index": ("definition", "unique", "primary", "exclusion"),
    "constraint": ("type", "definition", "validated", "deferrable", "deferred"),
    "policy": ("command", "permissive", "roles", "USING", "WITH CHECK"),
    "trigger": ("definition", "enabled"),
    "rule": ("definition",),
    "function": ("owner", "grants", "definition", "security definer", "settings", "volatility", "leakproof"),
    "type": ("type", "owner", "grants", "base type", "NOT NULL", "default", "enum labels"),
    "default privileges": ("grants",),
}
SEARCH_PATH_GET_SQL = "SELECT pg_catalog.current_setting('search_path')"
SEARCH_PATH_SET_SQL = "SELECT pg_catalog.set_config('search_path', $1, $2)"
EXPAND_PINNED_PATH = "pg_catalog, pg_temp"


async def expand_snapshot(conn, in_transaction: bool = True) -> list:
    """The catalog rows of EXPAND_SNAPSHOT_SQL as plain dicts, read with a pinned search_path (the pg_get_*def output
    qualifies names by it) and the caller's search_path put back after."""
    old = await conn.fetchval(SEARCH_PATH_GET_SQL)
    await conn.fetchval(SEARCH_PATH_SET_SQL, EXPAND_PINNED_PATH, in_transaction)
    try:
        return [{k: r[k] for k in ("kind", "key", "rel", "value", "aux")}
                for r in await conn.fetch(EXPAND_SNAPSHOT_SQL)]
    finally:
        if old is not None:
            await conn.fetchval(SEARCH_PATH_SET_SQL, old, in_transaction)


def _changed_fields(kind: str, old: str, new: str) -> str:
    names = EXPAND_FIELDS.get(kind, ())
    a, b = (old or "").split("|"), (new or "").split("|")
    if len(a) != len(b) or len(a) != len(names):
        return "definition"
    return ", ".join(n for n, x, y in zip(names, a, b) if x != y) or "definition"


def _flag(aux: str, i: int) -> bool:
    parts = (aux or "").split("|")
    return len(parts) > i and parts[i] in ("true", "t")


def _rows(value: str) -> tuple:
    try:
        return tuple(int(x) for x in (value or "0|0|0").split("|"))
    except ValueError:
        return (0, 0, 0)


def expand_findings(before: list, after: list, hot_tables=EXPAND_HOT_TABLES, hot_schemas=EXPAND_HOT_SCHEMAS,
                    rls_schemas=EXPAND_RLS_SCHEMAS, registry=EXPAND_REGISTRY_TABLE) -> list:
    """Pure: what an expand file changed outside the allowed set (ADR 0017 d3), as sorted one-line findings naming
    the object. `before` / `after` are expand_snapshot() rows taken around the body, inside its transaction.

    Allowed: new objects (schemas, tables, views, sequences, types, functions that are neither an overload nor
    SECURITY DEFINER, indexes, constraints / policies / triggers on new tables); on an existing table a new column that
    is nullable or has a
    default and is neither generated nor identity (a volatile default rewrites the table and shows as a changed
    relfilenode), a non-unique index, and the internal RI triggers a new table's FK adds (not snapshotted); rows
    written to tables the file creates and at most one row inserted into the registry
    (shared.schema_versions: its own registration; no update or delete there). Everything else
    is contract: any change to or removal of an existing object, a new policy / trigger / constraint / rule / unique
    index on an existing table, an overload, a new SECURITY DEFINER function, a new partition of an existing table, default privileges, a new
    column on a hot table, anything new in a hot schema, a new table that needs RLS without ENABLE + FORCE, and rows
    inserted, updated or deleted in an existing table."""
    b = {(r["kind"], r["key"]): r for r in before}
    a = {(r["kind"], r["key"]): r for r in after}
    old_rels = {key: r for (kind, key), r in b.items() if kind == "relation"}
    old_types = {key for (kind, key) in b if kind == "type"}
    old_fn_names = {r["aux"] for (kind, _), r in b.items() if kind == "function"}
    hot = {t.lower() for t in hot_tables}
    hot_ns = {s.lower() for s in hot_schemas}

    def is_hot(name: str) -> bool:
        return bool(name) and (name.lower() in hot or name.split(".", 1)[0].lower() in hot_ns)

    found = []
    for (kind, key), r in b.items():
        if kind == "rows":
            continue
        now = a.get((kind, key))
        if now is None:
            found.append(f"{kind} {key}: dropped or renamed")
        elif now["value"] != r["value"]:
            found.append(f"{kind} {key}: {_changed_fields(kind, r['value'], now['value'])} changed")
    for (kind, key), r in a.items():
        rel = r["rel"] or ""
        if kind == "rows":
            delta = [x - y for x, y in zip(_rows(r["value"]), _rows((b.get((kind, key)) or {}).get("value")))]
            if rel == registry:
                # Review S256: the expand lint skips the registration statement, so a CTE there (WITH d AS (DELETE
                # FROM shared.schema_versions …) INSERT …) could unregister another key; the file adds its own row.
                if delta[0] > 1 or delta[1] or delta[2]:
                    found.append(f"rows of the registry {rel}: {delta[0]} inserted, {delta[1]} updated, "
                                 f"{delta[2]} deleted (an expand file only inserts its own registration)")
            elif rel in old_rels:
                if any(delta):
                    found.append(f"rows of existing table {rel}: {delta[0]} inserted, {delta[1]} updated, "
                                 f"{delta[2]} deleted (config and routing rows included: contract)")
            continue
        if (kind, key) in b:
            continue
        on_old = rel in old_rels
        if kind == "column" and on_old:
            relkind = (old_rels[rel]["aux"] or "").split("|")[0]
            if relkind not in ("r", "p"):
                found.append(f"column {key}: added to an existing {relkind or '?'}-kind relation (not a table)")
            elif is_hot(rel):
                found.append(f"column {key}: added to hot table {rel} (running code reads it with SELECT * / "
                             f"RETURNING *: owners.yaml expand_hot_tables)")
            elif _flag(r["aux"], 2) or _flag(r["aux"], 3):
                found.append(f"column {key}: generated or identity column on an existing table")
            elif _flag(r["aux"], 0) and not _flag(r["aux"], 1):
                found.append(f"column {key}: NOT NULL without a default on an existing table")
        elif kind == "index" and on_old:
            if r["aux"] in ("true", "t"):
                found.append(f"index {key}: unique / primary / exclusion index on existing table {rel}")
        elif kind in ("constraint", "policy", "trigger", "rule") and (on_old or (kind == "constraint"
                                                                                 and rel in old_types)):
            found.append(f"{kind} {key}: new {kind} on existing {'table' if on_old else 'type'} {rel}")
        elif kind == "function" and r["aux"] in old_fn_names:
            found.append(f"function {key}: overload of an existing function name {r['aux']}")
        elif kind == "function" and _flag(r["value"], 3):
            # Review S256: a new SECURITY DEFINER function runs with its owner's rights (the owner role's own RLS
            # policy, e.g. USING (true)) and EXECUTE is granted to PUBLIC by default: an RLS bypass needs a review.
            found.append(f"function {key}: new SECURITY DEFINER function (runs with its owner's rights; EXECUTE is "
                         f"PUBLIC by default): contract")
        elif kind == "default privileges":
            found.append(f"default privileges {key}: added (ALTER DEFAULT PRIVILEGES)")
        elif kind == "relation":
            aux = (r["aux"] or "").split("|")
            relkind, parent = aux[0], (aux[4] if len(aux) > 4 else "")
            if is_hot(key):
                found.append(f"relation {key}: new object in hot schema {key.split('.', 1)[0]} (catalog recipe)")
            elif parent and parent in old_rels:
                found.append(f"relation {key}: new partition or child of existing table {parent}")
            elif relkind in ("r", "p") and not parent and (key.split(".", 1)[0] in rls_schemas or _flag(r["aux"], 3)) \
                    and not (_flag(r["aux"], 1) and _flag(r["aux"], 2)):
                why = "has a tenant_id column" if _flag(r["aux"], 3) else "in an RLS schema (expand_rls_schemas)"
                found.append(f"relation {key}: new table {why} without ENABLE and FORCE ROW LEVEL SECURITY")
        elif kind in ("index", "constraint", "policy", "trigger", "rule", "column") and is_hot(rel):
            found.append(f"{kind} {key}: new object in hot schema (catalog recipe)")
    return sorted(set(found))


def _log_expand(found: list, rehearse: bool) -> None:
    shown = found[:40]
    more = f" (+{len(found) - len(shown)} more)" if len(found) > len(shown) else ""
    log(f"ERROR: expand file changed an existing object: {'; '.join(shown)}{more}. "
        f"{'Rehearsal rolled back' if rehearse else 'Rolled back, the version is NOT registered'}: drop the "
        f"`-- migrate: expand` header (contract: migration-only PR, manual DB Migrate apply) or change the file")


async def run_expand_transaction(conn, sql: str, rehearse: bool = False, report: list = None) -> int:
    """Plain path (no role switch) of a transactional expand file: the file's BEGIN, snapshot, body, snapshot,
    post-check, then its COMMIT, or ROLLBACK with exit 14. rehearse=True always rolls back (check mode, classify)."""
    begin, body, commit, _ = transaction_parts(sql)
    await conn.execute(begin.text)
    before = await expand_snapshot(conn)
    if body:
        await conn.execute("\n".join(s.text for s in body))
    found = expand_findings(before, await expand_snapshot(conn))
    if report is not None:
        report.extend(found)
    if found or rehearse:
        await conn.execute("ROLLBACK")
        if found:
            _log_expand(found, rehearse)
            return 14
        log("expand rehearsal: post-check ok (no existing object changed), rolled back")
        return 0
    log("expand post-check: ok (no existing object changed)")
    await conn.execute(commit.text)
    return 0


# One session-level advisory lock for every applying mode (apply, roles/ files, set-password, run-script that is not
# READ_ONLY): an auto-apply (M3) and a person's DB Migrate run never overlap (ADR 0017 d5, critic 11). Two-int form,
# so it cannot collide with the single-bigint advisory keys the apps use. Released when the task's connection closes.
APPLY_LOCK_SQL = "SELECT pg_catalog.pg_try_advisory_lock(993, 1)"
APPLY_LOCK_WAIT_S = 25 * 60                 # under DB Migrate's 30-minute task wait
APPLY_LOCK_POLL_S = 15


async def take_apply_lock(conn, sleep, what: str) -> bool:
    waited = 0
    while True:
        if await conn.fetchval(APPLY_LOCK_SQL):
            log(f"apply lock: taken ({what}{f', after {waited} s' if waited else ''})")
            return True
        if waited >= APPLY_LOCK_WAIT_S:
            log(f"ERROR: apply lock: another DB Migrate or auto-apply run still holds it after {waited} s; nothing "
                f"ran. Re-run when that run has finished")
            return False
        if not waited:
            log(f"apply lock: held by another DB Migrate or auto-apply run; waiting up to {APPLY_LOCK_WAIT_S} s")
        await sleep(APPLY_LOCK_POLL_S)
        waited += APPLY_LOCK_POLL_S


async def wait_for_waves(conn, sleep, attempts=IDLE_WAITS, interval_s=IDLE_WAIT_S) -> list:
    """Q5: an expand file that names a hot table waits only for open waves (job tables do not matter)."""
    report = await job_tables_busy(conn)
    for _ in range(attempts):
        if not any(st.is_wave and st.busy for st in report):
            break
        await sleep(interval_s)
        report = await job_tables_busy(conn)
    return [st for st in report if st.is_wave and st.busy]


def version_pattern(version: str) -> str:
    """Regex for the keys of the same owner as `version` (CIS NNN, tp-NNN, bk-NNN)."""
    m = re.match(r"^([a-z]+-)?[0-9]{3}$", version)
    prefix = m.group(1) if m and m.group(1) else ""
    return f"^{re.escape(prefix)}[0-9]{{3}}$"


@dataclass
class BusyState:
    """Idle-check result for one owner job table or for shared.rerun_wave."""
    name: str                           # "booking.job", "shared.rerun_wave"
    running: int = 0
    queued: int = 0
    due: int = 0
    later: int = 0                      # queued rows due beyond BUSY_HORIZON_S: reported, never busy
    kinds: list = field(default_factory=list)       # "kind:status=n", non-exempt only
    exempt: tuple = ()
    open_waves: int = 0
    is_wave: bool = False
    missing: bool = False               # expected but not in the catalog: WARNING, not busy
    error: str = ""                     # could not be read: counted as busy (fail closed)

    @property
    def busy(self) -> bool:
        return bool(self.error or self.running or self.queued or self.open_waves)

    def line(self) -> str:
        if self.missing:
            what = "wave check skipped" if self.is_wave else "not checked"
            return f"WARNING: {self.name} not found ({what})"
        if self.error:
            return f"busy: {self.name} unreadable ({self.error}), counted as busy"
        if self.is_wave:
            return f"{'busy' if self.busy else 'idle'}: {self.name} open={self.open_waves}"
        exempt = f" (exempt: {', '.join(self.exempt)})" if self.exempt else ""
        later = f" later={self.later}" if self.later else ""
        if not self.busy:
            return f"idle: {self.name} running=0 queued=0{later}{exempt}"
        return (f"busy: {self.name} running={self.running} queued={self.queued} due={self.due}{later} "
                f"kinds=[{', '.join(self.kinds)}]")

    def short(self) -> str:
        if self.error:
            return f"{self.name} (unreadable)"
        if self.is_wave:
            return f"{self.name} (open={self.open_waves})"
        parts = [f"{k}={v}" for k, v in (("running", self.running), ("queued", self.queued)) if v]
        return f"{self.name} ({', '.join(parts)})"


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _err(e: Exception) -> str:
    return f"{type(e).__name__}: {e}".strip()


async def job_tables_busy(conn) -> list:
    """Reads every owner job table and shared.rerun_wave; returns one BusyState per object."""
    report: list = []
    try:
        schemas = [r[0] for r in await conn.fetch(JOB_TABLES_SQL)]
    except Exception as e:                      # fail closed: nothing could be checked
        return [BusyState("owner job tables", error=_err(e))]
    for schema in sorted(set(IDLE_EXEMPT_KINDS) - set(schemas)):
        report.append(BusyState(f"{schema}.job", missing=True))
    for schema in schemas:
        exempt = tuple(sorted(IDLE_EXEMPT_KINDS.get(schema, ())))
        st = BusyState(f"{schema}.job", exempt=exempt)
        try:
            rows = await conn.fetch(JOB_BUSY_SQL.format(table=f"{_quote_ident(schema)}.job"), list(exempt),
                                    BUSY_HORIZON_S)
        except Exception as e:
            st.error = _err(e)
        else:
            for r in rows:
                if r["status"] == "running":
                    st.running += r["n"]
                else:
                    st.queued += r["n"]
                    st.due += r["due"]
                    st.later += r["later"]
                if r["n"]:
                    st.kinds.append(f"{r['kind']}:{r['status']}={r['n']}")
        report.append(st)
    wave = BusyState("shared.rerun_wave", is_wave=True)
    try:
        if await conn.fetchval(WAVE_TABLE_SQL):
            wave.open_waves = await conn.fetchval(OPEN_WAVES_SQL) or 0
        else:
            wave.missing = True
    except Exception as e:
        wave.error = _err(e)
    report.append(wave)
    report.sort(key=lambda s: (s.is_wave, s.name))
    return report


def log_report(report: list) -> None:
    for st in report:
        log(st.line())


def busy_summary(report: list) -> str:
    return ", ".join(st.short() for st in report if st.busy)


async def wait_until_idle(conn, first=None, attempts=IDLE_WAITS, interval_s=IDLE_WAIT_S,
                          sleep=asyncio.sleep) -> list:
    """Re-checks up to `attempts` times, `interval_s` apart, while anything is busy.

    `first` is a report taken just before (so an idle start costs no extra query). Returns the
    last report; the caller refuses when it is still busy."""
    report = first if first is not None else await job_tables_busy(conn)
    if first is None:
        log_report(report)
    for i in range(1, attempts + 1):
        if not any(st.busy for st in report):
            return report
        log(f"waiting {interval_s}s for idle job tables (re-check {i}/{attempts}), busy: {busy_summary(report)}")
        await sleep(interval_s)
        report = await job_tables_busy(conn)
        still_busy = any(st.busy for st in report)
        log_report([st for st in report if st.busy] if still_busy else report)   # no repeated idle lines
    return report


@dataclass
class RolePlan:
    """Which role a file runs as (XD8)."""
    login: str
    run_as: str = ""
    why: str = ""
    error: str = ""

    @property
    def switch(self) -> bool:
        return bool(self.run_as) and self.run_as != self.login


async def resolve_role(conn, owner_dir: str) -> RolePlan:
    """Live-owner role switch (plan S1 item 4): the owner of the dir's anchor schema, read now."""
    login = await conn.fetchval(SESSION_USER_SQL)
    plan = RolePlan(login)
    if owner_dir == ROLES_DIR:
        if login != MASTER_ROLE:
            plan.error = (f"roles/ files run only as the RDS master {MASTER_ROLE} (login is {login}); they "
                          f"create roles and extensions")
            return plan
        plan.run_as, plan.why = login, "roles/ file, runs as the master"
        return plan
    od = OWNER_DIRS.get(owner_dir)
    if od is None:
        plan.error = f"unknown migration dir {owner_dir!r} (db/owners.yaml: {', '.join(sorted(OWNER_DIRS))}, roles)"
        return plan
    owner = await conn.fetchval(SCHEMA_OWNER_SQL, od.anchor_schema)
    if owner is None:
        plan.run_as, plan.why = login, f"anchor schema {od.anchor_schema} does not exist yet, no role switch"
    elif owner == login:
        plan.run_as, plan.why = login, f"login role owns anchor schema {od.anchor_schema}, no role switch"
    elif not await conn.fetchval(IS_MEMBER_SQL, owner):
        plan.error = (f"anchor schema {od.anchor_schema} is owned by {owner} and the login role {login} is not "
                      f"a member of it: cannot SET ROLE {owner} (role bootstrap in db/migrations/roles/)")
    else:
        plan.run_as, plan.why = owner, (f"login {login}, anchor schema {od.anchor_schema} owned by {owner}: "
                                        f"SET ROLE {owner} for this file")
    return plan


async def set_role_reach_error(conn, sql: str, file: str, plan: RolePlan) -> str:
    """'' when the login role may `SET LOCAL ROLE` to every target of the file (linted owner-dir files
    only: at or above role_lint_from). PostgreSQL checks the session user's membership, so a target
    the login role is not a member of fails at apply with 42501 "permission denied to set role" — found
    here instead, in `check` mode too (X1 review, S241): catalog_owner while the login is the master
    (the S1–S22 catalog view freeze), cis_app once the login is db_migrator (rl-002 grants it)."""
    owner_dir, number = migration_path(file)
    od = OWNER_DIRS.get(owner_dir)
    if od is None or number is None or number < od.role_lint_from:
        return ""
    targets = set_local_role_targets(sql)
    if not targets:
        return ""
    missing = [r["role"] for r in await conn.fetch(SET_ROLE_REACH_SQL, targets)]
    if not missing:
        return ""
    hints = []
    if "catalog_owner" in missing:
        hints.append(CATALOG_FREEZE)
    if set(missing) - {"catalog_owner"}:
        hints.append("memberships of the DB Migrate login come from db/migrations/roles/ (db/owners.yaml "
                     "migrator_member_of: rl-001 for the master, rl-002 for db_migrator)")
    return (f"the file runs `SET LOCAL ROLE {', '.join(missing)}` but the login role {plan.login} is not a member "
            f"(SET ROLE checks the session user): it would fail at apply with 42501; nothing ran. "
            + "; ".join(hints))


def transaction_parts(sql: str) -> tuple:
    """(begin, body, commit, error) of a file that is exactly one BEGIN … COMMIT block. The switched
    path needs it: the runner's SET LOCAL ROLE goes right after BEGIN and its RESET ROLE + post-check
    right before COMMIT, inside the file's own transaction."""
    stmts = split_statements(sql)
    if len(stmts) < 2 or not re.match(r"^(BEGIN|START TRANSACTION)\b", stmts[0].code) \
            or not re.match(r"^(COMMIT|END)\b", stmts[-1].code) or re.search(r"\bAND\s+CHAIN\b", stmts[-1].code):
        return None, None, None, "file does not start with BEGIN and end with COMMIT"
    inner = [s for s in stmts[1:-1] if TX_CONTROL_RE.search(s.code) or PREPARE_TX_RE.search(s.code)]
    if inner:
        return None, None, None, (f"line {inner[0].line}: transaction control inside the file; one "
                                  f"BEGIN … COMMIT block is required to run under a role switch")
    return stmts[0], stmts[1:-1], stmts[-1], ""


async def object_snapshot(conn, plan: RolePlan) -> list:
    return list(await conn.fetch(OBJECTS_SQL, list(OWNER_SCHEMAS), plan.run_as))


def ownership_findings(before: list, after: list, plan: RolePlan, owner_dir: str) -> list:
    """What the file left behind that the switch forbids (plan S1 item 5, hardened):
      * an object created or re-owned during the file, owned by anyone but the role the file ran as
        (or the dir's view owner, catalog_owner): the login role after a stray role reset, a runtime
        role after `SET LOCAL ROLE cis_app`, … — in any schema, any object kind, default privileges;
      * an object in an owners.yaml schema whose schema is owned by someone else but that the login
        role owns, even from before the file (a transferred owner: nothing in it may belong to the
        login role);
      * any change to roles, role memberships or role settings (roles/ only, DM-8.1)."""
    allowed = {plan.run_as} | set(OWNER_DIRS[owner_dir].view_owner_roles)
    key = lambda r: (r["kind"], r["id"], r["owner"])            # noqa: E731
    seen = {key(r) for r in before}
    now = {key(r) for r in after}
    found = []
    for r in after:
        if r["kind"] in ROLE_KINDS:
            if key(r) not in seen:
                found.append(f"{r['kind']} {r['name']} added or changed")
        elif key(r) not in seen and r["owner"] not in allowed:
            found.append(f"{r['kind']} {r['name']} (owner {r['owner']})")
        elif (r["owner"] == plan.login and r["mine"] and r["schema_owner"] != plan.login
              and r["kind"] != "default privileges"):     # leftover FOR ROLE <login> rows are revoked by the transfer
            found.append(f"{r['kind']} {r['name']} (owner {r['owner']}, in a schema owned by {r['schema_owner']})")
    for r in before:
        if r["kind"] in ROLE_KINDS and key(r) not in now:
            found.append(f"{r['kind']} {r['name']} removed or changed")
    return sorted(set(found))[:50]


async def _settle_and_check(conn, before: list, plan: RolePlan, owner_dir: str) -> list:
    """Inside the open transaction, the owner role still current: settle the work queued for COMMIT
    (SETTLE_ROUNDS), then RESET ROLE, pin search_path and run the ownership post-check."""
    stuck = []
    for _ in range(SETTLE_ROUNDS):
        await conn.execute(f"SAVEPOINT {SETTLE_SAVEPOINT}")
        ids = await conn.fetchval(XACT_IDS_SQL)
        await conn.execute("SET CONSTRAINTS ALL IMMEDIATE")
        wrote = await conn.fetchval(XACT_IDS_SQL) != ids
        await conn.execute(f"RELEASE SAVEPOINT {SETTLE_SAVEPOINT}")
        if not wrote:
            break
    else:
        stuck = [f"deferred trigger work still queues more after {SETTLE_ROUNDS} rounds of SET CONSTRAINTS "
                 f"ALL IMMEDIATE (it would run at COMMIT, after this check)"]
    await conn.execute("CLOSE ALL")
    await conn.execute("RESET ROLE")
    await conn.execute(PIN_SEARCH_PATH_SQL.format(scope="LOCAL "))
    return stuck + ownership_findings(before, await object_snapshot(conn, plan), plan, owner_dir)


async def _post_commit_findings(conn, before: list, plan: RolePlan, owner_dir: str) -> list:
    """The snapshot once more after COMMIT: anything that still ran at COMMIT (after the post-check)
    shows up here. Settled work leaves nothing to run, so a hit means a way past the settle step."""
    await conn.execute(PIN_SEARCH_PATH_SQL.format(scope=""))
    found = ownership_findings(before, await object_snapshot(conn, plan), plan, owner_dir)
    await conn.execute("RESET search_path")
    return found


def _log_post_commit(found: list, plan: RolePlan) -> None:
    log(f"ERROR: ownership check after COMMIT (ran as {plan.run_as}, login {plan.login}): {', '.join(found)}. "
        f"Something ran at COMMIT, after the post-check passed: the file is COMMITTED and its version "
        f"registered. Give the objects to {plan.run_as} or drop them (roles/ file), delete the version row "
        f"by hand and fix the migration (no deferred triggers / WITH HOLD cursors under the switch)")


def _log_invalid_cic(bad: list) -> None:
    log(f"ERROR: expand: index build left {', '.join(bad)}; the version is NOT registered. Drop the index "
        f"(DROP INDEX CONCURRENTLY IF EXISTS <name>, a run-script or a follow-up file) and re-run the file")


async def run_switched(conn, sql: str, d: Directives, plan: RolePlan, owner_dir: str, rehearse: bool = False,
                       report: list = None) -> int:
    """Runs the file as plan.run_as; returns 0, or 9 when the ownership post-check fails.

    An expand file (AA-993 M2b) also gets the expand post-check (expand_findings) inside the same transaction, after
    the ownership post-check: a finding rolls back and returns 14 (findings appended to `report` when given).
    rehearse=True (check mode, classify; transactional files only) rolls back even when every check passes.

    Transactional file: BEGIN, snapshot, SET LOCAL ROLE, the body, then — owner still current —
    SET CONSTRAINTS ALL IMMEDIATE + CLOSE ALL (deferred triggers and WITH HOLD cursors would run at
    COMMIT, after the check, as the login role), RESET ROLE + pinned search_path, post-check, then
    COMMIT (or ROLLBACK). No-transaction file: snapshot, SET ROLE, every statement but the last,
    RESET ROLE; then the registration (the last statement, a plain literal INSERT by the lint) in the
    runner's own transaction: BEGIN, SET LOCAL ROLE, pinned search_path, the registration, settle,
    RESET ROLE, post-check, COMMIT — a failed post-check rolls the registration back, so the file is
    retried after the clean-up instead of being marked applied. Both paths take the snapshot once more
    after COMMIT (exit 9 if anything ran at COMMIT)."""
    role = _quote_ident(plan.run_as)
    if d.no_transaction:
        stmts = split_statements(sql)
        before = await object_snapshot(conn, plan)
        xbefore = await expand_snapshot(conn, in_transaction=False) if d.expand else None
        await conn.execute(f"SET ROLE {role}")
        for k, s in enumerate(stmts[:-1], 1):
            log(f"statement {k}/{len(stmts)} (line {s.line}) …")
            await conn.execute(s.text)
        await conn.execute("RESET ROLE")
        if d.expand:
            bad = await invalid_cic_indexes(conn, stmts[:-1])
            if bad:
                _log_invalid_cic(bad)
                return 16
            found = expand_findings(xbefore, await expand_snapshot(conn, in_transaction=False))
            if report is not None:
                report.extend(found)
            if found:
                _log_expand(found, False)
                return 14
        log(f"statement {len(stmts)}/{len(stmts)} (line {stmts[-1].line}) … (registration, as {plan.run_as}, "
            f"in a transaction with the post-check)")
        await conn.execute("BEGIN")
        await conn.execute(f"SET LOCAL ROLE {role}")
        await conn.execute(PIN_SEARCH_PATH_SQL.format(scope="LOCAL "))
        await conn.execute(stmts[-1].text)
        stray = await _settle_and_check(conn, before, plan, owner_dir)
        if stray:
            await conn.execute("ROLLBACK")
            log(f"ERROR: ownership post-check (ran as {plan.run_as}, login {plan.login}): {', '.join(stray)}. "
                f"The statements before the registration are committed (no-transaction file) and the version "
                f"is NOT registered: give the objects to {plan.run_as} or drop them (roles/ file), fix the "
                f"migration, then re-run")
            return 9
        await conn.execute("COMMIT")
    else:
        begin, body, commit, _ = transaction_parts(sql)
        await conn.execute(begin.text)
        before = await object_snapshot(conn, plan)
        xbefore = await expand_snapshot(conn) if d.expand else None
        await conn.execute(f"SET LOCAL ROLE {role}")
        if body:
            await conn.execute("\n".join(s.text for s in body))
        stray = await _settle_and_check(conn, before, plan, owner_dir)
        if stray:
            await conn.execute("ROLLBACK")
            log(f"ERROR: ownership post-check (ran as {plan.run_as}, login {plan.login}): {', '.join(stray)}. "
                f"Rolled back. A RESET ROLE or SET ROLE back to the login role inside the file is the usual cause "
                f"(use SET LOCAL ROLE {plan.run_as}); roles and memberships belong in roles/")
            return 9
        if d.expand:
            found = expand_findings(xbefore, await expand_snapshot(conn))
            if report is not None:
                report.extend(found)
            if found or rehearse:
                await conn.execute("ROLLBACK")
                if found:
                    _log_expand(found, rehearse)
                    return 14
                log(f"expand rehearsal: post-check ok (ran as {plan.run_as}; no existing object changed), "
                    f"rolled back")
                return 0
            log("expand post-check: ok (no existing object changed)")
        elif rehearse:
            await conn.execute("ROLLBACK")
            return 0
        await conn.execute(commit.text)
    late = await _post_commit_findings(conn, before, plan, owner_dir)
    if late:
        _log_post_commit(late, plan)
        return 9
    return 0


# ── X1 S12: mode=set-password and mode=run-script ──
# Both arrive folded into the value of MIGRATION_MODE ("set-password:<role>",
# "run-script:db/scripts/<name>.py"), so no new environment variable reaches the task.
SET_PASSWORD = "set-password"
RUN_SCRIPT = "run-script"
APPLY_PENDING = "apply-pending"                # AA-993 M3: migration-apply.yml (bundle of copies, see below)
SECRETS_REGION = "us-west-1"                  # acc2: every DSN secret of the shared RDS lives here
PASSWORD_MIN_LEN = 32                         # plan S17: a new random password of at least 32 characters
# Printable ASCII only: PostgreSQL's SASLprep returns pure ASCII unchanged, so the verifier computed here
# from the raw password matches what the server derives from the password the client sends.
PASSWORD_RE = re.compile(r"^[\x20-\x7e]+$")
SCRAM_ITERATIONS = 4096                       # PostgreSQL's scram_iterations default
SCRAM_SALT_BYTES = 16                         # PostgreSQL's SCRAM_DEFAULT_SALT_LEN
SCRIPT_PATH_RE = re.compile(r"^db/scripts/[a-z0-9_]+\.py$")
# db-migrate.yml uploads the runner to s3://<bucket>/db-migrate/<run id>/run_migration.py: the run id is
# read from the presigned URL's path (only the digits are logged; the signature is never printed).
RUN_ID_RE = re.compile(r"(?:^|/)db-migrate/([0-9]+)/")
PASSWORD_MARKER = "x1:password-set"           # db/isolation_probe.py PASSWORD_MARKER (probe state key)
ROLE_LOGIN_SQL = "SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE rolname = $1"
WHOAMI_SQL = ("SELECT current_user::text AS current_user, "
              "(SELECT rolconnlimit FROM pg_catalog.pg_roles WHERE rolname = current_user) AS rolconnlimit")


@dataclass(frozen=True)
class Mode:
    kind: str           # check | apply | set-password | run-script
    arg: str = ""       # set-password: the role; run-script: db/scripts/<name>.py


def parse_mode(value: str) -> Mode:
    """MIGRATION_MODE → Mode; ValueError (exit 10) for anything outside the allowlists."""
    if value in ("check", "apply", APPLY_PENDING):
        return Mode(value)
    kind, sep, arg = (value or "").partition(":")
    if kind == SET_PASSWORD and sep:
        if arg not in PASSWORD_ROLES:
            raise ValueError(f"set-password: role {arg!r} is not in db/owners.yaml password_roles "
                             f"({', '.join(sorted(PASSWORD_ROLES))})")
        return Mode(kind, arg)
    if kind == RUN_SCRIPT and sep:
        if not SCRIPT_PATH_RE.fullmatch(arg):
            raise ValueError(f"run-script: {arg!r} is not a db/scripts/<name>.py path")
        return Mode(kind, arg)
    raise ValueError(f"unknown MIGRATION_MODE {value!r} (check, apply, apply-pending, set-password:<role>, "
                     f"run-script:db/scripts/<name>.py)")


def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def scram_sha256_verifier(password: str, salt: bytes = None, iterations: int = SCRAM_ITERATIONS) -> str:
    """SCRAM-SHA-256 secret (RFC 5802 / RFC 7677) in PostgreSQL's pg_authid format:
    SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>, all base64.

    SaltedPassword = PBKDF2-HMAC-SHA-256(password, salt, iterations) (RFC 5802 Hi()),
    ClientKey = HMAC(SaltedPassword, "Client Key"), StoredKey = SHA-256(ClientKey),
    ServerKey = HMAC(SaltedPassword, "Server Key"). ALTER ROLE … PASSWORD '<this>' stores it as is, so
    the password itself never reaches the server or its statement log."""
    salt = os.urandom(SCRAM_SALT_BYTES) if salt is None else salt
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    return f"SCRAM-SHA-256${iterations}:{_b64(salt)}${_b64(stored_key)}:{_b64(server_key)}"


@dataclass(frozen=True)
class DsnLogin:
    user: str
    password: str
    raw_password: str = field(default="", repr=False)    # as written in the DSN (percent-encoded)

    def __repr__(self) -> str:                           # never print the password by accident
        return f"DsnLogin(user={self.user!r}, password=***)"


def dsn_login(dsn: str) -> DsnLogin:
    """User and password exactly as asyncpg reads them from a URL DSN (connect_utils: netloc.partition('@'),
    then auth.partition(':'), each percent-decoded), so the verifier matches what the test login sends.
    ValueError messages never contain any part of the value."""
    try:
        parsed = urllib.parse.urlparse(dsn)
    except ValueError:
        raise ValueError("not a parseable URL") from None
    if parsed.scheme not in ("postgresql", "postgres"):
        raise ValueError("not a postgresql:// DSN")
    if "@" not in parsed.netloc:
        raise ValueError("the DSN has no user:password@ part")
    auth, _, hostspec = parsed.netloc.partition("@")
    if "@" in hostspec:
        raise ValueError("more than one '@' in the DSN: percent-encode '@' in the password as %40")
    raw_user, _, raw_password = auth.partition(":")
    query = urllib.parse.parse_qs(parsed.query)
    if {"user", "password", "passfile"} & set(query):
        raise ValueError("the DSN query sets user/password/passfile: keep them in the user:password@ part only")
    return DsnLogin(urllib.parse.unquote(raw_user), urllib.parse.unquote(raw_password), raw_password)


def dsn_target(dsn: str) -> tuple:
    """(host, port, database) a URL DSN connects to, as asyncpg reads it (port 5432 by default). ValueError for
    a DSN whose target is not one plain host:port/database (several hosts, or host/port/database in the
    query, which asyncpg would honour). Messages never contain any part of the value."""
    try:
        parsed = urllib.parse.urlparse(dsn)
        hostspec = parsed.netloc.rpartition("@")[2]
        port = parsed.port or 5432
    except ValueError:
        raise ValueError("the DSN's host:port is not parseable") from None
    if "," in hostspec or not parsed.hostname:
        raise ValueError("the DSN must name exactly one host")
    if {"host", "port", "dbname", "database"} & set(urllib.parse.parse_qs(parsed.query)):
        raise ValueError("the DSN query sets host/port/dbname/database: keep them in the URL only")
    database = urllib.parse.unquote(parsed.path.lstrip("/"))
    if not database:
        raise ValueError("the DSN names no database")
    return parsed.hostname.lower(), port, database


def _redact(text: str, secrets) -> str:
    """Replace each secret in the text, also in the forms an error message may show it: repr-escaped,
    percent-encoded and percent-decoded."""
    forms = set()
    for v in secrets:
        if v:
            forms |= {v, repr(v)[1:-1], v.encode("unicode_escape").decode("ascii"),
                      urllib.parse.quote(v, safe=""), urllib.parse.unquote(v)}
    for value in sorted({f for f in forms if f}, key=len, reverse=True):
        text = text.replace(value, "***")
    return text


def _dsn_secrets(*dsns) -> tuple:
    """Each DSN and its password (decoded + as written), for _redact."""
    out = []
    for dsn in dsns:
        if not dsn:
            continue
        out.append(dsn)
        try:
            who = dsn_login(dsn)
            out += [who.password, who.raw_password]
        except ValueError:
            pass
    return tuple(out)


def _quote_literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def _aws_err(e: Exception) -> str:
    code = (getattr(e, "response", None) or {}).get("Error", {}).get("Code")
    return f"{type(e).__name__}{f' {code}' if code else ''}"


def _run_id(env) -> str:
    m = RUN_ID_RE.search(urllib.parse.urlparse(env.get("RUNNER_URL") or "").path)
    return m.group(1) if m else "unknown"


def _get_secret(secret_id: str) -> str:
    import boto3   # only inside the task (the image has it); CI and the lint path never call this
    return boto3.client("secretsmanager", region_name=SECRETS_REGION).get_secret_value(
        SecretId=secret_id).get("SecretString") or ""


class MasterUnavailable(Exception):
    """No RDS master session for a roles/ file, set-password or run-script (exit 8). The message never holds
    any part of a DSN."""


@dataclass
class MasterLogin:
    conn: object
    dsn: str            # the DSN the session logged in with (redaction, set-password's target check)
    how: str            # where it came from, for the log


async def connect_master(env, settings: dict, connect, get_secret, purpose: str) -> MasterLogin:
    """An RDS master session for `purpose` (X1 S22, S242 amendment). The task's DATABASE_URL first: before S22 it
    is the master's and nothing changes. When it logs in as anyone else (db_migrator from S22), that session is
    closed and the master DSN is read here, in the task, from MASTER_SECRET (the migrator task role may read it,
    the execution role no longer injects it) and used with ssl=require. The caller still checks session_user.

    The master path never depends on the DATABASE_URL login working (review S244): a DATABASE_URL that names
    another user (db_migrator) is not opened at all (no session against its CONNECTION LIMIT 5), and one that
    fails to log in (28P01 after the db-migrator secret drifted, 53300 at its limit) falls back to the in-task
    master DSN. That keeps `set-password role=db_migrator` — the fix for a drifted db_migrator secret — working."""
    dsn = env["DATABASE_URL"]
    try:
        login = dsn_login(dsn).user
    except ValueError:
        login = None                            # not a plain URL DSN: ask the server below
    if login in (None, MASTER_ROLE):
        try:
            conn = await connect(dsn, settings)
        except Exception as e:                  # class + SQLSTATE only: the text may echo the DSN
            state = getattr(e, "sqlstate", "") or ""
            log(f"master login: the task's DATABASE_URL did not log in ({type(e).__name__} {state}".rstrip() + ")")
            login = "nobody (its login failed)"
        else:
            try:
                login = await conn.fetchval(SESSION_USER_SQL)
            except BaseException:
                await conn.close()
                raise
            if login == MASTER_ROLE:
                return MasterLogin(conn, dsn, "the task's DATABASE_URL")
            await conn.close()
    log(f"master login: {purpose} needs the RDS master {MASTER_ROLE} and the task logs in as {login}: "
        f"reading the master DSN in the task from {MASTER_SECRET} (X1 S22)")
    try:
        master_dsn = (get_secret(MASTER_SECRET) or "").strip()
    except Exception as e:                      # botocore ClientError: the error code only
        raise MasterUnavailable(f"master DSN secret {MASTER_SECRET} unreadable ({_aws_err(e)})") from None
    if not master_dsn:
        raise MasterUnavailable(f"master DSN secret {MASTER_SECRET} is empty")
    try:
        conn = await connect(master_dsn, settings, ssl="require")   # read by code, never in cleartext
    except Exception as e:                      # class + SQLSTATE only: the text may echo the DSN
        state = getattr(e, "sqlstate", "") or ""
        raise MasterUnavailable(f"master login with {MASTER_SECRET} failed: {type(e).__name__} {state}".rstrip()) \
            from None
    return MasterLogin(conn, master_dsn, f"in-task DSN from {MASTER_SECRET}")


async def run_set_password(env, role: str, connect, get_secret, sleep=asyncio.sleep) -> int:
    """XD2: the DSN Nghiệp wrote in the Console (S17 / S20) becomes the role's password; only a SCRAM
    verifier leaves the task. Order: checks (master login, role exists + LOGIN, secret readable, DSN user
    = role, password shape) → ALTER ROLE … PASSWORD '<verifier>' as the master → test login with the
    DSN (prints current_user + rolconnlimit) → COMMENT ON ROLE … 'x1:password-set …' as the master (the
    isolation probe expects the role's login only once the marker exists). Re-running is idempotent
    (new salt, same password)."""
    secret_id = PASSWORD_ROLES[role]
    log(f"set-password: role={role} secret={secret_id}")
    try:
        master = await connect_master(env, dict(DEFAULT_SETTINGS), connect, get_secret, "set-password")
    except MasterUnavailable as e:
        log(f"ERROR: role: set-password needs the RDS master {MASTER_ROLE} (ALTER ROLE … PASSWORD needs "
            f"CREATEROLE): {e}. Nothing changed")
        return 8
    conn = master.conn
    hide: tuple = _dsn_secrets(master.dsn)
    try:
        login = await conn.fetchval(SESSION_USER_SQL)
        if login != MASTER_ROLE:
            log(f"ERROR: role: set-password runs only as the RDS master {MASTER_ROLE} (login is {login}): "
                f"ALTER ROLE … PASSWORD needs CREATEROLE")
            return 8
        log(f"master login: {login} ({master.how})")
        if not await take_apply_lock(conn, sleep, f"set-password {role}"):
            return 17
        can_login = await conn.fetchval(ROLE_LOGIN_SQL, role)
        if can_login is None:
            log(f"ERROR: role {role} does not exist (rl-001 creates cis_app, rl-002 db_migrator, rl-003 crm_app): "
                f"nothing changed")
            return 11
        if not can_login:
            log(f"ERROR: role {role} is NOLOGIN: nothing changed")
            return 11
        try:
            dsn = (get_secret(secret_id) or "").strip()
        except Exception as e:                  # botocore ClientError: log the error code only
            log(f"ERROR: secret {secret_id} unreadable ({_aws_err(e)}); a secret with no value yet reads like a "
                f"missing one: Nghiệp writes the DSN in the Console first (plan S17 / S20). Nothing changed")
            return 11
        if not dsn:
            log(f"ERROR: secret {secret_id} is empty: nothing changed")
            return 11
        hide += (dsn,)
        try:
            who = dsn_login(dsn)
        except ValueError as e:
            log(f"ERROR: secret {secret_id}: {e}. Nothing changed")
            return 11
        hide += (who.password, who.raw_password)
        if who.user != role:
            log(f"ERROR: secret {secret_id} names a user other than {role}: nothing changed")
            return 11
        if len(who.password) < PASSWORD_MIN_LEN or not PASSWORD_RE.match(who.password):
            log(f"ERROR: secret {secret_id}: the password must be at least {PASSWORD_MIN_LEN} printable ASCII "
                f"characters (percent-encoded in the DSN where needed): nothing changed")
            return 11
        # The test login must reach the server and database the master is on: a mistyped host would otherwise
        # mark the role on this database while the password went to (and was tested against) another server.
        try:
            target, master_target = dsn_target(dsn), dsn_target(master.dsn)
        except ValueError as e:
            log(f"ERROR: secret {secret_id} or the master DSN: {e}. Nothing changed")
            return 11
        if target != master_target:
            log(f"ERROR: secret {secret_id} points at another host, port or database than the master connection "
                f"(they must be equal): nothing changed")
            return 11
        verifier = scram_sha256_verifier(who.password)
        hide += (verifier,)
        await conn.execute(f"ALTER ROLE {_quote_ident(role)} PASSWORD {_quote_literal(verifier)}")
        log(f"set-password: ALTER ROLE {role} PASSWORD '<SCRAM-SHA-256 verifier, {SCRAM_ITERATIONS} iterations>' done")
        try:
            test = await connect(dsn, dict(DEFAULT_SETTINGS), ssl="require")    # never a cleartext password
            try:
                row = await test.fetchrow(WHOAMI_SQL)
            finally:
                await test.close()
        except Exception as e:                  # class + SQLSTATE only: an auth error's text adds nothing safe
            state = getattr(e, "sqlstate", "") or ""
            log(f"ERROR: test login as {role} with {secret_id} failed: {type(e).__name__} {state}".rstrip()
                + f". The password is set; the role is NOT marked {PASSWORD_MARKER}")
            return 12
        log(f"set-password: test login current_user={row['current_user']} rolconnlimit={row['rolconnlimit']}")
        if row["current_user"] != role:
            log(f"ERROR: the test login ran as {row['current_user']}, not {role}: the role is NOT marked")
            return 12
        when = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        comment = f"{PASSWORD_MARKER} {when} by DB Migrate set-password (run {_run_id(env)})"
        await conn.execute(f"COMMENT ON ROLE {_quote_ident(role)} IS {_quote_literal(comment)}")
        log(f"set-password: COMMENT ON ROLE {role} IS {_quote_literal(comment)}")
        return 0
    except Exception as e:                      # PostgreSQL error on ALTER / COMMENT: never echo the statement
        log(f"ERROR: {type(e).__name__} {getattr(e, 'sqlstate', '') or ''} {_redact(str(e), hide)}")
        return 6
    finally:
        await conn.close()


def script_errors(source: str, path: str) -> list:
    """Shape of a db/scripts/ file: valid Python with a top-level `async def main(conn)` (one argument), and
    at most one `READ_ONLY = True|False`; a READ_ONLY script may not switch read-only off again."""
    if not SCRIPT_PATH_RE.fullmatch(path or ""):
        return [f"{path!r} is not a db/scripts/<name>.py path"]
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as e:
        return [f"syntax error, line {e.lineno}: {e.msg}"]
    mains = [n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == "main"]
    if not mains:
        return ["needs a top-level `async def main(conn)` (the runner awaits it with the master connection)"]
    a = mains[-1].args
    if len(a.posonlyargs) + len(a.args) != 1 or a.vararg or a.kwarg or a.kwonlyargs:
        return ["main() takes exactly one argument: the asyncpg connection"]
    read_only = _read_only_decl(tree)
    if read_only is _BAD_DECL:
        return ["READ_ONLY must be one top-level `READ_ONLY = True` (or False)"]
    if read_only and any(READ_ONLY_ESCAPE_RE.search(text) for text in _code_strings(tree)):
        return ["a READ_ONLY script must not change transaction_read_only / default_transaction_read_only "
                "or open a READ WRITE transaction"]
    return []


def _code_strings(tree) -> list:
    """Every string literal of the file except docstrings (comments are not in the AST either)."""
    docs = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.body:
            first = n.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docs.add(id(first.value))
    return [n.value for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docs]


_BAD_DECL = object()
READ_ONLY_ESCAPE_RE = re.compile(r"transaction_read_only|read\s+write", re.I)


def _read_only_decl(tree):
    """Top-level READ_ONLY: True / False, or _BAD_DECL unless it is exactly one assignment of a bool literal."""
    found = []
    for n in tree.body:
        targets = n.targets if isinstance(n, ast.Assign) else (
            [n.target] if isinstance(n, (ast.AnnAssign, ast.AugAssign)) else [])
        if any(isinstance(t, ast.Name) and t.id == "READ_ONLY" for t in targets):
            found.append(n)
    if not found:
        return False
    if len(found) != 1 or not isinstance(found[0], ast.Assign) or len(found[0].targets) != 1:
        return _BAD_DECL
    v = found[0].value
    return v.value if isinstance(v, ast.Constant) and isinstance(v.value, bool) else _BAD_DECL


def script_is_read_only(source: str) -> bool:
    return _read_only_decl(ast.parse(source)) is True


async def run_script(env, path: str, fetch, connect, sleep, get_secret=_get_secret) -> int:
    """XD5 / S19: a reviewed db/scripts/ file runs as the master, after the same idle check as apply
    (exit 7 while busy, MIGRATION_IDLE_OVERRIDE applies). A script that declares `READ_ONLY = True` runs
    with default_transaction_read_only=on instead and skips the wait (the busy report is still logged).
    The file arrives like a migration (presigned URL + sha256). Its own output goes to the task log as is."""
    file = env.get("MIGRATION_FILE") or ""
    if file != path:
        log(f"ERROR: MIGRATION_FILE {file!r} is not the mode's script {path!r}")
        return 10
    raw = fetch(env["MIGRATION_URL"])
    digest = hashlib.sha256(raw).hexdigest()
    if digest != env.get("MIGRATION_SHA256"):
        log(f"sha256 mismatch: got {digest}")
        return 2
    log(f"run-script: file={path} sha256={digest[:12]}")
    source = raw.decode("utf-8")
    errors = script_errors(source, path)
    if errors:
        for e in errors:
            log(f"ERROR: {path}: {e}")
        return 10
    code = compile(source, path, "exec")
    read_only = script_is_read_only(source)
    settings = dict(DEFAULT_SETTINGS)
    if read_only:
        settings["default_transaction_read_only"] = "on"
    try:
        master = await connect_master(env, settings, connect, get_secret, "run-script")
    except MasterUnavailable as e:
        log(f"ERROR: role: run-script runs only as the RDS master {MASTER_ROLE}: {e}. Nothing ran")
        return 8
    conn = master.conn
    # A script's error text could carry either DSN (the master's, or the task's own when it read os.environ).
    hide = _dsn_secrets(master.dsn, env.get("DATABASE_URL"))
    try:
        login = await conn.fetchval(SESSION_USER_SQL)
        if login != MASTER_ROLE:
            log(f"ERROR: role: run-script runs only as the RDS master {MASTER_ROLE} (login is {login})")
            return 8
        log(f"master login: {login} ({master.how})")
        log(f"ran as: {login} (run-script{', READ_ONLY: default_transaction_read_only=on' if read_only else ''})")
        if not read_only and not await take_apply_lock(conn, sleep, f"run-script {path}"):
            return 17
        report = await job_tables_busy(conn)
        log_report(report)
        override = (env.get("MIGRATION_IDLE_OVERRIDE") or "").strip()
        if read_only:
            log("run-script: READ_ONLY script, the idle check is report-only (no wait, no refusal)")
        elif override:
            if any(st.busy for st in report):
                log(f"WARNING: idle check OVERRIDDEN ({override}), busy: {busy_summary(report)}")
            else:
                log(f"note: idle-check override set ({override}) but nothing is busy")
        else:
            report = await wait_until_idle(conn, first=report, sleep=sleep)
            if any(st.busy for st in report):
                log(f"ERROR: refusing run-script — busy: {busy_summary(report)}. Wait until every job table is "
                    f"idle, or re-dispatch with override_busy_jobs=<reason> (Nghiệp only)")
                return 7
        log("run-script: main(conn) starts; its output follows")
        try:
            ns = {"__name__": "db_script", "__file__": path}
            exec(code, ns)                      # reviewed file on main, sha256-checked above
            result = await ns["main"](conn)
        except Exception as e:                  # a script's error text could carry the master DSN: redacted
            state = getattr(e, "sqlstate", "") or ""
            log(_redact(f"ERROR: script raised {type(e).__name__} {state} {e}".rstrip(), hide))
            if state == "55P03":
                log("hint: lock_timeout (5s) hit — retry when the job tables are idle, or SET LOCAL lock_timeout "
                    "inside the script's own transaction")
            return 13
        if result not in (None, 0):
            log(_redact(f"ERROR: script main() returned {result!r}", hide))
            return 13
        log("run-script: done")
        return 0
    finally:
        await conn.close()


def _fetch(url: str) -> bytes:
    return urllib.request.urlopen(url, timeout=30).read()


async def _connect(dsn: str, settings: dict, ssl=None):
    import asyncpg   # only inside the task: the lint path and CI run without asyncpg
    extra = {"ssl": ssl} if ssl else {}  # None: the DSN's sslmode / asyncpg's default, as before S12
    return await asyncpg.connect(dsn, timeout=30, server_settings=settings, **extra)


async def execute_file(conn, sql: str, d: "Directives", plan: "RolePlan", owner_dir: str,
                       rehearse: bool = False, report: list = None, info: dict = None) -> int:
    """Runs the file's statements the way apply does (role switch, no-transaction, plain); 0 or an exit code. An
    expand file gets the M2b post-check (exit 14); rehearse=True (expand, transactional) always rolls back.
    `info` (M3, apply-pending) receives the SQLSTATE of a PostgreSQL error, so the caller can retry 55P03."""
    try:
        if plan.switch:
            return await run_switched(conn, sql, d, plan, owner_dir, rehearse=rehearse, report=report)
        if d.expand and not d.no_transaction:
            return await run_expand_transaction(conn, sql, rehearse=rehearse, report=report)
        if d.no_transaction:
            stmts = split_statements(sql)
            xbefore = await expand_snapshot(conn, in_transaction=False) if d.expand else None
            for k, s in enumerate(stmts, 1):
                if d.expand and k == len(stmts):
                    bad = await invalid_cic_indexes(conn, stmts[:-1])
                    if bad:
                        _log_invalid_cic(bad)
                        return 16
                    found = expand_findings(xbefore, await expand_snapshot(conn, in_transaction=False))
                    if report is not None:
                        report.extend(found)
                    if found:
                        _log_expand(found, False)
                        return 14
                log(f"statement {k}/{len(stmts)} (line {s.line}) …")
                await conn.execute(s.text)          # one statement per message: autocommit
        else:
            await conn.execute(sql)                 # simple protocol: the file's own BEGIN/COMMIT
        return 0
    except Exception as e:                          # asyncpg.PostgresError and friends
        state = getattr(e, "sqlstate", "") or ""
        if info is not None:
            info["sqlstate"] = state
        log(f"ERROR: {type(e).__name__} {state} {e}")
        if state == "55P03":
            log(f"hint: lock_timeout ({d.settings['lock_timeout']}) hit — a job or session holds a lock "
                f"on the table. Retry when shared.job / booking.job are idle; raise it only with "
                f"`-- migrate: lock_timeout=…`")
        elif state == "57014":
            log(f"hint: statement_timeout ({d.settings['statement_timeout']}) hit — raise it with "
                f"`-- migrate: statement_timeout=…` if the statement is expected to be slow")
        if d.no_transaction:
            log("hint: no-transaction file stopped half way; statements before it are committed. "
                "A failed CREATE INDEX CONCURRENTLY leaves an INVALID index: drop it before the retry")
        return 6


async def run_task(env=None, fetch=_fetch, connect=_connect, sleep=asyncio.sleep, get_secret=_get_secret) -> int:
    env = os.environ if env is None else env
    try:
        m = parse_mode(env.get("MIGRATION_MODE") or "")
    except ValueError as e:
        log(f"ERROR: {e}")
        return 10
    if m.kind == SET_PASSWORD:
        return await run_set_password(env, m.arg, connect=connect, get_secret=get_secret, sleep=sleep)
    if m.kind == RUN_SCRIPT:
        return await run_script(env, m.arg, fetch=fetch, connect=connect, sleep=sleep, get_secret=get_secret)
    if m.kind == APPLY_PENDING:
        return await run_apply_pending(env, fetch=fetch, connect=connect, sleep=sleep, get_secret=get_secret)
    raw = fetch(env["MIGRATION_URL"])
    digest = hashlib.sha256(raw).hexdigest()
    if digest != env["MIGRATION_SHA256"]:
        log(f"sha256 mismatch: got {digest}")
        return 2
    version, mode = env["MIGRATION_VERSION"], env["MIGRATION_MODE"]
    log(f"file={env['MIGRATION_FILE']} version={version} sha256={digest[:12]} mode={mode}")
    return await apply_file(env, raw.decode("utf-8"), env.get("MIGRATION_FILE") or "", version, mode,
                            connect=connect, sleep=sleep, get_secret=get_secret)


async def apply_file(env, sql: str, file: str, version: str, mode: str, connect, sleep, get_secret,
                     lock_held: bool = False, info: dict = None) -> int:
    """check / apply of ONE file (lint, login, role, lock risk, apply lock, idle check, statements, registration).
    run_task calls it for DB Migrate; run_apply_pending (M3) once per file with lock_held=True, because the run
    already holds the apply lock on its own session, and `info` to learn the SQLSTATE of a failure."""
    d = parse_directives(sql)
    errors, warnings = lint(sql, d, file)
    log(f"directives: transaction={'no' if d.no_transaction else 'yes'} destructive={'yes' if d.destructive else 'no'} "
        f"lock_timeout={d.settings['lock_timeout']} statement_timeout={d.settings['statement_timeout']}")
    for w in warnings:
        log(f"WARNING: {w}")
    if errors:
        for e in errors:
            log(f"ERROR: {e}")
        return 4

    owner_dir = file.split("/", 1)[0]
    if owner_dir == ROLES_DIR:
        # X1 S22: roles/ files keep the RDS master; from S22 its DSN is read in the task (connect_master).
        try:
            master = await connect_master(env, d.settings, connect, get_secret, "a roles/ file")
        except MasterUnavailable as e:
            log(f"ERROR: role: roles/ files run only as the RDS master {MASTER_ROLE}: {e}. Nothing ran")
            return 8
        conn = master.conn
        log(f"master login: {master.how}")
    else:
        conn = await connect(env["DATABASE_URL"], d.settings)
    try:
        plan = await resolve_role(conn, owner_dir)
        if plan.error:
            log(f"ERROR: role: {plan.error}")
            return 8
        if plan.switch:
            # Files at or below the head are not linted; the switch still needs these shapes.
            shape_error = registration_error(sql) if d.no_transaction else transaction_parts(sql)[3]
            if shape_error:
                log(f"ERROR: role: {shape_error}")
                return 8
        reach_error = await set_role_reach_error(conn, sql, file, plan)
        if reach_error:
            log(f"ERROR: role: {reach_error}")
            return 8
        log(f"ran as: {plan.run_as}{' (check mode: the role apply uses)' if mode != 'apply' else ''} — {plan.why}")
        expand_applied = d.expand and await conn.fetchval(
            "SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        # AA-993 M2b: check mode rehearses a transactional expand file (body + post-check, then ROLLBACK), so a check
        # predicts exit 14 too. It runs the statements, so it takes the apply lock like apply does.
        rehearse = mode != "apply" and d.expand and not d.no_transaction and not expand_applied
        if expand_applied:
            log("expand: version already registered, lock-risk check skipped")
        elif d.expand:
            # ADR 0017 d4: sizes are read before any statement (check mode too, so a check predicts the apply).
            risk = await lock_risk_findings(conn, sql, d)
            if risk:
                log(f"ERROR: expand: lock risk -> contract: {'; '.join(risk)}. Nothing ran: use CREATE INDEX "
                    f"CONCURRENTLY in a no-transaction file, or drop the expand header and apply it by hand")
                return 15
            log(f"expand: lock-risk check ok ({len(lock_risk_targets(sql, d))} existing table(s) locked, each "
                f"<= {EXPAND_MAX_ROWS} rows); statement_timeout {d.settings['statement_timeout']}")
        if lock_held:
            log("apply lock: held by this run's own session (apply-pending)")
        elif (mode == "apply" or rehearse) and not await take_apply_lock(
                conn, sleep, f"{'apply' if mode == 'apply' else 'expand rehearsal'} {file}"):
            return 17
        latest = await conn.fetchval(
            "SELECT version FROM shared.schema_versions WHERE version ~ $1 ORDER BY version DESC LIMIT 1",
            version_pattern(version))
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        log(f"before: latest_registered_same_owner={latest} this_version_applied_at={applied}")
        report = await job_tables_busy(conn)
        log_report(report)
        override = (env.get("MIGRATION_IDLE_OVERRIDE") or "").strip()
        if mode != "apply":
            if override:
                log("note: the idle-check override only applies to mode=apply")
            if rehearse:
                log("expand rehearsal: the body runs in a transaction that is rolled back (check mode) …")
                return await execute_file(conn, sql, d, plan, owner_dir, rehearse=True)
            if d.expand and d.no_transaction and not expand_applied:
                log("expand: no rehearsal for a CREATE INDEX CONCURRENTLY file (it cannot run in a transaction); "
                    "apply checks it before the registration")
            return 0
        if applied:
            log("skip: already applied")
            return 0
        if plan.switch and not await conn.fetchval(CAN_REGISTER_SQL, plan.run_as):
            log(f"ERROR: role: {plan.run_as} cannot register the version (needs USAGE on schema shared and INSERT "
                f"on shared.schema_versions, X1 plan S4 / CIS 243): nothing ran")
            return 8
        if override:
            if any(st.busy for st in report):
                log(f"WARNING: idle check OVERRIDDEN ({override}), busy: {busy_summary(report)}")
            else:
                log(f"note: idle-check override set ({override}) but nothing is busy")
        elif d.expand:
            # ADR 0017 d5 / Q5: expand files skip the all-job-tables-idle wait; one that names a hot table (only a
            # non-unique CIC may, by the lint) still waits for an open rerun wave to close.
            hot = [h for h in (names_hot_table(st.code) for st in split_statements(sql)) if h]
            if hot:
                waves = await wait_for_waves(conn, sleep)
                if waves:
                    log(f"ERROR: refusing expand apply — it names hot table {hot[0]} and a rerun wave is open "
                        f"({busy_summary(waves)}). Re-run after the wave closes")
                    return 7
            log(f"expand: job-table idle wait skipped (ADR 0017 d5){'; no open wave' if hot else ''}")
        else:
            report = await wait_until_idle(conn, first=report, sleep=sleep)
            if any(st.busy for st in report):
                log(f"ERROR: refusing apply — busy: {busy_summary(report)}. Wait until every job table is "
                    f"idle, or re-dispatch with override_busy_jobs=<reason> (Nghiệp only)")
                return 7
        if d.destructive:
            snapshot = (env.get("MIGRATION_SNAPSHOT") or "").strip()
            if not snapshot:
                log("ERROR: destructive migration needs the RDS snapshot DB Migrate takes first "
                    "(MIGRATION_SNAPSHOT is empty) — run it through db-migrate.yml")
                return 5
            log(f"snapshot taken before apply: {snapshot}")
        code = await execute_file(conn, sql, d, plan, owner_dir, info=info)
        if code:
            return code
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        if not applied:
            log("ERROR: file ran but did not register its version in shared.schema_versions")
            return 3
        log(f"after: applied_at={applied}")
        return 0
    finally:
        await conn.close()


# ── AA-993 Phase E slice M3: apply-pending (root ADR 0017 decision 5, migration-apply.yml) ──
# MIGRATION_MODE=apply-pending: MIGRATION_URL is a JSON bundle built on the runner by db/apply_pending.py (every copy
# of the four owner dirs above the floor, its bytes, sha256 and the runner's verdict: bytes equal to the owner repo's
# main AND classified expand by db/expand_check.py on a replay). MIGRATION_SHA256 is the bundle's digest; MIGRATION_FILE
# and MIGRATION_VERSION are empty. In one task, holding the apply lock on its own session for the whole run:
#   * read every registered key once; per owner, in number order, every unregistered copy above the floor is pending;
#   * apply each pending file while it is the next in line AND expand by its own header and lint AND has the runner's
#     verdict ok AND is not below the owner's highest registered key (out-of-order); stop that owner at the first file
#     that is not (it stays for a person: manual DB Migrate apply). Never skip past a gap (critic 2): the task checks
#     it itself, not only the runner. Above the owner's head the numbers must be contiguous (head + 1, + 2, …; the app
#     preflight requires owner max + 1), and an owner-main file the runner found missing here (bundle `not_copied`: its
#     copy PR has not merged yet) is a stop at its number, so a later copy never runs before it;
#   * each file goes through apply_file exactly like DB Migrate apply (role switch, lock risk exit 15, post-check exit
#     14, CIC validity exit 16, the wave wait for hot tables; no idle override, no snapshot: an expand file is never
#     destructive), a lock timeout (55P03) is retried after AUTO_LOCK_RETRY_S;
#   * a failed file stops its owner; the other owners still run; the exit code is the first failure's (0 when every
#     owner either applied everything or stopped at a file that needs a person). Exit 7 (a hot-table file during an
#     open rerun wave) is a deferral, not a failure: the owner stops, the next run retries.
# One `MIGRATE auto: …` line per decision and a final `MIGRATE auto-result {json}` line that the workflow summarises.
AUTO_OWNERS = ("cis", "booking", "tripplanner", "crm")            # never roles/ (master files stay manual)
# replay_migrations.KEY_PREFIX / check_migration_copies.OWNERS (db/tests/test_aa993_apply_pending.py keeps them equal).
AUTO_KEY_PREFIX = {"cis": "", "booking": "bk-", "tripplanner": "tp-", "crm": "crm-"}
# Legacy gaps: unregistered copies at or below this number are never pending (CIS 232, 252, 263 ran by hand before
# self-registration; AA-CIS-App api/core/readiness.py LEGACY_CIS_BASELINE = 263). The other owners have no gap.
AUTO_APPLY_FLOOR = {"cis": 263}
AUTO_LOCK_RETRY_S = (30, 90)            # 55P03: two more tries, after 30 s and 90 s
BUNDLE_KIND = "aa993-apply-pending"
REGISTERED_SQL = "SELECT version FROM shared.schema_versions"
AUTO_FILE_RE = re.compile(r"^(cis|booking|tripplanner|crm)/([0-9]{3})_[a-z0-9_]+\.sql$")


# Why a `stop` step ends an owner (AA-993 M3 review): every kind needs a person, so every stop reaches the run's manual
# list and a note on the file's copy PR (db/apply_pending.py STOP_NOTES says what the person does for each kind).
STOP_OUT_OF_ORDER = "out-of-order"      # below the owner's highest registered key
STOP_NOT_COPIED = "not-copied"          # on the owner's main, its copy PR has not merged (bundle not_copied)
STOP_DUPLICATE = "duplicate"            # two copies with one number
STOP_GAP = "gap"                        # the owner's next number is neither registered nor copied
STOP_CONTRACT = "contract"              # no expand header
STOP_LINT = "lint"                      # expand header, lint error(s)
STOP_REFUSED_BYTES = "refused-bytes"    # runner: the copy is not byte-identical to the owner's main (or no clone)
STOP_REFUSED_CLASSIFY = "refused-classify"  # runner: expand_check --classify on the replay said contract
STOP_NO_EVIDENCE = "no-evidence"        # runner: no classify result for the file
STOP_REFUSED = "refused"                # runner: any other verdict (or none)
STOP_KINDS = (STOP_OUT_OF_ORDER, STOP_NOT_COPIED, STOP_DUPLICATE, STOP_GAP, STOP_CONTRACT, STOP_LINT,
              STOP_REFUSED_BYTES, STOP_REFUSED_CLASSIFY, STOP_NO_EVIDENCE, STOP_REFUSED)
# The bundle's per-file `verdict_kind` (db/apply_pending.py build): "ok" or one of the runner refusal kinds.
VERDICT_KINDS = ("ok", STOP_REFUSED_BYTES, STOP_REFUSED_CLASSIFY, STOP_NO_EVIDENCE, STOP_REFUSED)


@dataclass
class AutoStep:
    path: str                           # owner/NNN_name.sql
    version: str
    action: str                         # apply | stop
    reason: str = ""
    kind: str = ""                      # stop only: one of STOP_KINDS


def auto_version(owner: str, number: int) -> str:
    return f"{AUTO_KEY_PREFIX[owner]}{number:03d}"


def plan_pending(files: list, registered) -> dict:
    """Pure (also the runner-side dry run): {owner: {"head": key or None, "steps": [AutoStep], "legacy": n}}.

    files: [{"path", "sql", "verdict"}] (verdict "ok", or why the runner refuses the file), plus the runner's
    {"path", "not_copied": True} entries (on the owner's main, not copied here yet); registered: every key in
    shared.schema_versions. Per owner, the unregistered files above AUTO_APPLY_FLOOR in number order: `apply` while
    each one is copied, the next number (head + 1, then + 1 per step: never past a gap, critic 2), expand (header,
    lint), verdict ok and not below the owner's highest registered key; the first that is not ends the owner's steps
    with `stop`."""
    registered = set(registered)
    out = {}
    for owner in AUTO_OWNERS:
        prefix = AUTO_KEY_PREFIX[owner]
        mine = sorted(int(k[len(prefix):]) for k in registered
                      if re.fullmatch(rf"{re.escape(prefix)}[0-9]{{3}}", k))
        head = mine[-1] if mine else 0
        floor = AUTO_APPLY_FLOOR.get(owner, 0)
        entries = []
        for f in files:
            m = AUTO_FILE_RE.match(f["path"])
            if m and m.group(1) == owner:
                entries.append((int(m.group(2)), f))
        entries.sort(key=lambda e: (e[0], e[1]["path"]))
        steps, legacy = [], 0
        expected = max(head, floor) + 1            # the only number that may run next (then + 1 per applied file)
        for number, f in entries:
            version = auto_version(owner, number)
            if version in registered:
                continue
            if number <= floor:
                legacy += 0 if f.get("not_copied") else 1
                continue
            reason, kind = "", ""
            if number < head:
                kind = STOP_OUT_OF_ORDER
                reason = (f"out-of-order: below the owner's highest registered key {auto_version(owner, head)}; "
                          f"manual DB Migrate apply")
            elif f.get("not_copied"):
                kind = STOP_NOT_COPIED
                reason = (f"not copied yet: on the {owner} owner repo's main but not in db/migrations/{owner}/ (its "
                          f"migration-sync copy PR has not merged); nothing after it runs before it")
            elif number < expected:
                kind = STOP_DUPLICATE
                reason = f"duplicate number: {version} is already pending in this run; the copies must be fixed"
            elif number > expected:
                kind = STOP_GAP
                reason = (f"gap: {auto_version(owner, expected)} is neither registered nor copied here; nothing past a "
                          f"gap is applied (the owner's next file must be its head + 1)")
            else:
                d = parse_directives(f["sql"])
                errs = lint(f["sql"], d, f["path"])[0]
                if not d.expand:
                    kind = STOP_CONTRACT
                    reason = "contract (no `-- migrate: expand` header): manual DB Migrate apply"
                elif errs:
                    kind = STOP_LINT
                    reason = f"expand header but {len(errs)} lint error(s): {errs[0]}"
                elif f.get("verdict") != "ok":
                    vk = f.get("verdict_kind")
                    kind = vk if vk in VERDICT_KINDS and vk != "ok" else STOP_REFUSED
                    reason = f"refused on the runner: {f.get('verdict') or 'no verdict'}"
            if reason:
                steps.append(AutoStep(f["path"], version, "stop", reason, kind))
                break
            steps.append(AutoStep(f["path"], version, "apply"))
            expected = number + 1
        out[owner] = {"head": auto_version(owner, head) if mine else None, "steps": steps, "legacy": legacy}
    return out


def not_copied_entry(path: str) -> dict:
    """A plan_pending entry for an owner-main file that has no copy here yet: always a stop, never SQL to run."""
    return {"path": path, "sql": "", "verdict": "not copied", "not_copied": True}


def read_bundle(raw: bytes) -> list:
    """The bundle's files after the shape and per-file sha256 checks, plus a not_copied_entry per path of the bundle's
    `not_copied` list (owner-main files the runner found missing here; stops only, so the task may trust them as is);
    ValueError names the first problem."""
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict) or data.get("kind") != BUNDLE_KIND or data.get("format") != 1:
        raise ValueError(f"not an apply-pending bundle (kind {BUNDLE_KIND}, format 1)")
    files, seen, numbers = [], set(), set()
    for f in data.get("files") or []:
        path, sql = f.get("path", ""), f.get("sql")
        if not AUTO_FILE_RE.match(path) or not isinstance(sql, str) or path in seen:
            raise ValueError(f"bundle entry {path!r}: not an owner-dir copy path, no SQL, or listed twice")
        if hashlib.sha256(sql.encode("utf-8")).hexdigest() != f.get("sha256"):
            raise ValueError(f"bundle entry {path}: sha256 mismatch")
        seen.add(path)
        numbers.add(path[:path.index("_")])
        vk = f.get("verdict_kind", STOP_REFUSED)
        if vk not in VERDICT_KINDS:
            raise ValueError(f"bundle entry {path}: verdict_kind {vk!r} is not one of {', '.join(VERDICT_KINDS)}")
        files.append({"path": path, "sql": sql, "verdict": f.get("verdict", ""), "verdict_kind": vk})
    missing = data.get("not_copied") or []
    if not isinstance(missing, list):
        raise ValueError("bundle not_copied: not a list of owner-dir paths")
    for path in missing:
        if not isinstance(path, str) or not AUTO_FILE_RE.match(path) or path[:path.index("_")] in numbers:
            raise ValueError(f"bundle not_copied entry {path!r}: not an owner-dir path, or its number has a copy "
                             f"or is listed twice")
        numbers.add(path[:path.index("_")])
        files.append(not_copied_entry(path))
    return files


async def run_apply_pending(env, fetch, connect, sleep, get_secret=_get_secret) -> int:
    raw = fetch(env["MIGRATION_URL"])
    digest = hashlib.sha256(raw).hexdigest()
    if digest != env.get("MIGRATION_SHA256"):
        log(f"sha256 mismatch: got {digest}")
        return 2
    try:
        files = read_bundle(raw)
    except (ValueError, UnicodeDecodeError) as e:
        log(f"ERROR: apply-pending: {e}")
        return 10
    log(f"apply-pending: bundle sha256={digest[:12]} files={len(files)}")
    # Never an idle override or a snapshot here: expand files skip the job-table wait by rule, never destructive.
    file_env = {k: v for k, v in env.items() if k not in ("MIGRATION_IDLE_OVERRIDE", "MIGRATION_SNAPSHOT")}
    lock_conn = await connect(env["DATABASE_URL"], dict(DEFAULT_SETTINGS))
    result = {"bundle": digest[:12], "owners": {}, "exit": 0}
    try:
        if not await take_apply_lock(lock_conn, sleep, "apply-pending"):
            result["exit"] = 17
            log(f"auto-result {json.dumps(result, sort_keys=True)}")
            return 17
        registered = {r[0] for r in await lock_conn.fetch(REGISTERED_SQL)}
        plan = plan_pending(files, registered)
        code = 0
        for owner, p in plan.items():
            rows, failed = [], 0
            if p["legacy"]:
                log(f"auto: {owner}: {p['legacy']} legacy unregistered copy(ies) at or below "
                    f"{auto_version(owner, AUTO_APPLY_FLOOR[owner])} ignored (hand-applied before self-registration)")
            if not p["steps"]:
                log(f"auto: {owner}: nothing pending (head {p['head']})")
            for st in p["steps"]:
                if failed:
                    break
                if st.action == "stop":
                    log(f"auto: {owner}: STOP at {st.path} ({st.version}): {st.reason}")
                    rows.append({"file": st.path, "version": st.version, "status": "manual", "kind": st.kind,
                                 "reason": st.reason})
                    break
                sql = next(f["sql"] for f in files if f["path"] == st.path)
                log(f"auto: {owner}: apply {st.path} ({st.version})")
                rc = await _apply_with_retry(file_env, sql, st, connect, sleep, get_secret)
                if rc == 7:
                    # Q5: it names a hot table and a rerun wave is open. Not a failure: the next run applies it.
                    log(f"auto: {owner}: DEFERRED {st.path}: a rerun wave is open; the next run retries it")
                    rows.append({"file": st.path, "version": st.version, "status": "deferred", "exit": rc})
                    break
                if rc:
                    failed = rc
                    code = code or rc
                    log(f"auto: {owner}: FAILED {st.path} exit {rc}; later {owner} files wait for the next run")
                    rows.append({"file": st.path, "version": st.version, "status": "failed", "exit": rc})
                else:
                    rows.append({"file": st.path, "version": st.version, "status": "applied"})
            result["owners"][owner] = {"head_before": p["head"], "legacy": p["legacy"], "files": rows}
        result["exit"] = code
        log(f"auto-result {json.dumps(result, sort_keys=True)}")
        return code
    finally:
        await lock_conn.close()


async def _apply_with_retry(env, sql: str, st: AutoStep, connect, sleep, get_secret) -> int:
    for attempt, wait in enumerate((0,) + AUTO_LOCK_RETRY_S):
        if wait:
            log(f"auto: lock timeout on {st.path}; retry {attempt}/{len(AUTO_LOCK_RETRY_S)} in {wait} s")
            await sleep(wait)
        info = {}
        rc = await apply_file(env, sql, st.path, st.version, "apply", connect=connect, sleep=sleep,
                              get_secret=get_secret, lock_held=True, info=info)
        if not (rc == 6 and info.get("sqlstate") == "55P03"):
            return rc
    return rc


def inspect_script(path: str, out=sys.stdout) -> int:
    """DB Migrate "Validate input" for mode=run-script: {"errors": [...]} as JSON, exit 1 on any."""
    with open(path, encoding="utf-8") as f:
        errors = script_errors(f.read(), path)
    print(json.dumps({"errors": errors}), file=out)
    return 1 if errors else 0


def inspect(path: str, out=sys.stdout) -> int:
    with open(path, encoding="utf-8") as f:
        sql = f.read()
    d = parse_directives(sql)
    errors, warnings = lint(sql, d, path)
    print(json.dumps({**d.as_json(), "errors": errors, "warnings": warnings}), file=out)
    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--inspect":
        sys.exit(inspect(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "--inspect-script":
        sys.exit(inspect_script(sys.argv[2]))
    sys.exit(asyncio.run(run_task()))
