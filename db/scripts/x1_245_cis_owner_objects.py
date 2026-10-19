"""X1 S21 (AA-860): what CIS migration 245 (CIS schemas and objects to cis_owner) will move and check on Dev, read
before its apply. Read-only. Run it after rl-002 (X1 S20) and before the 245 `apply`; compare its output with the
NOTICE lines of the 245 apply ("migration 245: <kind> <name> -> cis_owner", then the total).

Dispatch: DB Migrate, mode=run-script, script=db/scripts/x1_245_cis_owner_objects.py.

Why a script: 245 reads the objects it moves from the catalog at apply time (AA-CIS-App
docs/implementation-notes/AA-860-S21.md: the schema reference lists tables, views, functions and enum names, but
not standalone sequences, type owners, domains, ranges or statistics). This prints the same list from Dev first,
with the exact query of 245 step 4 (MOVE_SQL; db/tests/test_x1_245_cis_owner_objects.py checks it is still the
query in db/migrations/cis/245_x1_cis_owner.sql once the copy lands), and every condition one of 245's guards
would refuse, so a refusal is known before the apply holds its locks.

Output (names and counts only, no row values):
  SCRIPT login session_user=<role> member_of_cis_owner=<t|f|-> member_of_cis_app=<t|f> registered_244=<t|f>
         registered_245=<t|f>
  SCRIPT cis_owner exists=<t|f> nologin=<t|f> plain=<t|f> member_of=<roles|-> create_on_db=<t|f>
         members=<roles|->                                      (245 guard 0; rl-002)
  SCRIPT schema <name> owner=<role>                             (the 12 owners.yaml CIS schemas)
  SCRIPT move <kind> <schema.name>                              (245 step 4, in its order)
  SCRIPT move_total <n> <kind>=<n> …
  SCRIPT refuse <reason> <object> (<owner>)                     (would fail 245 guard 8a / 8b / 8d / 8e)
  SCRIPT extension_member <kind> <schema.name>                  (left with the master, by design)
  SCRIPT rls force=<n> [<tables>] enable_only=<n>               (245 expects exactly the 8 FORCE tables)
  SCRIPT default_acl role=<role> schema=<s> type=<t> grantee=<g> privileges=<…>
  SCRIPT view <schema.name> readable_by_login=<t|f>             (245 counts the readable ones before / after)
  SCRIPT lock_tables <n>                                        (245 step 1 takes ACCESS EXCLUSIVE on these)
  SCRIPT summary move=<n> refuse=<n> ok=<t|f>
ok=t means none of the checks this script can see would refuse 245. It cannot see the behavioural block (counts
as cis_owner / cis_app after the transfer): that runs only inside the 245 transaction.
"""

READ_ONLY = True

CIS_SCHEMAS = ["acp_contract", "acp_deliver", "acp_gold_output", "acp_shared", "acp_silver_s2", "acp_silver_s3",
               "acp_silver_s4", "catalog", "geo", "gold_aa_internal", "shared", "silver_aa_internal"]
RUNTIME_SCHEMAS = [s for s in CIS_SCHEMAS if s != "catalog"]
FORCE_EXPECTED = ["gold_aa_internal.content_exports", "gold_aa_internal.published_tours",
                  "gold_aa_internal.webhook_deliveries", "shared.pipeline_runs", "silver_aa_internal.generated_content",
                  "silver_aa_internal.quality_scores", "silver_aa_internal.raw_tours", "silver_aa_internal.seo_context"]

# Verbatim the object query of AA-CIS-App api/migrations/245_x1_cis_owner.sql step 4 (whitespace aside; the test
# compares them). It names the master and the 11 runtime schemas literally, like the migration.
MOVE_SQL = """
        WITH s AS (
            SELECT ns.oid, ns.nspname FROM pg_catalog.pg_namespace ns
             WHERE ns.nspname = ANY (ARRAY['acp_contract', 'acp_deliver', 'acp_gold_output', 'acp_shared',
                                           'acp_silver_s2', 'acp_silver_s3', 'acp_silver_s4', 'geo',
                                           'gold_aa_internal', 'shared', 'silver_aa_internal'])),
        ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e'),
        master AS (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = 'aa_cis_admin'),
        objects AS (
            -- relations; indexes, toast, row types and owned / identity sequences follow their table
            SELECT 1 AS ord,
                   CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE'
                                  WHEN 'S' THEN 'SEQUENCE' WHEN 'c' THEN 'TYPE' ELSE 'TABLE' END AS kind,
                   pg_catalog.format('%I.%I', s.nspname, c.relname) AS name
              FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
             WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S', 'c')
               AND c.relowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_class'::regclass AND ext.objid = c.oid)
               AND NOT (c.relkind = 'S' AND EXISTS (
                        SELECT 1 FROM pg_catalog.pg_depend d
                         WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
                           AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype IN ('a', 'i')))
            UNION ALL
            -- enum, domain and range types (their array types follow; composite row types are relations above)
            SELECT 2, CASE y.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, pg_catalog.format('%I.%I', s.nspname, y.typname)
              FROM pg_catalog.pg_type y JOIN s ON s.oid = y.typnamespace
             WHERE y.typtype IN ('e', 'd', 'r') AND y.typowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_type'::regclass AND ext.objid = y.oid)
            UNION ALL
            SELECT 3, CASE f.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
                   pg_catalog.format('%I.%I(%s)', s.nspname, f.proname, pg_catalog.pg_get_function_identity_arguments(f.oid))
              FROM pg_catalog.pg_proc f JOIN s ON s.oid = f.pronamespace
             WHERE f.proowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_proc'::regclass AND ext.objid = f.oid)
            UNION ALL
            SELECT 4, 'STATISTICS', pg_catalog.format('%I.%I', s.nspname, x.stxname)
              FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace
             WHERE x.stxowner = (SELECT oid FROM master)
            UNION ALL
            SELECT 5, 'COLLATION', pg_catalog.format('%I.%I', s.nspname, x.collname)
              FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
             WHERE x.collowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_collation'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 6, 'CONVERSION', pg_catalog.format('%I.%I', s.nspname, x.conname)
              FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
             WHERE x.conowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_conversion'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 7, 'TEXT SEARCH DICTIONARY', pg_catalog.format('%I.%I', s.nspname, x.dictname)
              FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
             WHERE x.dictowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_dict'::regclass AND ext.objid = x.oid)
            UNION ALL
            SELECT 8, 'TEXT SEARCH CONFIGURATION', pg_catalog.format('%I.%I', s.nspname, x.cfgname)
              FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace
             WHERE x.cfgowner = (SELECT oid FROM master)
               AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_config'::regclass AND ext.objid = x.oid))
        SELECT kind, name FROM objects ORDER BY ord, name
"""

LOGIN_SQL = """
SELECT session_user::text AS login,
       CASE WHEN to_regrole('cis_owner') IS NULL THEN NULL
            ELSE pg_catalog.pg_has_role(session_user, 'cis_owner', 'MEMBER') END AS in_owner,
       pg_catalog.pg_has_role(session_user, 'cis_app', 'MEMBER') AS in_app,
       EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '244') AS v244,
       EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = '245') AS v245"""

OWNER_ROLE_SQL = """
SELECT NOT r.rolcanlogin AS nologin,
       NOT (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication) AS plain,
       (SELECT string_agg(pg_catalog.pg_get_userbyid(m.roleid), ',' ORDER BY pg_catalog.pg_get_userbyid(m.roleid))
          FROM pg_catalog.pg_auth_members m WHERE m.member = r.oid) AS member_of,
       pg_catalog.has_database_privilege(r.oid, pg_catalog.current_database(), 'CREATE') AS create_on_db,
       (SELECT string_agg(x.rolname, ',' ORDER BY x.rolname) FROM pg_catalog.pg_roles x
         WHERE pg_catalog.pg_has_role(x.oid, r.oid, 'MEMBER') AND x.oid <> r.oid AND NOT x.rolsuper) AS members
  FROM pg_catalog.pg_roles r WHERE r.rolname = 'cis_owner'"""

SCHEMAS_SQL = """
SELECT n.nspname::text AS name, pg_catalog.pg_get_userbyid(n.nspowner)::text AS owner
  FROM pg_catalog.pg_namespace n WHERE n.nspname = ANY($1::text[]) ORDER BY 1"""

# Everything with an owner in the 12 schemas that 245 guard 8a would refuse after step 4: not the master's (step 4
# moves only those) and not the expected end state (cis_owner; catalog relations: catalog_owner), or the master's
# but of a kind step 4 does not move. Extension members are listed separately.
REFUSE_OWNER_SQL = """
WITH s AS (SELECT ns.oid, ns.nspname FROM pg_catalog.pg_namespace ns WHERE ns.nspname = ANY($1::text[])),
ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e'),
owned AS (
    SELECT 'relation ' || c.relkind::text AS kind, s.nspname || '.' || c.relname AS name, c.relowner AS owner,
           s.nspname = 'catalog' AS in_catalog, c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S', 'c') AS movable,
           c.oid AS objid, 'pg_catalog.pg_class'::regclass AS classid
      FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace WHERE c.relkind NOT IN ('i', 'I')
    UNION ALL
    SELECT 'routine', s.nspname || '.' || f.proname, f.proowner, s.nspname = 'catalog', true, f.oid,
           'pg_catalog.pg_proc'::regclass
      FROM pg_catalog.pg_proc f JOIN s ON s.oid = f.pronamespace
    UNION ALL
    SELECT 'type ' || y.typtype::text, s.nspname || '.' || y.typname, y.typowner, s.nspname = 'catalog',
           y.typtype IN ('e', 'd', 'r'), y.oid, 'pg_catalog.pg_type'::regclass
      FROM pg_catalog.pg_type y JOIN s ON s.oid = y.typnamespace
     WHERE y.typrelid = 0 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type a WHERE a.typarray = y.oid)
    UNION ALL
    SELECT 'statistics', s.nspname || '.' || x.stxname, x.stxowner, s.nspname = 'catalog', true, x.oid,
           'pg_catalog.pg_statistic_ext'::regclass
      FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace
    UNION ALL
    SELECT 'operator', s.nspname || '.' || x.oprname, x.oprowner, s.nspname = 'catalog', false, x.oid,
           'pg_catalog.pg_operator'::regclass
      FROM pg_catalog.pg_operator x JOIN s ON s.oid = x.oprnamespace
    UNION ALL
    SELECT 'operator class', s.nspname || '.' || x.opcname, x.opcowner, s.nspname = 'catalog', false, x.oid,
           'pg_catalog.pg_opclass'::regclass
      FROM pg_catalog.pg_opclass x JOIN s ON s.oid = x.opcnamespace
    UNION ALL
    SELECT 'operator family', s.nspname || '.' || x.opfname, x.opfowner, s.nspname = 'catalog', false, x.oid,
           'pg_catalog.pg_opfamily'::regclass
      FROM pg_catalog.pg_opfamily x JOIN s ON s.oid = x.opfnamespace
    UNION ALL
    SELECT 'collation', s.nspname || '.' || x.collname, x.collowner, s.nspname = 'catalog', true, x.oid,
           'pg_catalog.pg_collation'::regclass
      FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
    UNION ALL
    SELECT 'conversion', s.nspname || '.' || x.conname, x.conowner, s.nspname = 'catalog', true, x.oid,
           'pg_catalog.pg_conversion'::regclass
      FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
    UNION ALL
    SELECT 'text search dictionary', s.nspname || '.' || x.dictname, x.dictowner, s.nspname = 'catalog', true,
           x.oid, 'pg_catalog.pg_ts_dict'::regclass
      FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
    UNION ALL
    SELECT 'text search configuration', s.nspname || '.' || x.cfgname, x.cfgowner, s.nspname = 'catalog', true,
           x.oid, 'pg_catalog.pg_ts_config'::regclass
      FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace)
SELECT kind, name, pg_catalog.pg_get_userbyid(owner)::text AS owner,
       EXISTS (SELECT 1 FROM ext WHERE ext.classid = owned.classid AND ext.objid = owned.objid) AS extension_member,
       CASE
         WHEN in_catalog AND kind LIKE 'relation %' THEN
              CASE WHEN pg_catalog.pg_get_userbyid(owner) = 'catalog_owner' THEN NULL
                   ELSE 'catalog_relation_not_catalog_owner' END
         WHEN in_catalog THEN
              CASE WHEN pg_catalog.pg_get_userbyid(owner) = 'cis_owner' THEN NULL
                   ELSE 'catalog_object_not_moved' END
         WHEN pg_catalog.pg_get_userbyid(owner) = 'cis_owner' THEN NULL
         WHEN pg_catalog.pg_get_userbyid(owner) = 'aa_cis_admin' AND movable THEN NULL
         WHEN pg_catalog.pg_get_userbyid(owner) = 'aa_cis_admin' THEN 'kind_not_moved'
         ELSE 'third_owner'
       END AS reason
  FROM owned ORDER BY 1, 2"""

SECDEF_SQL = """
SELECT n.nspname || '.' || f.proname AS name, pg_catalog.pg_get_userbyid(f.proowner)::text AS owner
  FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid = f.pronamespace
 WHERE n.nspname = ANY($1::text[]) AND f.prosecdef ORDER BY 1"""

RLS_SQL = """
SELECT n.nspname || '.' || c.relname AS name, c.relforcerowsecurity AS force
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = ANY($1::text[]) AND c.relrowsecurity ORDER BY 1"""

OWNER_POLICY_SQL = r"""
SELECT n.nspname || '.' || c.relname || ' ' || p.polname AS name
  FROM pg_catalog.pg_policy p JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE p.polname LIKE '%\_cis\_owner\_all'
    OR (to_regrole('cis_owner') IS NOT NULL AND to_regrole('cis_owner')::oid = ANY (p.polroles))
 ORDER BY 1"""

DEFAULT_ACL_SQL = """
SELECT pg_catalog.pg_get_userbyid(d.defaclrole)::text AS role, n.nspname::text AS schema,
       d.defaclobjtype::text AS type, a.grantee::regrole::text AS grantee,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
  FROM pg_catalog.pg_default_acl d JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace,
       pg_catalog.aclexplode(d.defaclacl) a
 WHERE n.nspname = ANY($1::text[])
 GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4"""

VIEWS_SQL = """
SELECT pg_catalog.format('%I.%I', n.nspname, c.relname) AS name, pg_catalog.has_table_privilege(c.oid, 'SELECT') AS readable
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = ANY($1::text[]) AND c.relkind = 'v' ORDER BY 1"""

LOCK_SQL = """
SELECT count(*) AS n FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = ANY($1::text[]) AND c.relkind IN ('r', 'p')"""


def _flag(v):
    return "-" if v is None else ("t" if v else "f")


async def main(conn):
    refuse = []
    lg = await conn.fetchrow(LOGIN_SQL)
    print(f"SCRIPT login session_user={lg['login']} member_of_cis_owner={_flag(lg['in_owner'])} "
          f"member_of_cis_app={_flag(lg['in_app'])} registered_244={_flag(lg['v244'])} "
          f"registered_245={_flag(lg['v245'])}", flush=True)
    if lg["login"] != "aa_cis_admin":
        refuse.append("guard0_login_not_master")
    if not lg["in_owner"]:
        refuse.append("guard0_master_not_member_of_cis_owner")
    if not lg["in_app"]:
        refuse.append("guard0_master_not_member_of_cis_app")
    if not lg["v244"]:
        refuse.append("guard0_244_not_applied")

    o = await conn.fetchrow(OWNER_ROLE_SQL)
    if o is None:
        print("SCRIPT cis_owner exists=f (apply rl-002 first)", flush=True)
        refuse.append("guard0_cis_owner_missing")
    else:
        members = [m for m in (o["members"] or "").split(",") if m]
        print(f"SCRIPT cis_owner exists=t nologin={_flag(o['nologin'])} plain={_flag(o['plain'])} "
              f"member_of={o['member_of'] or '-'} create_on_db={_flag(o['create_on_db'])} "
              f"members={','.join(members) or '-'}", flush=True)
        if not (o["nologin"] and o["plain"]) or o["member_of"]:
            refuse.append("guard0_cis_owner_shape")
        if not o["create_on_db"]:
            refuse.append("guard0_cis_owner_no_create_on_db")
        if set(members) - {"aa_cis_admin", "db_migrator"}:
            refuse.append("guard0_other_members_of_cis_owner")

    for r in await conn.fetch(SCHEMAS_SQL, CIS_SCHEMAS):
        print(f"SCRIPT schema {r['name']} owner={r['owner']}", flush=True)

    counts = {}
    moved = 0
    for r in await conn.fetch(MOVE_SQL):
        moved += 1
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
        print(f"SCRIPT move {r['kind'].lower()} {r['name']}", flush=True)
    print("SCRIPT move_total " + str(moved) + " "
          + " ".join(f"{k.lower().replace(' ', '_')}={v}" for k, v in sorted(counts.items())), flush=True)

    for r in await conn.fetch(REFUSE_OWNER_SQL, CIS_SCHEMAS):
        if r["extension_member"]:
            print(f"SCRIPT extension_member {r['kind']} {r['name']}", flush=True)
        elif r["reason"]:
            refuse.append(r["reason"])
            print(f"SCRIPT refuse {r['reason']} {r['kind']} {r['name']} ({r['owner']})", flush=True)
    for r in await conn.fetch(SECDEF_SQL, CIS_SCHEMAS):
        refuse.append("security_definer")
        print(f"SCRIPT refuse security_definer routine {r['name']} ({r['owner']})", flush=True)

    rls = await conn.fetch(RLS_SQL, CIS_SCHEMAS)
    force = [r["name"] for r in rls if r["force"]]
    print(f"SCRIPT rls force={len(force)} [{','.join(force)}] enable_only={len(rls) - len(force)}", flush=True)
    if force != sorted(FORCE_EXPECTED):
        refuse.append("force_set")
        print(f"SCRIPT refuse force_set expected [{','.join(sorted(FORCE_EXPECTED))}]", flush=True)
    for r in await conn.fetch(OWNER_POLICY_SQL):
        print(f"SCRIPT cis_owner_policy {r['name']} (245 drops and re-creates the 8 FORCE ones)", flush=True)

    for r in await conn.fetch(DEFAULT_ACL_SQL, CIS_SCHEMAS):
        print(f"SCRIPT default_acl role={r['role']} schema={r['schema']} type={r['type']} grantee={r['grantee']} "
              f"privileges={r['privileges']}", flush=True)
        if r["grantee"] != "cis_app" or r["role"] not in ("aa_cis_admin", "cis_owner") or r["schema"] == "catalog":
            refuse.append("default_acl")
            print(f"SCRIPT refuse default_acl role={r['role']} schema={r['schema']} grantee={r['grantee']}", flush=True)

    for r in await conn.fetch(VIEWS_SQL, CIS_SCHEMAS):
        print(f"SCRIPT view {r['name']} readable_by_login={_flag(r['readable'])}", flush=True)
    lock = await conn.fetchval(LOCK_SQL, RUNTIME_SCHEMAS)
    print(f"SCRIPT lock_tables {lock}", flush=True)
    print(f"SCRIPT summary move={moved} refuse={len(refuse)} ok={_flag(not refuse)}"
          + (f" reasons={','.join(sorted(set(refuse)))}" if refuse else ""), flush=True)
