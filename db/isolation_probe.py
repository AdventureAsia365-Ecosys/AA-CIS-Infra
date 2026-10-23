"""Read-only DB isolation probe of the shared RDS (X1 plan S2, roadmap U-16, P0-9).

Started by .github/workflows/db-isolation-probe.yml exactly like the schema dump: the workflow uploads
this file to S3, a one-off ECS task (the migrator task definition aa-cis-dev-db-migrate since X1 S12,
with the api service's image) downloads it through a presigned URL and execs it. Python + asyncpg + boto3 of the image
only. Configuration comes as one JSON argument (argv), so the task needs no new environment variable:
  {"cis_runtime_secret": "<valueFrom of the api task definition's database secret>",
   "api_task_definition": "<arn>", "region": "us-west-1", "ssl": "require"}
For a local run against a throwaway cluster, "dsn_file" names a JSON file {secret id or "catalog": DSN}
and "ssl": "disable"; nothing else changes.

Read-only by construction: every session sets default_transaction_read_only, runs in one READ ONLY
transaction that is ROLLED BACK at the end, statement_timeout 30s, lock_timeout 3s. Each probe statement
runs in its own savepoint (an expected 42501 does not abort the rest; set_config is undone). No row
value is ever printed: counts, role names, object names and SQLSTATEs only; tenants are labelled
(`master`, `t1`, `t2`, …), never printed by id; a DSN or password never reaches the log.

**Isolation evidence only from the role under test.** Every cross-app read, every RLS count and the
tenant matrix run through that role's own login (its own DSN secret): `aa-cis/dev/rds-app-user`
(aa_app_user), `booking/dev/database-url` (booking), `tripplanner/dev/database-url` (tripplanner),
`aa-cis/dev/rds-cis-app` (cis_app, from X1 S17) and the CIS runtime = whatever secret the running api
task definition injects. The "catalog" login (the task's own database DSN: the RDS master until X1 S22,
then db_migrator) only reads the catalog (attributes, memberships, owners, grants, policies, sessions)
and reference counts (tenant_tour_versions; the RLS parity tables of rls.force_parity.cis_app). The master and db_migrator are members of owner roles (and db_migrator of
catalog_owner, whose catalog_owner_aa_master_read policies apply to its members), so rows they can see
are never tenant-isolation evidence; the probe never grants itself a role and never uses SET ROLE.

Cells and their state keys. A cell that cannot pass until a later X1 step carries a state key read
LIVE at run time, not a PR number: shared.schema_versions rows (rl-001, 243, 244, rl-002), the live
owner of each owner's anchor schema together with its transfer key (`<owner>_transferred`: bk-014 /
tp-013 / 245 registered AND booking / tripplanner / shared owned by bk_owner / tp_owner / cis_owner;
registry rows are never deleted, so after a planned rollback — a roles/ undo file that gives the objects
back to the master — the key turns false again and the cells go back to pending instead of red), the
running api task definition's database secret (aa-cis/dev/rds-cis-app = X1 S18), the content of
aa-cis/dev/rds-cis-app (a cis_app DSN = X1 S17), the "password set" marker that DB Migrate
mode=set-password writes on the role (COMMENT ON ROLE cis_app, PASSWORD_MARKER; until then a cis_app
login fails with 28P01 and its cells stay pending with a warning) and the catalog login (not the master
= X1 S22). While its key is false a cell is `pending` (it may fail; if it already passes it is `ready`);
once the key is true it is expected and a failure fails the job. So the probe stays green between the
applies of a train with no expectation PR. A pending cell without a state key (none today) fails the
job as soon as it passes ("drop the pending flag").

Output: one line per record on stdout, `PROBE header {json}`, `PROBE cell {json}` …, `PROBE summary
{json}`; the workflow joins them into probe.json and a step-summary table. Exit 0 = no failing cell,
1 = at least one failing cell, 2 = the probe could not run (catalog login or state keys unreadable).

Runtime grants (X1 review S241): the failure an owner transfer most likely causes is not a cross-app
read but a runtime role losing a grant — an object the new owner creates that its runtime cannot use
(42501 after deploy). Cells runtime_grants.<owner> (baseline privilege on every existing object, as
has_*_privilege catalog facts) and default_acl.<owner> (pg_default_acl FOR ROLE <live owner> grants the
runtime role; no FOR ROLE master row left once transferred) cover it; consumer.contract_grants keeps
the contract reads of other apps (booking → tripplanner.v_inquiry_outbox, …); a grant whose migration is
newer than the cell set (owners.yaml expected_from, e.g. cis_app → booking.v_ops_* from bk-017, AA-858) has
its own cell consumer.contract_grants.<key>, pending until that key is registered.

RLS parity (X1 S16, S243 correction): the master reads the FORCE RLS tables unfiltered (rds_superuser,
AA-817 probe v2) and most CIS code sets no tenant GUC, so CIS 244 gives cis_app a permissive USING (true)
policy on every RLS table. Cell rls.force_parity.cis_app counts each table of RLS_PARITY_TABLES (the 8
FORCE tables + tenant_tour_versions) through cis_app's own login, without a GUC and under a forged one,
and compares with the catalog login's reference counts taken before and after (a concurrent insert falls
between them). Expected from 244 + the cis_app password (S17).

Mirrors db/owners.yaml (schemas, anchor schemas, owner roles, transfer keys, runtime secrets, view
owners, runtime privileges, contract consumer grants on single objects, RLS allowlist, master role):
db/tests/test_owners_registry.py fails when they disagree.
"""
import asyncio
import datetime
import json
import os
import re
import sys
import uuid
from dataclasses import dataclass, field
from urllib.parse import unquote, urlparse

PROBE = "db-isolation-probe"
FORMAT = 1
APP_NAME = "db-isolation-probe"
SESSION_SETTINGS = {
    "application_name": APP_NAME,
    "default_transaction_read_only": "on",
    "statement_timeout": "30s",
    "lock_timeout": "3s",
    "idle_in_transaction_session_timeout": "120s",
}
MASTER_TENANT = "00000000-0000-0000-0000-000000000001"   # AA master tenant (CIS 239), public constant
PLATFORM_SCOPE = "platform"                              # acp_contract.tour_atoms.owner_scope of AA's atoms (CIS 266)
SAMPLE = 10                                              # names shown per finding


# ── db/owners.yaml mirror (db/tests/test_owners_registry.py keeps them equal) ──
MASTER_ROLE = "aa_cis_admin"


@dataclass(frozen=True)
class RuntimePrivileges:
    """What one runtime role must hold in its owner's schemas (owners.yaml runtime_privileges)."""
    role: str
    schemas: tuple                     # the schemas the role works in (cis_app: every CIS schema but catalog)
    objects: tuple                     # ((kind, (privilege, …)), …) on every existing object, kind in OBJECT_KINDS
    default_acl: tuple                 # ((objects word, (privilege, …)), …) FOR ROLE <live owner> IN SCHEMA s


@dataclass(frozen=True)
class ProbeOwner:
    schemas: tuple                     # owners.yaml schemas
    anchor_schema: str                 # its live owner says whether the transfer is in force (as the runner, XD8)
    owner_role: str                    # NOLOGIN target owner (X1)
    transfer_key: str                  # shared.schema_versions key of the ownership transfer
    runtime_secrets: tuple             # ((runtime role, Secrets Manager id), …)
    view_owner_roles: frozenset = frozenset()   # may own views/matviews in the owner's schemas
    runtime_privileges: tuple = ()     # (RuntimePrivileges, …)
    runtime_privileges_from: str = ""  # state key from which they are expected ("" = <owner>_transferred)


BASELINE = (("relation", ("SELECT",)), ("sequence", ("USAGE",)), ("function", ("EXECUTE",)))
CIS_RUNTIME_SCHEMAS = ("acp_contract", "acp_deliver", "acp_gold_output", "acp_shared", "acp_silver_s2",
                       "acp_silver_s3", "acp_silver_s4", "geo", "gold_aa_internal", "shared", "silver_aa_internal")
DML = ("DELETE", "INSERT", "SELECT", "UPDATE")
OWNERS = {
    "cis": ProbeOwner(
        ("acp_contract", "acp_deliver", "acp_gold_output", "acp_shared", "acp_silver_s2", "acp_silver_s3",
         "acp_silver_s4", "catalog", "geo", "gold_aa_internal", "shared", "silver_aa_internal"),
        "shared", "cis_owner", "245",
        (("cis_app", "aa-cis/dev/rds-cis-app"), ("aa_app_user", "aa-cis/dev/rds-app-user")),
        frozenset({"catalog_owner"}),
        (RuntimePrivileges("cis_app", CIS_RUNTIME_SCHEMAS, BASELINE,
                           (("tables", DML), ("sequences", ("SELECT", "UPDATE", "USAGE")),
                            ("functions", ("EXECUTE",)))),),
        "244"),
    "booking": ProbeOwner(("booking",), "booking", "bk_owner", "bk-014", (("booking", "booking/dev/database-url"),),
                          runtime_privileges=(RuntimePrivileges(
                              "booking", ("booking",), BASELINE,
                              (("tables", DML), ("sequences", ("SELECT", "USAGE")), ("functions", ("EXECUTE",)))),)),
    "tripplanner": ProbeOwner(("tripplanner",), "tripplanner", "tp_owner", "tp-013",
                              (("tripplanner", "tripplanner/dev/database-url"),),
                              runtime_privileges=(RuntimePrivileges(
                                  "tripplanner", ("tripplanner",), BASELINE,
                                  (("tables", DML), ("sequences", ("SELECT", "USAGE")))),)),
}
# pg_default_acl.defaclobjtype of each owners.yaml default_acl word.
DEFACL_OBJTYPE = {"tables": "r", "sequences": "S", "functions": "f"}
OBJECT_KINDS = ("relation", "sequence", "function")
# Contract consumer grants on ONE named object (owners.yaml consumer_grants, status contract): the
# grantee must keep them through every transfer (an ACL is rewritten to the new owner, not dropped).
# Wildcard objects (catalog.* views) are left out: the helper view catalog._tour_day_text is not granted.
# Fourth field = owners.yaml expected_from: the owner's schema_versions key of the migration that creates the
# object and the grant. "" = always expected (cell consumer.contract_grants); a key = its own cell
# consumer.contract_grants.<key>, pending until the key is registered, so merging the registry entry before the
# DB Migrate apply never turns the nightly probe red (AA-858).
CONSUMER_GRANTS = (
    ("booking", ("EXECUTE",), "geo.name_norm(text)", ""),
    ("booking", ("USAGE", "SELECT"), "tripplanner.v_inquiry_outbox", ""),
    ("tripplanner", ("EXECUTE",), "geo.name_norm(text)", ""),
    ("tripplanner", ("INSERT",), "shared.llm_call_log", ""),
    ("cis_app", ("USAGE", "SELECT"), "booking.v_ops_funnel_daily", "bk-017"),
    ("cis_app", ("USAGE", "SELECT"), "booking.v_ops_case_status", "bk-017"),
    ("cis_app", ("USAGE", "SELECT"), "tripplanner.v_ops_traffic_daily", "tp-015"),
)
CONSUMER_GRANT_KEYS = tuple(sorted({k for *_, k in CONSUMER_GRANTS if k}))
# DB Migrate mode=set-password (X1 S12) ends with COMMENT ON ROLE <role> IS '<marker> <UTC time> …': a
# role without it has never had a password set, so its login is not expected yet (X1 S17 window).
PASSWORD_MARKER = "x1:password-set"
# CIS tables with ENABLE (not FORCE) row level security that need no policy TO cis_app (owners.yaml
# cis.rls_enable_only_allowlist). Empty: every such table gets one in CIS 244 (X1 S16).
RLS_ENABLE_ONLY_ALLOWLIST = frozenset()
# Tables where cis_app must read every row like the platform runtime does today (owners.yaml
# cis.rls_parity_tables; CIS 244 parity policies, S243): the 8 FORCE RLS tables + tenant_tour_versions.
RLS_PARITY_TABLES = ("gold_aa_internal.content_exports", "gold_aa_internal.published_tours",
                     "gold_aa_internal.tenant_tour_versions", "gold_aa_internal.webhook_deliveries",
                     "shared.pipeline_runs", "silver_aa_internal.generated_content",
                     "silver_aa_internal.quality_scores", "silver_aa_internal.raw_tours",
                     "silver_aa_internal.seo_context")

# Tenant matrix scope of an RLS table (AA-859 wave 4). The tenant column, first match wins: tenant_id (uuid, or text on
# acp_deliver.tenant_tour_pages, CIS 265), else owner_scope (acp_contract.tour_atoms: 'platform' or the owning tenant's
# uuid as text, CIS 266). A table with neither whose policy reaches the tenant through a parent row: {table: (its key
# column, parent table, the parent's key column)}; the parent has a tenant_id and its own policy for the pool. An RLS
# table with neither a tenant column nor an entry here cannot be judged under a real tenant: its visible rows there are
# an error of the matrix cell (register the table here), never a silent pass.
TENANT_SCOPE_COLUMNS = ("tenant_id", "owner_scope")
PARENT_SCOPED = {
    "acp_shared.angle_gate_option": ("request_id", "acp_shared.angle_gate_request", "request_id"),       # CIS 241
    "acp_shared.quarter_plan_version": ("plan_id", "acp_shared.quarter_plan", "plan_id"),                 # CIS 265
}
UNJUDGED = "not judged: no tenant column and not PARENT_SCOPED"
# The only constants a tenant-pool policy may share with every tenant: the AA master catalog (CIS 239; 265 compares the
# text tenant_id of tenant_tour_pages with a '::text' literal) and AA's platform atoms (266). Any other constant in such
# a policy (another tenant's id) shares nothing: its rows stay cross-tenant.
SHARED_SCOPE_CONSTANTS = frozenset({MASTER_TENANT, PLATFORM_SCOPE})

CIS_SCHEMAS = OWNERS["cis"].schemas
CIS_APP = "cis_app"
CIS_APP_SECRET = dict(OWNERS["cis"].runtime_secrets)[CIS_APP]
TENANT_POOL = "aa_app_user"
RUNTIME_SECRETS = {role: secret for o in OWNERS.values() for role, secret in o.runtime_secrets}
# Runtime roles whose role cells are expected today (cis_app: from rl-001).
LEGACY_RUNTIME_ROLES = ("aa_app_user", "booking", "tripplanner")
CIS_RUNTIME = "cis_runtime"            # label: the login the running api task definition uses
FORBIDDEN_IN_CHAIN = ("rds_superuser", "pg_read_all_data", "pg_write_all_data", MASTER_ROLE)

CIS_APP_LOGIN_KEYS = ("cis_app_secret_ready", "cis_app_password_set")
# Cross-app reads (X1 plan S2): each must raise 42501 through the role's own login.
CROSS_APP = (
    ("booking", "tripplanner.sessions", ()),
    ("booking", "shared.tenants", ()),
    ("tripplanner", "booking.customers", ()),
    ("aa_app_user", "booking.customers", ()),
    ("aa_app_user", "tripplanner.sessions", ()),
    (CIS_APP, "booking.customers", ("cis_app_secret_ready", "cis_app_password_set")),
    (CIS_APP, "tripplanner.sessions", ("cis_app_secret_ready", "cis_app_password_set")),
    (CIS_RUNTIME, "booking.customers", ("cis_runtime_on_cis_app",)),
    (CIS_RUNTIME, "tripplanner.sessions", ("cis_runtime_on_cis_app",)),
)

VERSION_KEYS = ("rl-001", "243", "bk-014", "tp-013", "244", "rl-002", "245") + CONSUMER_GRANT_KEYS
TRANSFER_KEYS = {name: f"{name}_transferred" for name in OWNERS}
KEY_TEXT = {
    "rl-001": "rl-001 registered (X1 S3, first apply of the S8 train)",
    "243": "CIS 243 registered (X1 S4)",
    "bk-014": "bk-014 registered (X1 S6)",
    "tp-013": "tp-013 registered (X1 S7)",
    "244": "CIS 244 registered (X1 S16)",
    "rl-002": "rl-002 registered (X1 S20)",
    "245": "CIS 245 registered (X1 S21)",
    "booking_transferred": "bk-014 registered and schema booking owned by bk_owner (X1 S6)",
    "tripplanner_transferred": "tp-013 registered and schema tripplanner owned by tp_owner (X1 S7)",
    "cis_transferred": "245 registered and schema shared owned by cis_owner (X1 S21)",
    "cis_app_secret_ready": "aa-cis/dev/rds-cis-app holds a cis_app DSN (X1 S17, Nghiệp's hand edit)",
    "cis_app_password_set": (f"role cis_app carries the '{PASSWORD_MARKER}' comment of DB Migrate "
                             f"mode=set-password (X1 S17)"),
    "cis_runtime_on_cis_app": "the running api task definition injects aa-cis/dev/rds-cis-app (X1 S18)",
    "catalog_login_not_master": "the probe's catalog login is not the RDS master (X1 S22, db_migrator)",
    **{k: f"{k} registered (creates contract consumer grants, owners.yaml expected_from)" for k in CONSUMER_GRANT_KEYS},
}
NOTES = [
    "Isolation evidence (cross-app reads, RLS counts, tenant matrix) comes only from each role's own login.",
    "The catalog login (RDS master until X1 S22, then db_migrator) reads the catalog only; it is a member of "
    "owner roles (db_migrator also of catalog_owner), so what it can see is never tenant-isolation evidence.",
    "Read-only: READ ONLY transactions, rolled back; counts and names only, no row values, no tenant ids.",
]


# ── SQL (catalog login) ──
REGISTERED_SQL = "SELECT version FROM shared.schema_versions WHERE version = ANY($1::text[]) ORDER BY 1"
ROLE_SQL = """
SELECT rolname, rolcanlogin AS login, rolsuper AS super, rolbypassrls AS bypassrls,
       rolcreaterole AS createrole, rolcreatedb AS createdb, rolreplication AS replication,
       rolconnlimit AS connlimit, pg_catalog.shobj_description(oid, 'pg_authid') AS comment
  FROM pg_catalog.pg_roles WHERE rolname = $1"""
ANCHOR_SQL = """
SELECT nspname::text AS schema, pg_catalog.pg_get_userbyid(nspowner)::text AS owner
  FROM pg_catalog.pg_namespace WHERE nspname = ANY($1::text[])"""
# Objects of the schemas $2 on which role $1 lacks a baseline privilege ($3 relations, $4 sequences that
# are not identity sequences — INSERT needs no right on those —, $5 functions that are not trigger
# functions — a trigger fires without EXECUTE), plus USAGE on each schema (has_table_privilege alone
# ignores it). Extension members are left out. Catalog facts: nothing runs as $1.
RUNTIME_MISSING_SQL = """
WITH s AS (SELECT n.oid, n.nspname FROM pg_catalog.pg_namespace n WHERE n.nspname = ANY($2::text[])),
ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e')
SELECT kind, name, missing FROM (
    SELECT 'schema' AS kind, s.nspname::text AS name,
           CASE WHEN pg_catalog.has_schema_privilege($1, s.oid, 'USAGE') THEN NULL ELSE 'USAGE' END AS missing
      FROM s
    UNION ALL
    SELECT 'relation', s.nspname || '.' || c.relname,
           (SELECT pg_catalog.string_agg(x, ',') FROM pg_catalog.unnest($3::text[]) AS x
             WHERE NOT pg_catalog.has_table_privilege($1, c.oid, x))
      FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_class'::regclass AND ext.objid = c.oid)
    UNION ALL
    SELECT 'sequence', s.nspname || '.' || c.relname,
           (SELECT pg_catalog.string_agg(x, ',') FROM pg_catalog.unnest($4::text[]) AS x
             WHERE NOT pg_catalog.has_sequence_privilege($1, c.oid, x))
      FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
     WHERE c.relkind = 'S'
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_class'::regclass
                         AND d.objid = c.oid AND d.deptype = 'i')
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_class'::regclass AND ext.objid = c.oid)
    UNION ALL
    SELECT 'function', s.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
           (SELECT pg_catalog.string_agg(x, ',') FROM pg_catalog.unnest($5::text[]) AS x
             WHERE NOT pg_catalog.has_function_privilege($1, p.oid, x))
      FROM pg_catalog.pg_proc p JOIN s ON s.oid = p.pronamespace
     WHERE p.prokind IN ('f', 'p') AND p.prorettype <> 'pg_catalog.trigger'::pg_catalog.regtype
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_proc'::regclass AND ext.objid = p.oid)
) o
WHERE missing IS NOT NULL
ORDER BY 1, 2"""
# Default privileges in the schemas $1: per row FOR ROLE, object type and what it grants role $2.
DEFAULT_ACL_SQL = """
SELECT n.nspname::text AS schema, d.defaclobjtype::text AS objtype,
       pg_catalog.pg_get_userbyid(d.defaclrole)::text AS for_role,
       coalesce((SELECT pg_catalog.array_agg(a.privilege_type::text ORDER BY a.privilege_type)
                   FROM pg_catalog.aclexplode(d.defaclacl) a
                  WHERE a.grantee = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = $2)),
                '{}') AS privileges
  FROM pg_catalog.pg_default_acl d JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
 WHERE n.nspname = ANY($1::text[])
 ORDER BY 1, 2, 3"""
CHAIN_SQL = """
WITH RECURSIVE ch(roleid, depth, path) AS (
    SELECT m.roleid, 1, ARRAY[r.oid]
      FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid = m.member
     WHERE r.rolname = $1
    UNION ALL
    SELECT m.roleid, ch.depth + 1, ch.path || m.member
      FROM pg_catalog.pg_auth_members m JOIN ch ON m.member = ch.roleid
     WHERE ch.depth < 10 AND NOT m.roleid = ANY(ch.path))
SELECT DISTINCT pg_catalog.pg_get_userbyid(roleid)::text AS role FROM ch ORDER BY 1"""
# Everything a role owns in this database (indexes follow their table; array and relation row types
# follow their element / relation).
OWNED_SQL = """
SELECT kind, name FROM (
    SELECT 'database' AS kind, d.datname::text AS name, d.datdba AS owner
      FROM pg_catalog.pg_database d WHERE d.datname = pg_catalog.current_database()
    UNION ALL
    SELECT 'schema', n.nspname::text, n.nspowner FROM pg_catalog.pg_namespace n
    UNION ALL
    SELECT 'relation', n.nspname || '.' || c.relname, c.relowner
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind NOT IN ('i', 'I')
    UNION ALL
    SELECT 'function', n.nspname || '.' || p.proname, p.proowner
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    UNION ALL
    SELECT 'type', n.nspname || '.' || t.typname, t.typowner
      FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typrelid = 0 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type a WHERE a.typarray = t.oid)
) o
WHERE o.owner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = $1)
ORDER BY 1, 2"""
# Objects of the given schemas (schema itself included, extension members left out) that the owner
# role does NOT own; the caller allows view owners (catalog_owner) on views/matviews only.
NOT_OWNED_SQL = """
WITH s AS (
    SELECT n.oid, n.nspname, n.nspowner FROM pg_catalog.pg_namespace n WHERE n.nspname = ANY($1::text[]))
SELECT kind, name, pg_catalog.pg_get_userbyid(owner)::text AS owner FROM (
    SELECT 'schema' AS kind, s.nspname::text AS name, s.nspowner AS owner FROM s
    UNION ALL
    SELECT CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview' WHEN 'S' THEN 'sequence'
                          ELSE 'relation' END,
           s.nspname || '.' || c.relname, c.relowner
      FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
     WHERE c.relkind NOT IN ('i', 'I')
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_class'::regclass
                         AND d.objid = c.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'function', s.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
           p.proowner
      FROM pg_catalog.pg_proc p JOIN s ON s.oid = p.pronamespace
     WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_proc'::regclass
                         AND d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'type', s.nspname || '.' || t.typname, t.typowner
      FROM pg_catalog.pg_type t JOIN s ON s.oid = t.typnamespace
     WHERE t.typrelid = 0 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type a WHERE a.typarray = t.oid)
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_type'::regclass
                         AND d.objid = t.oid AND d.deptype = 'e')
) o
WHERE pg_catalog.pg_get_userbyid(owner) <> $2
ORDER BY 1, 2"""
OWNER_GRANTS_SQL = """
SELECT pg_catalog.has_schema_privilege($1, 'shared', 'USAGE') AS usage_shared,
       pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'SELECT') AS select_registry,
       pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'INSERT') AS insert_registry"""
REGISTRY_WRITES_SQL = """
SELECT pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'INSERT') AS insert,
       pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'UPDATE') AS update,
       pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'DELETE') AS delete,
       pg_catalog.has_table_privilege($1, 'shared.schema_versions', 'TRUNCATE') AS truncate"""
ENABLE_ONLY_SQL = """
SELECT n.nspname || '.' || c.relname AS fq,
       EXISTS (SELECT 1 FROM pg_catalog.pg_policies p
                WHERE p.schemaname = n.nspname AND p.tablename = c.relname
                  AND p.permissive = 'PERMISSIVE' AND $2 = ANY(p.roles)) AS has_policy
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p')
   AND c.relrowsecurity AND NOT c.relforcerowsecurity
 ORDER BY 1"""
RLS_TABLES_SQL = """
SELECT n.nspname || '.' || c.relname AS fq,
       pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(c.relname) AS q,
       c.relforcerowsecurity AS forced,
       (SELECT a.attname::text FROM pg_catalog.pg_attribute a
         WHERE a.attrelid = c.oid AND a.attname = ANY($2::text[]) AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY pg_catalog.array_position($2::text[], a.attname::text) LIMIT 1) AS tenant_col
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p') AND c.relrowsecurity
 ORDER BY 1"""
# Permissive SELECT/ALL policies that reach the tenant pool role (TO it or TO public): their constant
# tenant ids / owner scopes in SHARED_SCOPE_CONSTANTS are rows the role may read under any tenant (the AA
# master catalog, CIS 239 / 265; the platform atoms, 266).
POOL_POLICIES_SQL = """
SELECT schemaname || '.' || tablename AS fq, coalesce(qual, '') AS qual
  FROM pg_catalog.pg_policies
 WHERE schemaname = ANY($1::text[]) AND permissive = 'PERMISSIVE' AND cmd IN ('SELECT', 'ALL')
   AND ($2 = ANY(roles) OR 'public' = ANY(roles))"""
TENANTS_SQL = "SELECT tenant_id::text FROM shared.tenants ORDER BY created_at, tenant_id"
TTV = "gold_aa_internal.tenant_tour_versions"
SESSIONS_SQL = """
SELECT coalesce(nullif(application_name, ''), '(empty)') AS app, count(*)::int AS n
  FROM pg_catalog.pg_stat_activity
 WHERE usename = $1 AND pid <> pg_catalog.pg_backend_pid() AND backend_type = 'client backend'
   AND coalesce(application_name, '') <> $2
 GROUP BY 1 ORDER BY 1"""
CONNLIMIT_SQL = "SELECT rolconnlimit FROM pg_catalog.pg_roles WHERE rolname = $1"
CONSUMER_SQL = {
    "exists_relation": "SELECT pg_catalog.to_regclass($1) IS NOT NULL",
    "exists_function": "SELECT pg_catalog.to_regprocedure($1) IS NOT NULL",
    "USAGE": "SELECT pg_catalog.has_schema_privilege($1, pg_catalog.split_part($2, '.', 1), 'USAGE')",
    "relation": "SELECT pg_catalog.has_table_privilege($1, $2, $3)",
    "function": "SELECT pg_catalog.has_function_privilege($1, $2, $3)",
}
# `<scope column> = '<constant>'::uuid|text` as pg_policies deparses it: a uuid tenant_id (CIS 239), a text tenant_id
# (CIS 265 tenant_tour_pages, `'…'::text`), owner_scope (CIS 266), each possibly table-qualified or cast to text.
SCOPE_CONST_RE = re.compile(r"\b(?:tenant_id|owner_scope)\)?(?:::text)?\s*=\s*'([^']*)'::(?:uuid|text)\b")


class _Undo(Exception):
    """Raised to roll a savepoint back (undo set_config, keep the transaction usable)."""


# ── pure helpers (unit-tested) ──
def safe_err(e: BaseException) -> str:
    """Error text that can never carry a DSN or a password: server errors keep their SQLSTATE and
    message (PostgreSQL never echoes a password), anything else only its type name."""
    state = getattr(e, "sqlstate", None)
    if state:
        return f"{state} {type(e).__name__}: {(str(e).splitlines() or [''])[0][:160]}"
    code = (getattr(e, "response", None) or {}).get("Error", {}).get("Code")   # botocore ClientError
    return f"{type(e).__name__} {code}" if code else type(e).__name__


def secret_name(value_from: str) -> str:
    """Secrets Manager name from an ECS `valueFrom` (ARN, ARN:json-key::, or a plain name)."""
    if not value_from:
        return ""
    if value_from.startswith("arn:"):
        parts = value_from.split(":")
        name = parts[6] if len(parts) > 6 else ""
        return re.sub(r"-[A-Za-z0-9]{6}$", "", name)
    return value_from


def secret_id(value_from: str) -> str:
    """What GetSecretValue accepts: the ARN without a `:json-key:version-stage:version-id` suffix."""
    if value_from.startswith("arn:"):
        return ":".join(value_from.split(":")[:7])
    return value_from


def normalize_dsn(raw):
    """A usable postgres DSN from a secret value, or None (empty, placeholder, not a DSN).
    Accepts a plain DSN (postgresql:// or postgresql+asyncpg://) or JSON {url|dsn|…} / RDS fields."""
    if not raw:
        return None
    s = raw.strip()
    if s.startswith("{"):
        try:
            obj = json.loads(s)
        except ValueError:
            return None
        for k in ("url", "dsn"):
            if isinstance(obj.get(k), str):
                return normalize_dsn(obj[k])
        if obj.get("host") and obj.get("username"):
            from urllib.parse import quote
            return (f"postgresql://{quote(str(obj['username']), safe='')}:{quote(str(obj.get('password', '')), safe='')}"
                    f"@{obj['host']}:{obj.get('port', 5432)}/{obj.get('dbname') or obj.get('database') or ''}")
        return None
    s = re.sub(r"^(postgres|postgresql)\+[a-z0-9]+://", "postgresql://", s)
    if not re.match(r"^(postgres|postgresql)://", s):
        return None
    return s


def dsn_user(dsn):
    if not dsn:
        return None
    try:
        u = urlparse(dsn).username
    except ValueError:
        return None
    return unquote(u) if u else None


def chain_violations(chain: list) -> list:
    return sorted(r for r in chain if r in FORBIDDEN_IN_CHAIN or r.endswith("_owner"))


def allowed_tenant_constants(policies: list) -> dict:
    """{table fq: [shared constants readable by the tenant pool under any GUC]}: the SHARED_SCOPE_CONSTANTS a
    pool policy of that table compares its tenant column with (uuid or text literal). Another constant shares
    nothing, so a policy that names another tenant's id still shows up as cross-tenant rows."""
    out: dict = {}
    for p in policies:
        for m in SCOPE_CONST_RE.finditer(p["qual"]):
            if m.group(1).lower() in SHARED_SCOPE_CONSTANTS:
                out.setdefault(p["fq"], set()).add(m.group(1).lower())
    return {k: sorted(v) for k, v in out.items()}


def matrix_count_sql(t: dict):
    """The tenant-matrix count for one RLS table (an RLS_TABLES_SQL row) as the tenant pool: visible rows and
    cross-tenant rows, $1 = the GUC tenant (NULL when unset or ''), $2 = the shared constants its pool
    policies name. Cross-tenant = a non-NULL tenant column that is neither $1 nor in $2; for a PARENT_SCOPED
    table, a row without a parent the session can see whose tenant_id is $1 or in $2 (the parent read runs as
    the pool, through the parent's own policy, so a foreign row's parent is invisible). None = no tenant scope."""
    col = t.get("tenant_col")
    if col in TENANT_SCOPE_COLUMNS:
        return (f"SELECT count(*)::bigint AS visible, count(*) FILTER (WHERE {col} IS NOT NULL "
                f"AND {col}::text IS DISTINCT FROM $1 AND NOT (lower({col}::text) = ANY($2::text[])))"
                f"::bigint AS cross FROM {t['q']}")
    if t["fq"] in PARENT_SCOPED:
        key, parent, parent_key = PARENT_SCOPED[t["fq"]]
        return (f"SELECT count(*)::bigint AS visible, count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM {parent} p "
                f"WHERE p.{parent_key} = c.{key} AND (p.tenant_id::text = $1 "
                f"OR lower(p.tenant_id::text) = ANY($2::text[]))))::bigint AS cross FROM {t['q']} c")
    return None


def tenant_labels(tenant_ids: list) -> dict:
    """{tenant id: label}; ids never leave the task, labels do."""
    labels, k = {}, 0
    for t in tenant_ids:
        if t.lower() == MASTER_TENANT:
            labels[t] = "master"
        else:
            k += 1
            labels[t] = f"t{k}"
    return labels


def ownership_offenders(rows: list, owner: "ProbeOwner") -> list:
    """Rows of NOT_OWNED_SQL that break "every object owned by the owner role": view owners may own
    views/matviews only."""
    return [r for r in rows
            if not (r["owner"] in owner.view_owner_roles and r["kind"] in ("view", "matview"))]


def default_acl_findings(rows: list, rp: "RuntimePrivileges", owner: "ProbeOwner", live_owner: str) -> list:
    """What breaks "objects the owner creates later reach the runtime role" (DEFAULT_ACL_SQL rows of the
    owner's schemas, privileges as granted to rp.role): a missing or short row FOR ROLE <live owner of the
    anchor schema> IN SCHEMA s for each owners.yaml default_acl object type, and, once the live owner is
    no longer the master, any FOR ROLE <master> row left in the owner's schemas (the transfer revokes
    them; a leftover means the master would still be the creator the default privileges follow)."""
    words = {v: k for k, v in DEFACL_OBJTYPE.items()}
    have = {(r["schema"], r["objtype"], r["for_role"]): set(r["privileges"] or ()) for r in rows}
    out = []
    for schema in rp.schemas:
        for word, privs in rp.default_acl:
            got = have.get((schema, DEFACL_OBJTYPE[word], live_owner))
            if got is None:
                out.append(f"no default privileges FOR ROLE {live_owner} IN SCHEMA {schema} ON {word.upper()}")
            elif not set(privs) <= got:
                out.append(f"FOR ROLE {live_owner} IN SCHEMA {schema} ON {word.upper()}: {rp.role} lacks "
                           f"{','.join(sorted(set(privs) - got))}")
    if live_owner != MASTER_ROLE:
        out += [f"FOR ROLE {MASTER_ROLE} IN SCHEMA {r['schema']} ON {words.get(r['objtype'], r['objtype']).upper()} "
                f"left after the transfer"
                for r in rows if r["for_role"] == MASTER_ROLE and r["schema"] in owner.schemas]
    return sorted(set(out))


def consumer_kind(obj: str) -> str:
    """'function' for schema.name(args), else 'relation'."""
    return "function" if obj.endswith(")") else "relation"


@dataclass
class Cell:
    id: str
    group: str
    title: str
    when: tuple = ()                 # state keys that must all be true for the cell to be expected
    ok: bool = False                 # the check holds right now
    detail: dict = field(default_factory=dict)
    error: str = ""                  # could not evaluate (counts as not ok)
    pending_without_key: bool = False
    warn_while_pending: bool = False

    def status(self, keys: dict) -> str:
        if self.pending_without_key:
            return "FAIL" if self.ok else "pending"       # passes already: drop the pending flag
        expected = all(keys.get(k, False) for k in self.when)
        if expected:
            return "pass" if self.ok and not self.error else "FAIL"
        return "ready" if self.ok and not self.error else "pending"

    def as_json(self, keys: dict) -> dict:
        st = self.status(keys)
        out = {"id": self.id, "group": self.group, "title": self.title, "status": st,
               "expected": all(keys.get(k, False) for k in self.when) and not self.pending_without_key,
               "when": [KEY_TEXT.get(k, k) for k in self.when], "detail": self.detail}
        if self.error:
            out["error"] = self.error
        if self.warn_while_pending and st == "pending":
            out["warn"] = True
        return out


def state_keys(facts: dict) -> dict:
    reg = set(facts["catalog"]["registered"])
    keys = {v: v in reg for v in VERSION_KEYS}
    # An ownership transfer is in force while its key is registered AND the anchor schema is owned by the
    # owner role (the same live fact DB Migrate's role switch reads). Registry rows are never deleted, so
    # after a planned rollback (a roles/ undo file) the anchor is the master's again and the cells keyed
    # on it go back to pending instead of failing every night.
    anchors = facts["catalog"].get("anchor_owner", {})
    for name, o in OWNERS.items():
        keys[TRANSFER_KEYS[name]] = keys[o.transfer_key] and anchors.get(o.anchor_schema) == o.owner_role
    keys["cis_runtime_on_cis_app"] = secret_name(facts["cis_runtime"]["value_from"]) == CIS_APP_SECRET
    keys["cis_app_secret_ready"] = facts["logins"].get(CIS_APP, {}).get("secret_user") == CIS_APP
    keys["cis_app_password_set"] = PASSWORD_MARKER in (facts["roles"].get(CIS_APP, {}).get("comment") or "")
    keys["catalog_login_not_master"] = facts["catalog"]["login"] != MASTER_ROLE
    return keys


ELEVATED_ATTRS = ("super", "bypassrls", "createrole", "createdb", "replication")
RUNTIME_ATTRS_TITLE = "LOGIN, not SUPERUSER / BYPASSRLS / CREATEROLE / CREATEDB / REPLICATION"


def _role_cells(cid: str, label: str, info: dict, when: tuple) -> list:
    """Attributes, membership chain, owned objects and connection limit of one runtime role."""
    if info.get("error") or not info.get("exists"):
        err = info.get("error") or f"role {label} does not exist"
        return [Cell(f"{cid}.{k}", "runtime role", f"{label}: {t}", when, error=err)
                for k, t in (("attributes", RUNTIME_ATTRS_TITLE),
                             ("membership", "member of no owner/master/rds_superuser/pg_*_all_data role"),
                             ("owns_nothing", "owns no object"), ("connection_limit", "has a CONNECTION LIMIT"))]
    bad_chain = chain_violations(info["chain"])
    owned = info["owned"]
    return [
        # CREATEROLE too: on PostgreSQL 15 a CREATEROLE role can grant itself any non-superuser role
        # (bk_owner, cis_owner, pg_read_all_data, …) and SET ROLE into every schema, whatever its
        # memberships are today; CREATEDB / REPLICATION have no business on a runtime role either.
        Cell(f"{cid}.attributes", "runtime role", f"{label}: {RUNTIME_ATTRS_TITLE}", when,
             ok=info["login"] and not any(info.get(a) for a in ELEVATED_ATTRS),
             detail={"role": info["rolname"], "login": info["login"],
                     **{a: info.get(a) for a in ELEVATED_ATTRS}}),
        Cell(f"{cid}.membership", "runtime role",
             f"{label}: member of no owner/master/rds_superuser/pg_*_all_data role", when,
             ok=not bad_chain, detail={"role": info["rolname"], "member_of": info["chain"][:SAMPLE * 2],
                                       "forbidden": bad_chain}),
        Cell(f"{cid}.owns_nothing", "runtime role", f"{label}: owns no object (DM-1.3)", when,
             ok=not owned, detail={"role": info["rolname"], "owned": len(owned),
                                   "sample": [f"{o['kind']} {o['name']}" for o in owned[:SAMPLE]]}),
        Cell(f"{cid}.connection_limit", "runtime role", f"{label}: has a CONNECTION LIMIT (C2.2)", when,
             ok=info["connlimit"] > 0, detail={"role": info["rolname"], "connection_limit": info["connlimit"]}),
    ]


def build_cells(facts: dict, keys: dict) -> list:
    cells: list = []
    roles = facts["roles"]

    # Runtime roles (catalog facts).
    for r in LEGACY_RUNTIME_ROLES:
        cells += _role_cells(f"role.{r}", r, roles.get(r, {}), ())
    cells += _role_cells(f"role.{CIS_APP}", CIS_APP, roles.get(CIS_APP, {}), ("rl-001",))
    rt_user = facts["cis_runtime"].get("user")
    cells += _role_cells("role.cis_runtime", f"CIS runtime ({rt_user or 'unknown'})",
                         roles.get(rt_user, {}) if rt_user else {"error": facts["cis_runtime"].get("error")
                                                                  or "CIS runtime login unknown"},
                         ("cis_runtime_on_cis_app",))

    # Owner roles (rl-001, rl-002).
    for owner, key in (("bk_owner", "rl-001"), ("tp_owner", "rl-001"), ("cis_owner", "rl-002")):
        info = roles.get(owner, {})
        ok = bool(info.get("exists")) and not info.get("login") and not any(info.get(a) for a in ELEVATED_ATTRS)
        cells.append(Cell(f"owner_role.{owner}", "owner role",
                          f"{owner}: NOLOGIN, not SUPERUSER / BYPASSRLS / CREATEROLE / CREATEDB / REPLICATION",
                          (key,), ok=ok, error=info.get("error", ""),
                          detail={k: info.get(k) for k in ("exists", "login", *ELEVATED_ATTRS)}))

    # Logins through each role's own secret.
    # cis_app: Nghiệp writes its DSN first (S17), set-password runs after; in between the login fails
    # with 28P01. Expected only once set-password has marked the role; a warning while the secret is
    # ready but the marker is missing (so a forgotten set-password does not stay silent).
    pw_gap = keys.get("cis_app_secret_ready", False) and not keys.get("cis_app_password_set", False)
    for role, login in sorted(facts["logins"].items()):
        when = CIS_APP_LOGIN_KEYS if role == CIS_APP else ()
        expected_user = None if role == CIS_RUNTIME else role
        ok = not login.get("error") and (expected_user is None or login.get("current_user") == expected_user)
        cells.append(Cell(f"login.{role}", "login", f"{role}: logs in with its own secret "
                          f"{login.get('secret', '?')}", when, ok=ok, error=login.get("error", ""),
                          detail={"secret": login.get("secret"), "current_user": login.get("current_user")},
                          warn_while_pending=role == CIS_APP and pw_gap))

    # Cross-app reads (42501 through the role's own login).
    for role, target, when in CROSS_APP:
        login = facts["logins"].get(role, {})
        res = login.get("cross", {}).get(target)
        if login.get("error") or res is None:
            cells.append(Cell(f"cross.{role}.{target}", "cross-app", f"{role} cannot read {target} (42501)", when,
                              error=login.get("error") or "not probed"))
            continue
        cells.append(Cell(f"cross.{role}.{target}", "cross-app", f"{role} cannot read {target} (42501)", when,
                          ok=res.get("sqlstate") == "42501",
                          detail={"login": login.get("current_user"), **res}))

    # Ownership of each owner's schemas.
    for name, owner in OWNERS.items():
        own = facts["ownership"].get(name, {})
        offenders = own.get("offenders", [])
        cells.append(Cell(f"ownership.{name}", "ownership",
                          f"every object in {', '.join(owner.schemas) if len(owner.schemas) < 3 else name + ' schemas'} "
                          f"owned by {owner.owner_role}", (TRANSFER_KEYS[name],),
                          ok=not own.get("error") and not offenders, error=own.get("error", ""),
                          detail={"not_owned": len(offenders),
                                  "sample": [f"{o['kind']} {o['name']} ({o['owner']})" for o in offenders[:SAMPLE]]}))

    # Runtime grants: the runtime role can use every object of its schemas (existing objects: baseline
    # privilege per kind; future objects: default privileges FOR ROLE <live owner>). The failure X1 is
    # most likely to cause is a runtime role losing a grant (42501 after deploy), not a cross-app read.
    for name, owner in OWNERS.items():
        key = owner.runtime_privileges_from or TRANSFER_KEYS[name]
        live = facts["catalog"].get("anchor_owner", {}).get(owner.anchor_schema)
        for rp in owner.runtime_privileges:
            suffix = "" if len(owner.runtime_privileges) == 1 else f".{rp.role}"
            g = facts["runtime_grants"].get(name, {}).get(rp.role, {})
            missing = g.get("missing", [])
            cells.append(Cell(f"runtime_grants.{name}{suffix}", "runtime grants",
                              f"{rp.role}: USAGE on its {len(rp.schemas)} schema(s), SELECT on every relation, USAGE on "
                              f"every non-identity sequence, EXECUTE on every non-trigger function", (key,),
                              ok=not g.get("error") and not missing, error=g.get("error", ""),
                              detail={"missing": len(missing),
                                      "sample": [f"{m['kind']} {m['name']}: {m['missing']}"
                                                 for m in missing[:SAMPLE]]}))
            d = facts["default_acl"].get(name, {}).get(rp.role, {})
            found = [] if d.get("error") else default_acl_findings(d.get("rows", []), rp, owner, live or "?")
            cells.append(Cell(f"default_acl.{name}{suffix}", "runtime grants",
                              f"default privileges FOR ROLE <live owner of {owner.anchor_schema}> grant {rp.role} "
                              f"{', '.join(w for w, _ in rp.default_acl)}; no FOR ROLE {MASTER_ROLE} row once "
                              f"transferred", (key,), ok=not d.get("error") and not found, error=d.get("error", ""),
                              detail={"live_owner": live, "findings": found[:SAMPLE * 2]}))
    cg = facts["consumer"]
    for key in ("",) + CONSUMER_GRANT_KEYS:
        grants = [c for c in cg.get("grants", []) if c.get("from", "") == key]
        bad = [f"{c['grantee']} {c['object']}: {', '.join(c['missing'])}" for c in grants if c["missing"]]
        cells.append(Cell(f"consumer.contract_grants.{key}" if key else "consumer.contract_grants", "runtime grants",
                          f"contract consumer grants created by {key} held (owners.yaml consumer_grants)" if key else
                          "contract consumer grants on single objects still held (owners.yaml consumer_grants)",
                          (key,) if key else (),
                          ok=not cg.get("error") and not bad and bool(grants), error=cg.get("error", ""),
                          detail={"checked": len(grants), "missing": bad}))

    # Owner roles may register their own keys (CIS 243); cis_app may not write the registry (244).
    for owner in ("bk_owner", "tp_owner"):
        g = facts["owner_grants"].get(owner, {})
        ok = not g.get("error") and g.get("usage_shared") and g.get("select_registry") and g.get("insert_registry")
        cells.append(Cell(f"registry.{owner}", "registry",
                          f"{owner}: USAGE on shared + SELECT, INSERT on shared.schema_versions", ("243",),
                          ok=bool(ok), error=g.get("error", ""), detail={k: v for k, v in g.items() if k != "error"}))
    w = facts["registry_writes"].get(CIS_APP, {})
    cells.append(Cell(f"registry.{CIS_APP}", "registry",
                      f"{CIS_APP}: no INSERT/UPDATE/DELETE/TRUNCATE on shared.schema_versions", ("rl-001",),
                      ok=not w.get("error") and not any(w.get(k) for k in ("insert", "update", "delete", "truncate")),
                      error=w.get("error", ""), detail={k: v for k, v in w.items() if k != "error"}))

    # Standing RLS cell: every ENABLE-without-FORCE CIS table has a permissive policy TO cis_app.
    eo = facts["rls_enable_only"]
    missing = [t["fq"] for t in eo.get("tables", []) if not t["has_policy"] and t["fq"] not in RLS_ENABLE_ONLY_ALLOWLIST]
    cells.append(Cell("rls.enable_only_has_cis_app_policy", "rls",
                      "every ENABLE-without-FORCE CIS table has a permissive policy TO cis_app (or is allowlisted)",
                      ("244",), ok=not eo.get("error") and not missing, error=eo.get("error", ""),
                      detail={"tables": len(eo.get("tables", [])), "missing": missing[:SAMPLE * 2]}))

    # Tenant matrix through aa_app_user's own login.
    tm = facts["tenant_matrix"]
    cross = []
    errors = []
    for fq, modes in sorted(tm.get("tables", {}).items()):
        for mode, r in modes.items():
            if r.get("error") and not r["error"].startswith("42501"):
                errors.append(f"{fq} [{mode}] {r['error']}")
            elif (r.get("cross") or 0) > 0:
                cross.append(f"{fq} [{mode}] cross={r['cross']} visible={r['visible']}")
            elif r.get("cross") is None and (r.get("visible") or 0) > 0:
                errors.append(f"{fq} [{mode}] {UNJUDGED} ({r['visible']} visible rows)")
    cells.append(Cell("tenant.aa_app_user_isolation", "tenant",
                      "aa_app_user sees 0 cross-tenant rows under unset/empty/forged/each tenant GUC", (),
                      ok=not tm.get("error") and not cross and not errors and bool(tm.get("tables")),
                      error=tm.get("error", "") or ("; ".join(errors[:3]) if errors else ""),
                      detail={"tables": len(tm.get("tables", {})), "modes": tm.get("modes", []),
                              "cross_tenant": cross[:SAMPLE], "errors": errors[:SAMPLE],
                              "matrix": "see the `matrix` records (one per table)"}))

    fp = facts.get("force_parity", {})
    ref, got = fp.get("reference", {}), fp.get("cis_app", {})
    mismatch = []
    for t in RLS_PARITY_TABLES:
        r, g = ref.get(t, []), got.get(t, {})
        if g.get("error") or not r or "plain" not in g:
            mismatch.append(f"{t}: {g.get('error') or ('no reference count' if not r else 'not counted')}")
        elif g["plain"] not in r or g["forged"] not in r:
            mismatch.append(f"{t}: cis_app {g['plain']} (no GUC) / {g['forged']} (forged GUC), reference {r}")
    cells.append(Cell("rls.force_parity.cis_app", "rls",
                      f"cis_app (own login) reads every row of the {len(RLS_PARITY_TABLES)} RLS parity tables (FORCE "
                      f"+ tenant_tour_versions) without a GUC and under a forged one (= catalog login count; 244)",
                      ("244",) + CIS_APP_LOGIN_KEYS, ok=not fp.get("error") and not mismatch,
                      error=fp.get("error", ""), detail={"tables": len(RLS_PARITY_TABLES),
                                                         "mismatch": mismatch[:SAMPLE]}))

    ttv = facts["ttv"]
    cells.append(Cell("tenant.cis_runtime_sees_all_ttv", "tenant",
                      f"CIS runtime sees every row of {TTV} without a GUC (ENABLE-only owner exemption / 244 policy)",
                      (), ok=not ttv.get("error") and ttv.get("runtime") is not None
                      and ttv.get("runtime") in ttv.get("reference", []),
                      error=ttv.get("error", ""), detail={k: v for k, v in ttv.items() if k != "error"}))

    # Sessions.
    s = facts["sessions"]
    dm = s.get("db_migrator", {})
    cells.append(Cell("sessions.db_migrator_below_limit", "sessions",
                      "db_migrator sessions < its CONNECTION LIMIT - 1", ("rl-002",),
                      ok=not dm.get("error") and dm.get("limit", -1) > 0 and dm.get("n", 0) < dm.get("limit", 0) - 1,
                      error=dm.get("error", ""), detail={k: v for k, v in dm.items() if k != "error"}))
    ms = s.get("master", {})
    cells.append(Cell("sessions.master_break_glass_only", "sessions",
                      f"no {MASTER_ROLE} session other than this probe (break-glass only after X1 S22)",
                      ("catalog_login_not_master",), ok=not ms.get("error") and not ms.get("sessions"),
                      error=ms.get("error", ""), detail={"sessions": ms.get("sessions", [])},
                      warn_while_pending=True))
    return cells


def summarize(cells: list, keys: dict) -> dict:
    counts = {"pass": 0, "FAIL": 0, "pending": 0, "ready": 0}
    for c in cells:
        counts[c.status(keys)] += 1
    return {**counts, "cells": len(cells), "exit": 1 if counts["FAIL"] else 0}


def emit(kind: str, obj) -> None:
    print(f"PROBE {kind} " + json.dumps(obj, default=str, sort_keys=True, separators=(",", ":")), flush=True)


# ── DB collection (inside the task) ──
class Secrets:
    """Secrets Manager in the task; a local JSON map {secret id or name: DSN} for a dry run."""

    def __init__(self, cfg: dict):
        self.local = None
        if cfg.get("dsn_file"):
            with open(cfg["dsn_file"], encoding="utf-8") as f:
                self.local = json.load(f)
        else:
            import boto3   # only inside the task
            self.sm = boto3.client("secretsmanager", region_name=cfg.get("region") or "us-west-1")

    def get(self, sid: str):
        if self.local is not None:
            if sid not in self.local and secret_name(sid) not in self.local:
                raise LookupError("secret not found")
            return self.local.get(sid, self.local.get(secret_name(sid)))
        return self.sm.get_secret_value(SecretId=secret_id(sid)).get("SecretString")


async def connect(dsn: str, cfg: dict):
    import asyncpg   # only inside the task
    ssl = cfg.get("ssl", "require")
    return await asyncpg.connect(dsn, ssl=None if ssl == "disable" else ssl, timeout=20,
                                 server_settings=SESSION_SETTINGS)


async def _savepoint(conn, fn):
    """Run fn() in a savepoint that is always rolled back; returns (value, error)."""
    box = {}
    try:
        async with conn.transaction():
            box["v"] = await fn()
            raise _Undo()
    except _Undo:
        return box.get("v"), None
    except Exception as e:  # noqa: BLE001 — record, keep probing
        return None, e


async def _role_info(conn, role: str) -> dict:
    row = await conn.fetchrow(ROLE_SQL, role)
    if row is None:
        return {"exists": False}
    info = {"exists": True, **dict(row)}
    info["chain"] = [r["role"] for r in await conn.fetch(CHAIN_SQL, role)]
    info["owned"] = [dict(r) for r in await conn.fetch(OWNED_SQL, role)]
    return info


async def collect_catalog(conn, cfg: dict, facts: dict, runtime_user) -> list:
    """Catalog facts as the catalog login. Returns the tenant ids (never emitted)."""
    facts["catalog"]["login"] = await conn.fetchval("SELECT session_user::text")
    facts["catalog"]["server_version"] = await conn.fetchval("SELECT current_setting('server_version')")
    # Every user-table read runs in a savepoint that is rolled back: its ACCESS SHARE lock is released at
    # once, so the probe never holds a lock a migration's ALTER would queue behind.
    v, e = await _savepoint(conn, lambda: conn.fetch(REGISTERED_SQL, list(VERSION_KEYS)))
    if e:
        raise RuntimeError(f"state keys: shared.schema_versions unreadable: {safe_err(e)}")
    facts["catalog"]["registered"] = [r["version"] for r in v]
    anchors = sorted({o.anchor_schema for o in OWNERS.values()})
    v, e = await _savepoint(conn, lambda: conn.fetch(ANCHOR_SQL, anchors))
    if e:
        raise RuntimeError(f"state keys: anchor schema owners unreadable: {safe_err(e)}")
    facts["catalog"]["anchor_owner"] = {r["schema"]: r["owner"] for r in v}

    names = set(LEGACY_RUNTIME_ROLES) | {CIS_APP, "bk_owner", "tp_owner", "cis_owner"}
    if runtime_user:
        names.add(runtime_user)
    for role in sorted(names):
        v, e = await _savepoint(conn, lambda role=role: _role_info(conn, role))
        facts["roles"][role] = v if e is None else {"error": safe_err(e)}

    for name, owner in OWNERS.items():
        v, e = await _savepoint(conn, lambda o=owner: conn.fetch(NOT_OWNED_SQL, list(o.schemas), o.owner_role))
        facts["ownership"][name] = ({"error": safe_err(e)} if e else
                                    {"offenders": ownership_offenders([dict(r) for r in v], owner)})

    for name, owner in OWNERS.items():
        for rp in owner.runtime_privileges:
            if not facts["roles"].get(rp.role, {}).get("exists"):
                err = {"error": f"role {rp.role} does not exist"}
                facts["runtime_grants"].setdefault(name, {})[rp.role] = err
                facts["default_acl"].setdefault(name, {})[rp.role] = err
                continue
            kinds = dict(rp.objects)
            v, e = await _savepoint(conn, lambda rp=rp, kinds=kinds: conn.fetch(
                RUNTIME_MISSING_SQL, rp.role, list(rp.schemas), list(kinds.get("relation", ())),
                list(kinds.get("sequence", ())), list(kinds.get("function", ()))))
            facts["runtime_grants"].setdefault(name, {})[rp.role] = (
                {"error": safe_err(e)} if e else {"missing": [dict(r) for r in v]})
            v, e = await _savepoint(conn, lambda o=owner, rp=rp: conn.fetch(DEFAULT_ACL_SQL, list(o.schemas), rp.role))
            facts["default_acl"].setdefault(name, {})[rp.role] = (
                {"error": safe_err(e)} if e else {"rows": [dict(r) for r in v]})

    async def consumer():
        out = []
        for grantee, privs, obj, key in CONSUMER_GRANTS:
            kind = consumer_kind(obj)
            # An object its migration has not created yet: "absent", never an error that would hide the other
            # grants (has_*_privilege raises on a missing object). Expected only once its key is registered.
            if not await conn.fetchval(CONSUMER_SQL[f"exists_{kind}"], obj):
                out.append({"grantee": grantee, "object": obj, "privileges": list(privs), "missing": ["absent"],
                            "from": key})
                continue
            missing = []
            for priv in privs:
                if priv == "USAGE":
                    ok = await conn.fetchval(CONSUMER_SQL["USAGE"], grantee, obj)
                else:
                    ok = await conn.fetchval(CONSUMER_SQL[kind], grantee, obj, priv)
                if not ok:
                    missing.append(priv)
            out.append({"grantee": grantee, "object": obj, "privileges": list(privs), "missing": missing,
                        "from": key})
        return out
    v, e = await _savepoint(conn, consumer)
    facts["consumer"] = {"error": safe_err(e)} if e else {"grants": v}

    for owner in ("bk_owner", "tp_owner"):
        if not facts["roles"].get(owner, {}).get("exists"):
            facts["owner_grants"][owner] = {"error": f"role {owner} does not exist"}
            continue
        v, e = await _savepoint(conn, lambda o=owner: conn.fetchrow(OWNER_GRANTS_SQL, o))
        facts["owner_grants"][owner] = {"error": safe_err(e)} if e else dict(v)
    if facts["roles"].get(CIS_APP, {}).get("exists"):
        v, e = await _savepoint(conn, lambda: conn.fetchrow(REGISTRY_WRITES_SQL, CIS_APP))
        facts["registry_writes"][CIS_APP] = {"error": safe_err(e)} if e else dict(v)
    else:
        facts["registry_writes"][CIS_APP] = {"error": f"role {CIS_APP} does not exist"}

    v, e = await _savepoint(conn, lambda: conn.fetch(ENABLE_ONLY_SQL, list(CIS_SCHEMAS), CIS_APP))
    facts["rls_enable_only"] = {"error": safe_err(e)} if e else {"tables": [dict(r) for r in v]}

    v, e = await _savepoint(conn, lambda: conn.fetch(RLS_TABLES_SQL, list(CIS_SCHEMAS), list(TENANT_SCOPE_COLUMNS)))
    rls_tables = [] if e else [dict(r) for r in v]
    if e:
        facts["tenant_matrix"]["error"] = "RLS table list: " + safe_err(e)
    v, e = await _savepoint(conn, lambda: conn.fetch(POOL_POLICIES_SQL, list(CIS_SCHEMAS), TENANT_POOL))
    facts["_allowed_constants"] = {} if e else allowed_tenant_constants([dict(r) for r in v])
    facts["_rls_tables"] = rls_tables
    v, e = await _savepoint(conn, lambda: conn.fetch(TENANTS_SQL))
    tenants = [] if e else [r["tenant_id"] for r in v]
    if e:
        facts["tenant_matrix"]["error"] = "tenant list: " + safe_err(e)

    v, e = await _savepoint(conn, lambda: conn.fetch(SESSIONS_SQL, MASTER_ROLE, APP_NAME))
    facts["sessions"]["master"] = {"error": safe_err(e)} if e else {"sessions": [dict(r) for r in v]}

    async def dm():
        limit = await conn.fetchval(CONNLIMIT_SQL, "db_migrator")
        if limit is None:
            return {"error": "role db_migrator does not exist"}
        n = await conn.fetchval("SELECT count(*)::int FROM pg_catalog.pg_stat_activity "
                                "WHERE usename = 'db_migrator' AND backend_type = 'client backend'")
        return {"n": n, "limit": limit}
    v, e = await _savepoint(conn, dm)
    facts["sessions"]["db_migrator"] = {"error": safe_err(e)} if e else v
    return tenants


async def ttv_count(conn):
    v, e = await _savepoint(conn, lambda: conn.fetchval(f"SELECT count(*)::bigint FROM {TTV}"))
    if e:
        raise e
    return v


async def parity_counts(conn, facts: dict) -> None:
    """cis_app's own count(*) of each RLS parity table, without a GUC and under a forged tenant."""
    forged = str(uuid.uuid4())
    out = facts["force_parity"].setdefault("cis_app", {})
    for t in RLS_PARITY_TABLES:
        async def count(t=t, guc=""):
            await conn.execute("SELECT pg_catalog.set_config('app.tenant_id', $1, true)", guc)
            return await conn.fetchval(f"SELECT count(*)::bigint FROM {t}")
        plain, e1 = await _savepoint(conn, count)
        forged_n, e2 = await _savepoint(conn, lambda t=t: count(t, forged))
        e = e1 or e2
        out[t] = {"error": safe_err(e)} if e else {"plain": plain, "forged": forged_n}


async def probe_login(role: str, sid: str, cfg: dict, secrets: Secrets, facts: dict, tenants: list) -> None:
    """Everything that must be evidence of isolation: through `role`'s own login only."""
    out = facts["logins"].setdefault(role, {"secret": secret_name(sid)})
    try:
        dsn = normalize_dsn(secrets.get(sid))
    except Exception as e:  # noqa: BLE001
        out["error"] = f"secret {secret_name(sid)}: {safe_err(e)}"
        return
    if not dsn:
        out["error"] = f"secret {secret_name(sid)} holds no usable DSN (empty or placeholder)"
        return
    out["secret_user"] = dsn_user(dsn)
    try:
        conn = await connect(dsn, cfg)
    except Exception as e:  # noqa: BLE001
        out["error"] = f"login failed: {safe_err(e)}"
        return
    tr = conn.transaction(readonly=True)
    try:
        await tr.start()
        out["current_user"] = await conn.fetchval("SELECT current_user::text")
        out["cross"] = {}
        for r, target, _when in CROSS_APP:
            if r != role:
                continue
            _v, e = await _savepoint(conn, lambda t=target: conn.fetchval(f"SELECT 1 FROM {t} LIMIT 1"))
            out["cross"][target] = {"readable": e is None,
                                    "sqlstate": getattr(e, "sqlstate", None) if e else None,
                                    **({"error": safe_err(e)} if e else {})}
        if role == TENANT_POOL:
            await tenant_matrix(conn, facts, tenants)
        if role == CIS_APP:
            await parity_counts(conn, facts)
        if role == CIS_RUNTIME:
            try:
                facts["ttv"]["runtime"] = await ttv_count(conn)
            except Exception as e:  # noqa: BLE001
                facts["ttv"]["error"] = "CIS runtime count: " + safe_err(e)
    finally:
        try:
            await tr.rollback()
        finally:
            await conn.close()


async def tenant_matrix(conn, facts: dict, tenants: list) -> None:
    """aa817 matrix through the tenant pool's own login: visible and cross-tenant rows per RLS table
    under GUC unset / '' / forged uuid / every tenant of shared.tenants. Cross-tenant = a row whose tenant
    column (tenant_id, else owner_scope) is neither the GUC tenant nor a constant a policy shares with every
    tenant (the AA master catalog, the platform atoms); NULL tenant_id rows (platform facts) are not tenant
    rows; a PARENT_SCOPED row is judged by its parent (matrix_count_sql)."""
    tm = facts["tenant_matrix"]
    if tm.get("error"):
        return
    labels = tenant_labels(tenants)
    forged = str(uuid.uuid4())
    modes = [("unset", None, None), ("empty", "", None), ("forged", forged, forged)] + \
            [(f"tenant:{labels[t]}", t, t) for t in tenants]
    tm["modes"] = [m[0] for m in modes]
    tm["tables"] = {}
    allowed = facts.get("_allowed_constants", {})
    for t in facts.get("_rls_tables", []):
        row_out = {}
        for mode, guc, me in modes:
            async def count(t=t, guc=guc, me=me):
                if guc is not None:
                    await conn.execute("SELECT pg_catalog.set_config('app.tenant_id', $1, true)", guc)
                sql = matrix_count_sql(t)
                if sql:
                    r = await conn.fetchrow(sql, me, allowed.get(t["fq"], []))
                    return {"visible": r["visible"], "cross": r["cross"]}
                n = await conn.fetchval(f"SELECT count(*)::bigint FROM {t['q']}")
                # No tenant scope: under a GUC that names no real tenant every visible row is foreign; under a real
                # tenant the rows cannot be judged (build_cells reports them, UNJUDGED).
                return {"visible": n, "cross": n if mode in ("unset", "empty", "forged") else None}
            v, e = await _savepoint(conn, count)
            row_out[mode] = {"error": safe_err(e)} if e else v
        tm["tables"][t["fq"]] = row_out


async def collect(cfg: dict, facts: dict) -> int:
    secrets = Secrets(cfg)
    rt_value_from = cfg.get("cis_runtime_secret") or ""
    facts["cis_runtime"] = {"value_from": rt_value_from, "secret": secret_name(rt_value_from),
                            "task_definition": cfg.get("api_task_definition")}
    rt_dsn = None
    if rt_value_from:
        try:
            rt_dsn = normalize_dsn(secrets.get(rt_value_from))
            facts["cis_runtime"]["user"] = dsn_user(rt_dsn)
        except Exception as e:  # noqa: BLE001
            facts["cis_runtime"]["error"] = safe_err(e)
    else:
        facts["cis_runtime"]["error"] = "no cis_runtime_secret in the probe config"

    catalog_dsn = (secrets.local or {}).get("catalog") if secrets.local is not None else os.environ.get("DATABASE_URL")
    if not catalog_dsn:
        raise RuntimeError("no catalog DSN (the task's database secret)")
    conn = await connect(catalog_dsn, cfg)
    try:
        async def reference():
            # The CIS runtime count runs on another connection a moment later: a reference count before
            # and after it (each in its own short read-only transaction) brackets a concurrent insert.
            tr = conn.transaction(readonly=True)
            await tr.start()
            try:
                facts["ttv"].setdefault("reference", []).append(await ttv_count(conn))
            except Exception as e:  # noqa: BLE001
                facts["ttv"]["error"] = "reference count: " + safe_err(e)
            try:
                refs = facts["force_parity"].setdefault("reference", {})
                for t in RLS_PARITY_TABLES:
                    v, e = await _savepoint(conn, lambda t=t: conn.fetchval(f"SELECT count(*)::bigint FROM {t}"))
                    if e:
                        raise e
                    refs.setdefault(t, []).append(v)
            except Exception as e:  # noqa: BLE001
                facts["force_parity"]["error"] = "reference count: " + safe_err(e)
            finally:
                await tr.rollback()

        tr = conn.transaction(readonly=True)
        await tr.start()
        try:
            tenants = await collect_catalog(conn, cfg, facts, facts["cis_runtime"].get("user"))
        finally:
            await tr.rollback()
        await reference()
        for role, sid in sorted(RUNTIME_SECRETS.items()):
            await probe_login(role, sid, cfg, secrets, facts, tenants)
        if rt_value_from:
            await probe_login(CIS_RUNTIME, rt_value_from, cfg, secrets, facts, tenants)
        else:
            facts["logins"][CIS_RUNTIME] = {"error": facts["cis_runtime"]["error"]}
        await reference()
    finally:
        await conn.close()
    if "runtime" not in facts["ttv"] and not facts["ttv"].get("error"):
        facts["ttv"]["error"] = "CIS runtime count not taken (login failed)"
    return 0


def empty_facts() -> dict:
    return {"catalog": {"login": None, "registered": [], "anchor_owner": {}}, "roles": {}, "ownership": {},
            "owner_grants": {}, "runtime_grants": {}, "default_acl": {}, "consumer": {},
            "registry_writes": {}, "rls_enable_only": {}, "tenant_matrix": {}, "ttv": {}, "force_parity": {},
            "sessions": {}, "logins": {}, "cis_runtime": {}}


def parse_config(argv: list) -> dict:
    for a in reversed(argv[1:]):
        if a.startswith("{"):
            return json.loads(a)
    return {}


async def main(argv=None) -> int:
    argv = sys.argv if argv is None else argv
    cfg = parse_config(argv)
    facts = empty_facts()
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    try:
        await collect(cfg, facts)
        keys = state_keys(facts)
    except Exception as e:  # noqa: BLE001 — the probe could not run at all
        emit("header", {"probe": PROBE, "format": FORMAT, "generated_at": now, "notes": NOTES})
        emit("fatal", {"error": safe_err(e)})
        emit("summary", {"exit": 2, "cells": 0, "fatal": True})
        return 2
    cells = build_cells(facts, keys)
    emit("header", {"probe": PROBE, "format": FORMAT, "generated_at": now, "notes": NOTES,
                    "catalog_login": facts["catalog"]["login"],
                    "server_version": facts["catalog"].get("server_version"),
                    "registered": facts["catalog"]["registered"],
                    "anchor_owner": facts["catalog"].get("anchor_owner", {}),
                    "cis_runtime": {k: facts["cis_runtime"].get(k) for k in ("secret", "user", "task_definition")},
                    "state_keys": {KEY_TEXT[k]: v for k, v in keys.items()}})
    for c in cells:
        emit("cell", c.as_json(keys))
    for fq, modes in sorted(facts["tenant_matrix"].get("tables", {}).items()):
        emit("matrix", {"table": fq, "role": TENANT_POOL, "modes": modes})
    summary = summarize(cells, keys)
    emit("summary", summary)
    return summary["exit"]


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
