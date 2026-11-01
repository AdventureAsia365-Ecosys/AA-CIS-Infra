"""AA-1026 D5 (S263, tech lead T-15): the owner steps of a re-embed into another embedding space, run as `cis_owner`.

AA-CIS-App migration 328 registers the space of every vector column (`shared.embedding_space`,
`shared.embedding_column`); migration 329 adds the trigger function `shared._embedding_shadow_reset()`. Every other
owner step lives here, not as SQL functions in a migration: the view rebuild of a swap switched roles in dynamic SQL,
which the X1 role lint refuses in a migration (CIS PR #1225 preflight), and DDL on live tables run once per move is
easier to review and rehearse as one script with a dry run. The paid part (filling the shadow column) is the CIS job
`embedding_reembed`, never this script. Root runbook: `docs/ops/runbooks/embedding-re-embed.md`.

ACTION (one per dispatch; edit the constants in a one-line PR):
  "status"       read the registry rows of COLUMN's swap group and, per column, rows with a vector, rows still without
                 a shadow vector, the shadow / previous column (no write; MODE is ignored);
  "prepare"      ADD COLUMN <column>__shadow vector(<dimension of SPACE>) (nullable: a catalog-only change), its
                 comment, the trigger <column>__shadow_reset (BEFORE UPDATE OF <column>: a writer that rewrites a row's
                 serving vector empties that row's shadow vector, so the fill re-reads it and the swap never promotes a
                 vector of text that is gone) and the registry's shadow_column / shadow_space_key. Prepared already for
                 SPACE: the trigger is re-installed, nothing else (the fill resumes);
  "drop_shadow"  drop an unswapped shadow column and its trigger, registry cleared (e.g. after the T-15 test);
  "swap"         every column of COLUMN's swap group in one transaction: refuses while a row has a vector but no
                 shadow vector (the fill resumes; ALLOW_MISSING lets them through, empty), saves and drops the views
                 that read the columns (deepest first), removes the reset triggers, renames <column> -> <column>__prev
                 and <column>__shadow -> <column> (NOT NULL and the single-column indexes follow: <index> ->
                 <index>__prev, <index>__shadow -> <index>), recreates the views from their own definition with their
                 options, grants and comments (shallowest first), and records space / previous in the registry;
  "rollback"     the inverse while <column>__prev exists (the new vectors go back to the shadow column, its trigger
                 back on). Rows written after the swap have no old vector: refused unless ALLOW_MISSING, which leaves a
                 NOT NULL column nullable;
  "purge_blank"  before a swap, only for the two embedding CACHES (acp_contract.atom_embedding: atoms gone or with no
                 place; acp_contract.question_embedding: blank question text): delete the rows that have a vector, no
                 shadow vector and no text to re-embed (the fill reports them as blank_rows / blank_keys and the swap
                 refuses them). The writers re-embed a cache row on demand when its atom or question is used again.
                 EXPECT_BLANK = the fill's remaining_blank_rows: any other count is refused and rolled back. Data
                 deletion: dry run first (count printed, rolled back), apply on a tech lead yes. Other columns have no
                 purge: fix their text and re-run the fill, or swap with ALLOW_MISSING (runbook).
Views are recreated as WRITE_ROLE, so a swap or rollback refuses before any change when a view that reads the group
belongs to another role. The tour_place group's views (catalog.v_component_embedding, v_tour_component) are
catalog_owner's, and the master login is not a member of catalog_owner and never becomes one (X1 plan §1.4): that
group swaps with a contract cis/ migration under the catalog recipe (runbook). Dropping the kept old vectors
(`<column>__prev`) is not offered either: a DROP COLUMN of real data is a destructive cis/ migration
(`-- migrate: destructive`, DB Migrate snapshots the database first; skill aa-cis-schema destructive-ops).

MODE "dry_run" (as merged): the action inside a transaction, every DDL statement printed, the registry state printed
from inside it, then ROLLED BACK (a full rehearsal: it takes the same locks for a moment). MODE "apply": the same,
committed. Prints table / column / index / view names, space keys and counts only.

Local test: `python3 aa1026_embedding_shadow.py <DSN> [--apply]`.
"""

import asyncio
import re

MODE = "dry_run"
ACTION = "status"
COLUMN = "acp_contract.question_embedding.embedding"
SPACE = "titan-embed-text-v2/1024/v1"
ALLOW_MISSING = False
EXPECT_BLANK = None
# prepare only: None = vector(<dimension of SPACE>). Tests on a PostgreSQL without pgvector set an array type.
SHADOW_TYPE = None

SCRIPT_NAME = "aa1026_embedding_shadow"
WRITE_ROLE = "cis_owner"
ACTIONS = ("status", "prepare", "drop_shadow", "swap", "rollback", "purge_blank")
SHADOW, PREV, RESET = "__shadow", "__prev", "__shadow_reset"
RESET_FUNCTION = "shared._embedding_shadow_reset()"           # AA-CIS-App migration 329
_TYPE_RE = re.compile(r"^[a-z][a-z0-9_ ]*(\[\])?$")
# The blank-text rule of the CIS fill (AA-CIS-App services/embeddings/sources.py, sources atom_view and question_text:
# the text the writer embedded, empty after strip). Keep the two in step. Only rows still without a shadow vector.
_BLANK = "coalesce({text}, '') !~ '[^[:space:]]'"
PURGE_BLANK = {
    "acp_contract.atom_embedding.embedding": (
        "DELETE FROM acp_contract.atom_embedding t WHERE t.embedding IS NOT NULL AND t.embedding__shadow IS NULL "
        "AND NOT EXISTS (SELECT 1 FROM acp_contract.tour_atoms a WHERE a.atom_id = t.atom_id AND NOT "
        + _BLANK.format(text="CASE t.view WHEN 'place' THEN a.place ELSE coalesce(a.place, '') || ' ' "
                             "|| coalesce(a.action, '') END") + ")"),
    "acp_contract.question_embedding.embedding": (
        "DELETE FROM acp_contract.question_embedding t WHERE t.embedding IS NOT NULL "
        "AND t.embedding__shadow IS NULL AND " + _BLANK.format(text="t.question_text")),
}
# The views that read the given columns of a table, directly or through other views, with their depth (1 = reads the
# table): dropped deepest first, recreated shallowest first.
DEPENDENT_VIEWS = """
WITH RECURSIVE d(view_oid, depth) AS (
    SELECT DISTINCT r.ev_class, 1
      FROM pg_depend dep
      JOIN pg_rewrite r ON r.oid = dep.objid
     WHERE dep.classid = 'pg_rewrite'::regclass AND dep.refclassid = 'pg_class'::regclass
       AND dep.refobjid = $1::text::regclass AND dep.refobjsubid = ANY ($2::int[])
       AND r.ev_class <> $1::text::regclass
    UNION ALL
    SELECT r.ev_class, d.depth + 1
      FROM d
      JOIN pg_depend dep ON dep.refobjid = d.view_oid AND dep.classid = 'pg_rewrite'::regclass
                        AND dep.refclassid = 'pg_class'::regclass
      JOIN pg_rewrite r ON r.oid = dep.objid
     WHERE r.ev_class <> d.view_oid AND d.depth < 20
)
SELECT view_oid, max(depth)::int AS depth FROM d GROUP BY view_oid"""
VIEW_STATE = """
SELECT n.nspname AS schema, cl.relname AS name, cl.relkind::text AS relkind, pg_get_viewdef(cl.oid) AS def,
       pg_get_userbyid(cl.relowner) AS owner, cl.reloptions AS options, obj_description(cl.oid, 'pg_class') AS comment,
       EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = cl.oid AND a.attacl IS NOT NULL) AS column_grants
  FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace
 WHERE cl.oid = $1"""
VIEW_COLUMN_COMMENTS = """
SELECT a.attname AS name, col_description(a.attrelid, a.attnum) AS comment
  FROM pg_attribute a
 WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped AND col_description(a.attrelid, a.attnum) IS NOT NULL
 ORDER BY a.attnum"""
VIEW_GRANTS = """
SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END AS grantee,
       x.privilege_type AS privilege, x.is_grantable AS grantable
  FROM pg_class cl, aclexplode(cl.relacl) x
 WHERE cl.oid = $1 AND x.grantee <> cl.relowner
 ORDER BY 1, 2"""


class Refused(Exception):
    """A step refused: printed as `SCRIPT refuse`, the transaction rolled back."""


def out(event: str, **kw) -> None:
    print("SCRIPT " + " ".join([event] + [f"{k}={v}" for k, v in kw.items()]), flush=True)


def split_column(column: str) -> tuple:
    parts = column.split(".")
    if len(parts) != 3 or not all(p.replace("_", "").isalnum() for p in parts):
        raise ValueError(f"COLUMN must be schema.table.column, not {column!r}")
    return tuple(parts)


def _q(ident: str) -> str:
    return '"' + ident.replace('"', '""') + '"'


def _lit(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def _tbl(schema: str, table: str) -> str:
    return f"{_q(schema)}.{_q(table)}"


def _name_fits(name: str, what: str) -> str:
    if len(name) > 63:
        raise Refused(f"{what} name {name} is longer than 63 characters (rename it first)")
    return name


async def ddl(conn, sql: str, show: str = None) -> None:
    """Runs one DDL statement and prints it (a view body is printed by name only)."""
    out("ddl", sql=show or sql)
    await conn.execute(sql)


async def report(conn, schema: str, table: str, column: str) -> int:
    row = await conn.fetchrow("SELECT swap_group FROM shared.embedding_column WHERE table_schema = $1 "
                              "AND table_name = $2 AND column_name = $3", schema, table, column)
    if row is None:
        out("refuse", why=f"{schema}.{table}.{column} is not in shared.embedding_column")
        return 1
    rows = await conn.fetch("SELECT table_schema, table_name, column_name, space_key, shadow_column, shadow_space_key, "
                            "previous_column, previous_space_key FROM shared.embedding_column WHERE swap_group = $1 "
                            "ORDER BY 1, 2, 3", row["swap_group"])
    for r in rows:
        tbl = _tbl(r["table_schema"], r["table_name"])
        vectors = await conn.fetchval(f"SELECT count(*) FROM {tbl} WHERE {_q(r['column_name'])} IS NOT NULL")
        todo = None
        if r["shadow_column"]:
            todo = await conn.fetchval(f"SELECT count(*) FROM {tbl} WHERE {_q(r['column_name'])} IS NOT NULL "
                                       f"AND {_q(r['shadow_column'])} IS NULL")
        out("column", group=row["swap_group"], column=f"{r['table_schema']}.{r['table_name']}.{r['column_name']}",
            space=r["space_key"], shadow=r["shadow_column"], shadow_space=r["shadow_space_key"],
            previous=r["previous_column"], previous_space=r["previous_space_key"], vectors=vectors,
            without_shadow_vector=todo)
    return 0


# ── the steps (each inside the caller's transaction, as WRITE_ROLE) ────────────────────────────────────────────────

async def _registry_row(conn, schema: str, table: str, column: str, what: str):
    row = await conn.fetchrow("SELECT * FROM shared.embedding_column WHERE table_schema = $1 AND table_name = $2 "
                              "AND column_name = $3 FOR UPDATE", schema, table, column)
    if row is None:
        raise Refused(f"{what}: {schema}.{table}.{column} is not in shared.embedding_column")
    return row


async def _columns_of(conn, tbl: str) -> dict:
    """attname -> (attnum, attnotnull, type) of the live columns of a table."""
    rows = await conn.fetch("SELECT attname, attnum::int AS attnum, attnotnull, format_type(atttypid, atttypmod) AS typ "
                            "FROM pg_attribute WHERE attrelid = $1::text::regclass AND attnum > 0 "
                            "AND NOT attisdropped", tbl)
    return {r["attname"]: (r["attnum"], r["attnotnull"], r["typ"]) for r in rows}


async def reset_trigger(conn, schema: str, table: str, column: str, install: bool) -> None:
    """Drops, then (install) creates the trigger <column>__shadow_reset of the table."""
    trg = _name_fits(column + RESET, "trigger")
    shadow = column + SHADOW
    tbl = _tbl(schema, table)
    exists = await conn.fetchval("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = $1::text::regclass "
                                 "AND tgname = $2 AND NOT tgisinternal)", tbl, trg)
    if exists:
        await ddl(conn, f"DROP TRIGGER {_q(trg)} ON {tbl}")
    if install:
        await ddl(conn, f"CREATE TRIGGER {_q(trg)} BEFORE UPDATE OF {_q(column)} ON {tbl} FOR EACH ROW "
                        f"WHEN (NEW.{_q(column)} IS DISTINCT FROM OLD.{_q(column)} "
                        f"AND NEW.{_q(shadow)} IS NOT DISTINCT FROM OLD.{_q(shadow)}) "
                        f"EXECUTE FUNCTION shared._embedding_shadow_reset({_lit(shadow)})")


async def rename_indexes(conn, schema: str, table: str, column: str, strip: str, add: str) -> None:
    """Renames the single-column indexes of the table on `column`: strips `strip` from the end of the name, appends
    `add`."""
    rows = await conn.fetch(
        "SELECT ic.relname, n.nspname FROM pg_index x JOIN pg_class ic ON ic.oid = x.indexrelid "
        "JOIN pg_namespace n ON n.oid = ic.relnamespace "
        "JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = x.indkey[0] "
        "WHERE x.indrelid = $1::text::regclass AND x.indnatts = 1 AND a.attname = $2 AND NOT a.attisdropped "
        "ORDER BY ic.relname", _tbl(schema, table), column)
    for r in rows:
        name = r["relname"]
        base = name[:-len(strip)] if strip and name.endswith(strip) else name
        new = _name_fits(base + add, "index")
        if new != name:
            await ddl(conn, f"ALTER INDEX {_q(r['nspname'])}.{_q(name)} RENAME TO {_q(new)}")


async def prepare(conn, schema: str, table: str, column: str, space_key: str, column_type: str = None) -> str:
    c = await _registry_row(conn, schema, table, column, "prepare")
    s = await conn.fetchrow("SELECT dimension, status FROM shared.embedding_space WHERE space_key = $1", space_key)
    if s is None or s["status"] == "retired":
        raise Refused(f"prepare: space {space_key} is unknown or retired")
    if c["space_key"] == space_key:
        raise Refused(f"prepare: {schema}.{table}.{column} already serves {space_key}")
    if c["previous_column"] is not None:
        raise Refused(f"prepare: {schema}.{table}.{column} still keeps {c['previous_column']} (roll back or drop it "
                      "first)")
    if await conn.fetchval("SELECT to_regprocedure($1) IS NULL", RESET_FUNCTION):
        raise Refused(f"prepare: {RESET_FUNCTION} is missing (apply AA-CIS-App migration 329 first)")
    if c["shadow_column"] is not None:
        if c["shadow_space_key"] == space_key:
            await reset_trigger(conn, schema, table, column, True)
            return c["shadow_column"]                    # prepared already: the fill resumes
        raise Refused(f"prepare: {schema}.{table}.{column} has a shadow for {c['shadow_space_key']} (drop it first)")
    if column_type is None:
        if await conn.fetchval("SELECT to_regtype('vector') IS NULL"):
            raise Refused("prepare: pgvector is not installed")
        column_type = f"vector({int(s['dimension'])})"
    elif not _TYPE_RE.match(column_type):
        raise Refused(f"prepare: bad column type {column_type!r}")
    shadow = _name_fits(column + SHADOW, "column")
    tbl = _tbl(schema, table)
    await ddl(conn, f"ALTER TABLE {tbl} ADD COLUMN {_q(shadow)} {column_type}")
    await ddl(conn, f"COMMENT ON COLUMN {tbl}.{_q(shadow)} IS "
                    + _lit(f"AA-1026: re-embed of {column} into {space_key} (shadow; swap with the AA-CIS-Infra "
                           f"run-script {SCRIPT_NAME})"))
    await reset_trigger(conn, schema, table, column, True)
    await conn.execute("UPDATE shared.embedding_column SET shadow_column = $4, shadow_space_key = $5, updated_at = now(), "
                       "updated_by = $6 WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
                       schema, table, column, shadow, space_key, SCRIPT_NAME)
    return shadow


async def drop_shadow(conn, schema: str, table: str, column: str) -> str:
    c = await _registry_row(conn, schema, table, column, "drop shadow")
    if c["shadow_column"] is None:
        raise Refused(f"drop shadow: {schema}.{table}.{column} has no shadow column")
    await reset_trigger(conn, schema, table, column, False)
    await ddl(conn, f"ALTER TABLE {_tbl(schema, table)} DROP COLUMN {_q(c['shadow_column'])}")
    await conn.execute("UPDATE shared.embedding_column SET shadow_column = NULL, shadow_space_key = NULL, "
                       "updated_at = now(), updated_by = $4 WHERE table_schema = $1 AND table_name = $2 "
                       "AND column_name = $3", schema, table, column, SCRIPT_NAME)
    return c["shadow_column"]


async def _saved_views(conn, group_rows: list, direction: str) -> list:
    """Every view reading a column of the group (serving, shadow or previous), with what a rebuild needs; refuses
    before any change when one cannot be rebuilt here."""
    depth = {}
    for c in group_rows:
        tbl = _tbl(c["table_schema"], c["table_name"])
        cols = await _columns_of(conn, tbl)
        names = (c["column_name"], c["shadow_column"], c["previous_column"])
        attnums = [cols[n][0] for n in names if n and n in cols]
        for v in await conn.fetch(DEPENDENT_VIEWS, tbl, attnums):
            depth[v["view_oid"]] = max(depth.get(v["view_oid"], 0), v["depth"])
    saved = []
    for oid, d in depth.items():
        v = dict(await conn.fetchrow(VIEW_STATE, oid))
        name = f"{v['schema']}.{v['name']}"
        if v["relkind"] != "v":
            raise Refused(f"{direction}: {name} is not a plain view (rebuild it by hand)")
        if v["column_grants"]:
            raise Refused(f"{direction}: {name} has column grants (rebuild it by hand)")
        if v["owner"] != WRITE_ROLE:
            raise Refused(f"{direction}: {name} belongs to {v['owner']}, not {WRITE_ROLE}: this session may not "
                          "recreate it as its owner; swap this group with a cis/ migration (catalog recipe, runbook)")
        v["grants"] = [dict(g) for g in await conn.fetch(VIEW_GRANTS, oid)]
        if any(g["grantable"] for g in v["grants"]):
            raise Refused(f"{direction}: {name} has a grant WITH GRANT OPTION (rebuild it by hand)")
        v["column_comments"] = [dict(r) for r in await conn.fetch(VIEW_COLUMN_COMMENTS, oid)]
        v["depth"] = d
        saved.append(v)
    return saved


async def switch(conn, group: str, direction: str, allow_missing: bool) -> int:
    """Swap (direction 'swap') or roll back ('rollback') every column of a swap group, in the caller's transaction."""
    if direction not in ("swap", "rollback"):
        raise Refused(f"switch: direction must be swap or rollback, not {direction}")
    other_suffix, parked_suffix = (SHADOW, PREV) if direction == "swap" else (PREV, SHADOW)
    rows = await conn.fetch("SELECT * FROM shared.embedding_column WHERE swap_group = $1 "
                            "ORDER BY table_schema, table_name, column_name FOR UPDATE", group)
    if not rows:
        raise Refused(f"{direction}: no column in swap group {group}")

    # 1. every column of the group is ready
    for c in rows:
        name = f"{c['table_schema']}.{c['table_name']}"
        other = c["shadow_column"] if direction == "swap" else c["previous_column"]
        if other is None:
            raise Refused(f"{direction}: {name}.{c['column_name']} has no {other_suffix} column ("
                          + ("prepare and fill it first" if direction == "swap" else "nothing to roll back") + ")")
        tbl = _tbl(c["table_schema"], c["table_name"])
        cols = await _columns_of(conn, tbl)
        if c["column_name"] not in cols or other not in cols:
            raise Refused(f"{direction}: {name} lacks {c['column_name']} or {other}")
        if c["column_name"] + parked_suffix in cols:
            raise Refused(f"{direction}: {name}.{c['column_name'] + parked_suffix} already exists")
        _name_fits(c["column_name"] + parked_suffix, "column")
        if direction == "swap":
            dim = await conn.fetchval("SELECT dimension FROM shared.embedding_space WHERE space_key = $1",
                                      c["shadow_space_key"])
            typ = cols[other][2]
            if typ.startswith("vector(") and typ != f"vector({dim})":
                raise Refused(f"swap: {name}.{other} is {typ}, space {c['shadow_space_key']} has dimension {dim}")
            if not allow_missing:
                missing = await conn.fetchval(f"SELECT count(*) FROM {tbl} WHERE {_q(c['column_name'])} IS NOT NULL "
                                              f"AND {_q(other)} IS NULL")
                if missing:
                    raise Refused(f"swap: {name}: {missing} row(s) have a vector but no shadow vector (run the "
                                  "re-embed job again: it resumes)")

    # 2. the dependent views: saved (refused before any change if one cannot be rebuilt), dropped deepest first
    saved = await _saved_views(conn, rows, direction)
    saved.sort(key=lambda v: (-v["depth"], v["schema"], v["name"]))
    for v in saved:
        await ddl(conn, f"DROP VIEW {_q(v['schema'])}.{_q(v['name'])}")

    # 3. the renames, column by column, and the registry in the same transaction
    n = 0
    for c in rows:
        schema, table, column = c["table_schema"], c["table_name"], c["column_name"]
        tbl = _tbl(schema, table)
        other = c["shadow_column"] if direction == "swap" else c["previous_column"]
        parked = column + parked_suffix
        not_null = (await _columns_of(conn, tbl))[column][1]
        # the reset trigger names columns by number: off before the renames, back on after a rollback only
        await reset_trigger(conn, schema, table, column, False)
        await rename_indexes(conn, schema, table, column, "", parked_suffix)
        await ddl(conn, f"ALTER TABLE {tbl} RENAME COLUMN {_q(column)} TO {_q(parked)}")
        if not_null:
            await ddl(conn, f"ALTER TABLE {tbl} ALTER COLUMN {_q(parked)} DROP NOT NULL")
        await ddl(conn, f"ALTER TABLE {tbl} RENAME COLUMN {_q(other)} TO {_q(column)}")
        await rename_indexes(conn, schema, table, column, other_suffix, "")
        if not_null:
            missing = await conn.fetchval(f"SELECT count(*) FROM {tbl} WHERE {_q(column)} IS NULL")
            if missing == 0:
                await ddl(conn, f"ALTER TABLE {tbl} ALTER COLUMN {_q(column)} SET NOT NULL")
            elif allow_missing:
                out("notice", column=f"{schema}.{table}.{column}", stays="nullable", rows_without_vector=missing)
            else:
                raise Refused(f"{direction}: {schema}.{table}: {missing} row(s) have no vector in {other} (rows written "
                              "after the swap have no old vector: set ALLOW_MISSING, then delete or re-embed them)")
        if direction == "swap":
            await conn.execute(
                "UPDATE shared.embedding_column SET previous_column = $4, previous_space_key = space_key, "
                "space_key = shadow_space_key, shadow_column = NULL, shadow_space_key = NULL, updated_at = now(), "
                "updated_by = $5 WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
                schema, table, column, parked, SCRIPT_NAME)
            await conn.execute("UPDATE shared.embedding_space SET status = 'active', updated_at = now(), "
                               "updated_by = $2 WHERE space_key = $1 AND status <> 'active'",
                               c["shadow_space_key"], SCRIPT_NAME)
        else:
            await conn.execute(
                "UPDATE shared.embedding_column SET shadow_column = $4, shadow_space_key = space_key, "
                "space_key = previous_space_key, previous_column = NULL, previous_space_key = NULL, "
                "updated_at = now(), updated_by = $5 WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
                schema, table, column, parked, SCRIPT_NAME)
            await reset_trigger(conn, schema, table, column, True)
        n += 1

    # 4. the views again, shallowest first, as they were (their definition text resolves to the renamed columns)
    for v in sorted(saved, key=lambda v: (v["depth"], v["schema"], v["name"])):
        view = f"{_q(v['schema'])}.{_q(v['name'])}"
        options = f" WITH ({', '.join(v['options'])})" if v["options"] else ""
        await ddl(conn, f"CREATE VIEW {view}{options} AS {v['def'].rstrip().rstrip(';')}",
                  show=f"CREATE VIEW {view}{options} AS <its definition>")
        if v["comment"] is not None:
            await ddl(conn, f"COMMENT ON VIEW {view} IS {_lit(v['comment'])}", show=f"COMMENT ON VIEW {view}")
        for col in v["column_comments"]:
            await ddl(conn, f"COMMENT ON COLUMN {view}.{_q(col['name'])} IS {_lit(col['comment'])}",
                      show=f"COMMENT ON COLUMN {view}.{_q(col['name'])}")
        for g in v["grants"]:
            grantee = "PUBLIC" if g["grantee"] == "PUBLIC" else _q(g["grantee"])
            await ddl(conn, f"GRANT {g['privilege']} ON {view} TO {grantee}")
    return n


async def run(conn, mode: str, action: str) -> int:
    if action not in ACTIONS:
        out("refuse", why=f"ACTION must be one of {ACTIONS}")
        return 1
    schema, table, column = split_column(COLUMN)
    out(SCRIPT_NAME, mode=mode.upper(), action=action, column=COLUMN)
    if action == "status":
        async with conn.transaction(readonly=True):
            return await report(conn, schema, table, column)
    tx = conn.transaction()
    await tx.start()
    committed = False
    try:
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", SCRIPT_NAME)
        if await report(conn, schema, table, column):
            return 1
        group = await conn.fetchval("SELECT swap_group FROM shared.embedding_column WHERE table_schema = $1 "
                                    "AND table_name = $2 AND column_name = $3", schema, table, column)
        try:
            if action == "prepare":
                result = await prepare(conn, schema, table, column, SPACE, SHADOW_TYPE)
            elif action == "drop_shadow":
                result = await drop_shadow(conn, schema, table, column)
            elif action == "purge_blank":
                result = await purge_blank(conn, schema, table, column)
            else:
                result = await switch(conn, group, action, ALLOW_MISSING)
        except Refused as e:
            out("refuse", why=str(e))
            return 1
        out("done", action=action, result=result)
        await report(conn, schema, table, column)
        if mode == "apply":
            await tx.commit()
            committed = True
            out("committed", action=action)
        else:
            out("rolled_back", reason="dry_run", action=action)
    finally:
        if not committed:
            await tx.rollback()
    return 0


async def purge_blank(conn, schema: str, table: str, column: str) -> int:
    if COLUMN not in PURGE_BLANK:
        raise Refused(f"{COLUMN} is not an embedding cache: fix its text and re-run the fill, or swap with "
                      "ALLOW_MISSING (runbook)")
    if not isinstance(EXPECT_BLANK, int) or isinstance(EXPECT_BLANK, bool) or EXPECT_BLANK < 0:
        raise Refused("set EXPECT_BLANK to the fill's remaining_blank_rows")
    if not await conn.fetchval("SELECT shadow_column FROM shared.embedding_column WHERE table_schema = $1 "
                               "AND table_name = $2 AND column_name = $3", schema, table, column):
        raise Refused(f"{COLUMN} has no shadow column (prepare and fill first)")
    result = await conn.fetchval(f"WITH d AS ({PURGE_BLANK[COLUMN]} RETURNING 1) SELECT count(*) FROM d")
    if result != EXPECT_BLANK:
        raise Refused(f"{result} blank row(s) found, EXPECT_BLANK is {EXPECT_BLANK}: nothing deleted (re-run the "
                      "fill and read its remaining_blank_rows)")
    return result


async def main(conn):
    return await run(conn, MODE, ACTION)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-1026: embedding re-embed owner steps (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, "apply" if args.apply else "dry_run", ACTION)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
