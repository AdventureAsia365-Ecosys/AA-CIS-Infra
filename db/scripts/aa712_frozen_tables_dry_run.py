"""AA-712 X4 DRY RUN (read-only): the frozen TripPlanner place tables before tp-018 drops them, and the tripplanner
grants on CIS objects before CIS 270 revokes them. Skill aa-cis-schema references/destructive-ops.md, step 1.

Dispatch: DB Migrate, mode=run-script, script=db/scripts/aa712_frozen_tables_dry_run.py (READ_ONLY: the session is
default_transaction_read_only, the idle check only reports). Dispatch it twice some minutes apart (or before and
after a TripPlanner smoke) to see whether any read counter moves.

Output (counts, names of tables / roles, timestamps; no row values):
  SCRIPT table name=<t> exists=<t|f> rows=<exact> bytes=<total relation size> last_write=<ts|-> write_column=<col|->
         seq_scan=<n> idx_scan=<n> ins=<n> upd=<n> del=<n> last_analyze=<ts|->
  SCRIPT stats_reset database=<ts|->                       (pg_stat counters count from here)
  SCRIPT statements table=<t> statements=<n> calls=<n> roles=<r,…>   (pg_stat_statements, when installed)
  SCRIPT dependent object=<name> on=<t> kind=<view|fk>     (what would block tp-018's DROP … RESTRICT)
  SCRIPT grant table=<t> grantee=<role> privileges=<…>     (who can touch the frozen tables)
  SCRIPT id_map rows=<n> trip_events_with_old_ids=<n> drafts_with_old_ids=<n>
  SCRIPT cis_grant object=<schema.name | schema> privilege=<p> grantor=<role> by_owner=<t|f>   (CIS 270 preview)
  SCRIPT verdict drop_ready=<true|false> revoke_ready=<true|false> reasons=<…>
drop_ready: every table exists or is already gone, no dependent outside the eight, no write on or after tp-018's
cutoff. revoke_ready: every grant 270 removes was made by the object's owner (cis_owner), so cis_owner's REVOKE
removes it. Read counters are reported, not judged (they count since the stats reset).
"""

READ_ONLY = True

FROZEN = ("itinerary_components", "tour_day", "tour_stop", "tour_graph_build", "tour_graph_edge", "tour_graph_node",
          "tour_leg", "tour_junction")
# The one write-time column of a table, where it has one (tp-001 / tp-003 / tp-004).
WRITE_COLUMN = {"itinerary_components": "created_at", "tour_day": "extracted_at", "tour_graph_build": "built_at"}
# tp-018's guard: no row written on or after this instant (AA-712 slice 6a removed the writers on 14/10/2026).
CUTOFF = "2026-10-16 00:00:00+00"
# What CIS 270 revokes from tripplanner.
CIS_270_RELATIONS = ("gold_aa_internal.published_tours", "shared.destinations", "shared.v_destination_photos",
                     "shared.v_tour_photos", "acp_contract.v_active_tour_atoms")
CIS_270_SCHEMAS = ("gold_aa_internal", "acp_contract")

STAT_SQL = """
SELECT s.seq_scan, coalesce(s.idx_scan, 0) AS idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
       greatest(s.last_analyze, s.last_autoanalyze) AS last_analyze, pg_total_relation_size(s.relid) AS bytes
  FROM pg_stat_user_tables s WHERE s.relid = $1::text::regclass
"""

# $1 = the relations as text (schema-qualified names), cast here: no regclass codec needed on the client.
DEPENDENTS_SQL = """
WITH f AS (SELECT array_agg(x::regclass) AS oids FROM unnest($1::text[]) x)
SELECT DISTINCT v.oid::regclass::text AS dep, d.refobjid::regclass::text AS dep_on, 'view' AS kind
  FROM pg_depend d
  JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
  JOIN pg_class v ON v.oid = r.ev_class
 CROSS JOIN f
 WHERE d.refobjid = ANY(f.oids) AND NOT v.oid = ANY(f.oids)
UNION
SELECT c.conrelid::regclass::text || ' (' || c.conname || ')', c.confrelid::regclass::text, 'fk'
  FROM pg_constraint c CROSS JOIN f
 WHERE c.contype = 'f' AND c.confrelid = ANY(f.oids) AND NOT c.conrelid = ANY(f.oids)
 ORDER BY 1
"""

GRANTS_SQL = """
SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS grantee,
       string_agg(DISTINCT a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE c.oid = $1::text::regclass AND a.grantee <> c.relowner
 GROUP BY 1 ORDER BY 1
"""

# The tripplanner grants on the objects CIS 270 revokes: table and column level, with grantor and owner.
CIS_RELATION_GRANTS_SQL = """
WITH f AS (SELECT array_agg(x::regclass) AS oids FROM unnest($1::text[]) x)
SELECT c.oid::regclass::text AS object, a.privilege_type AS privilege, pg_get_userbyid(a.grantor) AS grantor,
       a.grantor = c.relowner AS by_owner
  FROM f, pg_class c, aclexplode(c.relacl) a
 WHERE c.oid = ANY(f.oids) AND a.grantee = 'tripplanner'::regrole
UNION
SELECT DISTINCT c.oid::regclass::text || ' (columns)', a.privilege_type, pg_get_userbyid(a.grantor),
       a.grantor = c.relowner
  FROM f
  JOIN pg_class c ON c.oid = ANY(f.oids)
  JOIN pg_attribute att ON att.attrelid = c.oid AND att.attnum > 0 AND NOT att.attisdropped
 CROSS JOIN LATERAL aclexplode(att.attacl) a
 WHERE a.grantee = 'tripplanner'::regrole
 ORDER BY 1, 2
"""

CIS_SCHEMA_GRANTS_SQL = """
SELECT n.nspname::text AS object, a.privilege_type AS privilege, pg_get_userbyid(a.grantor) AS grantor,
       a.grantor = n.nspowner AS by_owner
  FROM pg_namespace n, aclexplode(n.nspacl) a
 WHERE n.nspname = ANY($1::text[]) AND a.grantee = 'tripplanner'::regrole
 ORDER BY 1, 2
"""

ID_MAP_SQL = """
SELECT (SELECT count(*) FROM tripplanner.component_id_map) AS rows,
       count(*) AS events, count(DISTINCT e.trip_id) AS drafts
  FROM tripplanner.trip_events e
 WHERE e.payload ? 'component_id'
   AND EXISTS (SELECT 1 FROM tripplanner.component_id_map m WHERE m.old_id::text = e.payload ->> 'component_id')
"""

STATEMENTS_SQL = """
SELECT count(*) AS statements, coalesce(sum(s.calls), 0) AS calls,
       coalesce(string_agg(DISTINCT pg_get_userbyid(s.userid), ',' ORDER BY pg_get_userbyid(s.userid)), '') AS roles
  FROM pg_stat_statements s
 WHERE s.query ~* ('\\mtripplanner\\.' || $1 || '\\M')
"""


def _ts(v) -> str:
    return v.isoformat() if v is not None else "-"


async def _exists(conn, rel: str) -> bool:
    return await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", rel)


async def main(conn):
    reasons = []
    cutoff = await conn.fetchval("SELECT $1::text::timestamptz", CUTOFF)
    present = []
    for t in FROZEN:
        rel = f"tripplanner.{t}"
        if not await _exists(conn, rel):
            print(f"SCRIPT table name={t} exists=f")
            continue
        present.append(rel)
        rows = await conn.fetchval(f"SELECT count(*) FROM {rel}")
        col = WRITE_COLUMN.get(t)
        last = await conn.fetchval(f"SELECT max({col}) FROM {rel}") if col else None
        if last is not None and last >= cutoff:
            reasons.append(f"write_after_cutoff:{t}")
        s = await conn.fetchrow(STAT_SQL, rel)
        print(f"SCRIPT table name={t} exists=t rows={rows} bytes={s['bytes']} last_write={_ts(last)} "
              f"write_column={col or '-'} seq_scan={s['seq_scan']} idx_scan={s['idx_scan']} ins={s['n_tup_ins']} "
              f"upd={s['n_tup_upd']} del={s['n_tup_del']} last_analyze={_ts(s['last_analyze'])}")
        for g in await conn.fetch(GRANTS_SQL, rel):
            print(f"SCRIPT grant table={t} grantee={g['grantee']} privileges={g['privileges']}")
    reset = await conn.fetchval("SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()")
    print(f"SCRIPT stats_reset database={_ts(reset)}")

    if await conn.fetchval("SELECT to_regclass('public.pg_stat_statements') IS NOT NULL"):
        for t in FROZEN:
            try:
                st = await conn.fetchrow(STATEMENTS_SQL, t)
            except Exception as e:  # noqa: BLE001 - e.g. no permission on another role's statements
                print(f"SCRIPT statements table={t} error={type(e).__name__}")
                continue
            print(f"SCRIPT statements table={t} statements={st['statements']} calls={st['calls']} "
                  f"roles={st['roles'] or '-'}")
    else:
        print("SCRIPT statements unavailable=pg_stat_statements")

    if present:
        for d in await conn.fetch(DEPENDENTS_SQL, present):
            print(f"SCRIPT dependent object={d['dep']} on={d['dep_on']} kind={d['kind']}")
            reasons.append(f"dependent:{d['dep']}")

    if await _exists(conn, "tripplanner.component_id_map"):
        m = await conn.fetchrow(ID_MAP_SQL)
        print(f"SCRIPT id_map rows={m['rows']} trip_events_with_old_ids={m['events']} "
              f"drafts_with_old_ids={m['drafts']}")
    else:
        print("SCRIPT id_map exists=f")
        reasons.append("id_map_missing")

    revoke_ready = True
    if await conn.fetchval("SELECT to_regrole('tripplanner') IS NOT NULL"):
        rels = [r for r in CIS_270_RELATIONS if await _exists(conn, r)]
        grants = list(await conn.fetch(CIS_RELATION_GRANTS_SQL, rels)) if rels else []
        grants += list(await conn.fetch(CIS_SCHEMA_GRANTS_SQL, list(CIS_270_SCHEMAS)))
        for g in grants:
            print(f"SCRIPT cis_grant object={g['object']} privilege={g['privilege']} grantor={g['grantor']} "
                  f"by_owner={'t' if g['by_owner'] else 'f'}")
            if not g["by_owner"]:
                revoke_ready = False
        if not grants:
            print("SCRIPT cis_grant none=t")
    drop_ready = not reasons
    print(f"SCRIPT verdict drop_ready={'true' if drop_ready else 'false'} "
          f"revoke_ready={'true' if revoke_ready else 'false'} reasons={','.join(reasons) or '-'}")
    return 0
