"""Runs ONE migration inside a one-off ECS task on the CIS api image (RDS is VPC-private).

Started by .github/workflows/db-migrate.yml, which uploads this file and the migration to S3 and
passes presigned URLs. Uses only the image's own Python + asyncpg and the task's DATABASE_URL
(Secrets Manager, task definition) — nothing from the app code.

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
`shared.rerun_wave` rows, whether it is busy. Busy = any queued (any run_after) or running row of a
kind not in IDLE_EXEMPT_KINDS, or an open wave. check only reports. apply (once the version is known
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
the RDS master and are refused under any other login. The idle check and the registry reads run as
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
freeze from S1 to S22 bites (the master is not a member of catalog_owner and never becomes one; from
S22 db_migrator is), and where a db_migrator without cis_app would show up.

Exit codes: 0 ok · 2 sha256 mismatch · 3 file ran but did not register · 4 lint error ·
5 destructive apply without a snapshot · 6 PostgreSQL error (lock/statement timeout included) ·
7 apply refused: a job table is busy or a rerun wave is open · 8 role refused (roles/ under a
non-master login, login not a member of the live owner, the owner cannot register the version,
unknown dir, a file that cannot run under the switch, or a `SET LOCAL ROLE` target the login role
is not a member of) · 9 ownership post-check failed (rolled
back; for a no-transaction file the statements before the registration stay committed and the
version is not registered), or the check after COMMIT found something that ran at COMMIT (committed
and registered: clean up by hand).

Local, no database and no asyncpg needed (CI lint and the DB Migrate "Validate input" step):
  python3 db/run_migration.py --inspect db/migrations/cis/230_x.sql
prints the parsed directives as JSON and exits 1 on a lint error.
"""
import asyncio
import hashlib
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass, field

DEFAULT_SETTINGS = {"lock_timeout": "5s", "statement_timeout": "15min", "application_name": "db-migrate"}
OVERRIDABLE = ("lock_timeout", "statement_timeout")
FLAGS = ("no-transaction", "destructive")

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
}
IDLE_WAITS = 3          # apply re-checks this many times before it refuses …
IDLE_WAIT_S = 20        # … this many seconds apart
JOB_TABLES_SQL = """
SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relname = 'job' AND c.relkind IN ('r', 'p')
   AND EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = c.oid AND a.attname = 'status' AND NOT a.attisdropped)
 ORDER BY n.nspname"""
JOB_BUSY_SQL = """
SELECT kind, status, count(*)::int AS n,
       count(*) FILTER (WHERE status = 'queued' AND run_after <= now())::int AS due
  FROM {table} WHERE status IN ('queued', 'running') AND NOT (kind = ANY($1::text[]))
 GROUP BY kind, status ORDER BY kind, status"""
WAVE_TABLE_SQL = "SELECT to_regclass('shared.rerun_wave') IS NOT NULL"
OPEN_WAVES_SQL = "SELECT count(*)::int FROM shared.rerun_wave WHERE status = 'open'"


# ── X1 owner registry mirror (db/owners.yaml; db/tests/test_owners_registry.py keeps them equal) ──
# The task gets only this file and the SQL (presigned URLs), so the registry facts it needs are
# constants here, not a YAML read (no PyYAML in the runner, no new env var).
MASTER_ROLE = "aa_cis_admin"      # RDS master: runs roles/ files; break-glass after X1 S22
ROLES_DIR = "roles"               # Infra-native files, key rl-NNN


@dataclass(frozen=True)
class OwnerDir:
    anchor_schema: str            # its live owner decides the role a file runs as (XD8)
    schemas: tuple                # every schema of the owner (ownership post-check, 244/245 lists)
    set_local_roles: frozenset    # the only `SET LOCAL ROLE` targets the lint allows in the dir
    role_lint_from: int           # first file number the role lint applies to (> today's head)
    view_owner_roles: frozenset = frozenset()   # may own objects a switched file creates, besides the owner


OWNER_DIRS = {
    "cis": OwnerDir("shared",
                    ("acp_contract", "acp_deliver", "acp_gold_output", "acp_shared", "acp_silver_s2",
                     "acp_silver_s3", "acp_silver_s4", "catalog", "geo", "gold_aa_internal", "shared",
                     "silver_aa_internal"),
                    frozenset({"catalog_owner", "cis_owner", "cis_app"}), 243, frozenset({"catalog_owner"})),
    "booking": OwnerDir("booking", ("booking",), frozenset(), 14),
    "tripplanner": OwnerDir("tripplanner", ("tripplanner",), frozenset(), 13),
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
# S22 catalog.* view changes are frozen (X1 review, S241): the lint asks for the recipe, the runner's
# membership pre-check (SET_ROLE_REACH_SQL) refuses it at `check` time while the login is the master.
CATALOG_VIEW_DDL_RE = re.compile(
    r"\b(?:CREATE(?:\s+OR\s+REPLACE)?(?:\s+(?:TEMP|TEMPORARY|RECURSIVE))*|ALTER|DROP)\s+(?:MATERIALIZED\s+)?"
    r"VIEW\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?CATALOG\s*\.")
CATALOG_FREEZE = ("catalog.* view changes are frozen from X1 S1 until X1 S22: a cis/ file changes a catalog view "
                  "only with the catalog recipe (GRANT CREATE ON SCHEMA catalog TO catalog_owner; SET LOCAL ROLE "
                  "catalog_owner; …; SET LOCAL ROLE cis_owner; REVOKE CREATE …), which needs the DB Migrate login "
                  "to be a member of catalog_owner — db_migrator from S22; the master never is (X1 plan §1.4, "
                  "AA-CIS-App CONTEXT.md)")
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
    settings: dict = field(default_factory=lambda: dict(DEFAULT_SETTINGS))
    errors: list = field(default_factory=list)

    def as_json(self) -> dict:
        return {"no_transaction": self.no_transaction, "destructive": self.destructive,
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
    return errors, warnings


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
        if not self.busy:
            return f"idle: {self.name} running=0 queued=0{exempt}"
        return (f"busy: {self.name} running={self.running} queued={self.queued} due={self.due} "
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
            rows = await conn.fetch(JOB_BUSY_SQL.format(table=f"{_quote_ident(schema)}.job"), list(exempt))
        except Exception as e:
            st.error = _err(e)
        else:
            for r in rows:
                if r["status"] == "running":
                    st.running += r["n"]
                else:
                    st.queued += r["n"]
                    st.due += r["due"]
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
    (catalog view freeze until S22), cis_app once the login is db_migrator (rl-002 must grant it)."""
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


async def run_switched(conn, sql: str, d: Directives, plan: RolePlan, owner_dir: str) -> int:
    """Runs the file as plan.run_as; returns 0, or 9 when the ownership post-check fails.

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
        await conn.execute(f"SET ROLE {role}")
        for k, s in enumerate(stmts[:-1], 1):
            log(f"statement {k}/{len(stmts)} (line {s.line}) …")
            await conn.execute(s.text)
        await conn.execute("RESET ROLE")
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
        await conn.execute(commit.text)
    late = await _post_commit_findings(conn, before, plan, owner_dir)
    if late:
        _log_post_commit(late, plan)
        return 9
    return 0


def _fetch(url: str) -> bytes:
    return urllib.request.urlopen(url, timeout=30).read()


async def _connect(dsn: str, settings: dict):
    import asyncpg   # only inside the task: the lint path and CI run without asyncpg
    return await asyncpg.connect(dsn, timeout=30, server_settings=settings)


async def run_task(env=None, fetch=_fetch, connect=_connect, sleep=asyncio.sleep) -> int:
    env = os.environ if env is None else env
    raw = fetch(env["MIGRATION_URL"])
    digest = hashlib.sha256(raw).hexdigest()
    if digest != env["MIGRATION_SHA256"]:
        log(f"sha256 mismatch: got {digest}")
        return 2
    version, mode = env["MIGRATION_VERSION"], env["MIGRATION_MODE"]
    log(f"file={env['MIGRATION_FILE']} version={version} sha256={digest[:12]} mode={mode}")

    sql = raw.decode("utf-8")
    d = parse_directives(sql)
    file = env.get("MIGRATION_FILE") or ""
    errors, warnings = lint(sql, d, file)
    log(f"directives: transaction={'no' if d.no_transaction else 'yes'} destructive={'yes' if d.destructive else 'no'} "
        f"lock_timeout={d.settings['lock_timeout']} statement_timeout={d.settings['statement_timeout']}")
    for w in warnings:
        log(f"WARNING: {w}")
    if errors:
        for e in errors:
            log(f"ERROR: {e}")
        return 4

    conn = await connect(env["DATABASE_URL"], d.settings)
    owner_dir = file.split("/", 1)[0]
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
        try:
            if plan.switch:
                code = await run_switched(conn, sql, d, plan, owner_dir)
                if code:
                    return code
            elif d.no_transaction:
                stmts = split_statements(sql)
                for k, s in enumerate(stmts, 1):
                    log(f"statement {k}/{len(stmts)} (line {s.line}) …")
                    await conn.execute(s.text)          # one statement per message: autocommit
            else:
                await conn.execute(sql)                 # simple protocol: the file's own BEGIN/COMMIT
        except Exception as e:                          # asyncpg.PostgresError and friends
            state = getattr(e, "sqlstate", "") or ""
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
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        if not applied:
            log("ERROR: file ran but did not register its version in shared.schema_versions")
            return 3
        log(f"after: applied_at={applied}")
        return 0
    finally:
        await conn.close()


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
    sys.exit(asyncio.run(run_task()))
