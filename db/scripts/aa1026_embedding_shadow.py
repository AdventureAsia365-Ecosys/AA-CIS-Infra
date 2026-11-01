"""AA-1026 D5 (S263, tech lead T-15): the owner steps of a re-embed into another embedding space, run as `cis_owner`.

AA-CIS-App migration 340 registers the space of every vector column (`shared.embedding_space`,
`shared.embedding_column`); migration 341 adds the owner functions this script calls. The paid part (filling the
shadow column) is the CIS job `embedding_reembed`, never this script. Root runbook:
`docs/ops/runbooks/embedding-re-embed.md`.

ACTION (one per dispatch; edit the constants in a one-line PR):
  "status"       read the registry rows of COLUMN's swap group and, per column, rows with a vector, rows still without
                 a shadow vector, the shadow / previous column (no write; MODE is ignored);
  "prepare"      shared.embedding_prepare_shadow(COLUMN, SPACE): ADD COLUMN <column>__shadow vector(<dimension>);
  "drop_shadow"  shared.embedding_drop_shadow(COLUMN): drop an unswapped shadow (e.g. after the T-15 test);
  "swap"         shared.embedding_swap(group of COLUMN, ALLOW_MISSING): the whole swap group, dependent views rebuilt;
  "rollback"     shared.embedding_rollback(group of COLUMN, ALLOW_MISSING);
  "purge_blank"  before a swap, only for the two embedding CACHES (acp_contract.atom_embedding: atoms gone or with no
                 place; acp_contract.question_embedding: blank question text): delete the rows that have a vector, no
                 shadow vector and no text to re-embed (the fill reports them as blank_rows / blank_keys and the swap
                 refuses them). The writers re-embed a cache row on demand when its atom or question is used again.
                 EXPECT_BLANK = the fill's remaining_blank_rows: any other count is refused and rolled back. Data
                 deletion: dry run first (count printed, rolled back), apply on a tech lead yes. Other columns have no
                 purge: fix their text and re-run the fill, or swap with ALLOW_MISSING (runbook).
A swap whose dependent views belong to catalog_owner (the tour_place group: catalog.v_component_embedding,
v_tour_component) needs a session that may SET ROLE catalog_owner, which the master login may not: run that swap as a
one-line cis/ migration applied by DB Migrate (db_migrator), see the runbook. `embedding_drop_previous` is destructive
(no rollback after it) and is not offered here: it follows the DRY RUN procedure in its own reviewed script.

MODE "dry_run" (as merged): the action inside a transaction, the registry state printed from inside it, then ROLLED
BACK. MODE "apply": the same, committed. Prints table / column names, space keys and counts only.

Local test: `python3 aa1026_embedding_shadow.py <DSN> [--apply]`.
"""

import asyncio

MODE = "dry_run"
ACTION = "status"
COLUMN = "acp_contract.question_embedding.embedding"
SPACE = "titan-embed-text-v2/1024/v1"
ALLOW_MISSING = False
EXPECT_BLANK = None

SCRIPT_NAME = "aa1026_embedding_shadow"
WRITE_ROLE = "cis_owner"
ACTIONS = ("status", "prepare", "drop_shadow", "swap", "rollback", "purge_blank")
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


def out(event: str, **kw) -> None:
    print("SCRIPT " + " ".join([event] + [f"{k}={v}" for k, v in kw.items()]), flush=True)


def split_column(column: str) -> tuple:
    parts = column.split(".")
    if len(parts) != 3 or not all(p.replace("_", "").isalnum() for p in parts):
        raise ValueError(f"COLUMN must be schema.table.column, not {column!r}")
    return tuple(parts)


def _q(ident: str) -> str:
    return '"' + ident.replace('"', '""') + '"'


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
        tbl = f"{_q(r['table_schema'])}.{_q(r['table_name'])}"
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
        if action == "prepare":
            result = await conn.fetchval("SELECT shared.embedding_prepare_shadow($1, $2, $3, $4)",
                                         schema, table, column, SPACE)
        elif action == "drop_shadow":
            result = await conn.fetchval("SELECT shared.embedding_drop_shadow($1, $2, $3)", schema, table, column)
        elif action == "purge_blank":
            if COLUMN not in PURGE_BLANK:
                out("refuse", why=f"{COLUMN} is not an embedding cache: fix its text and re-run the fill, or swap "
                                  "with ALLOW_MISSING (runbook)")
                return 1
            if not isinstance(EXPECT_BLANK, int) or isinstance(EXPECT_BLANK, bool) or EXPECT_BLANK < 0:
                out("refuse", why="set EXPECT_BLANK to the fill's remaining_blank_rows")
                return 1
            if not await conn.fetchval("SELECT shadow_column FROM shared.embedding_column WHERE table_schema = $1 "
                                       "AND table_name = $2 AND column_name = $3", schema, table, column):
                out("refuse", why=f"{COLUMN} has no shadow column (prepare and fill first)")
                return 1
            result = await conn.fetchval(f"WITH d AS ({PURGE_BLANK[COLUMN]} RETURNING 1) SELECT count(*) FROM d")
            if result != EXPECT_BLANK:
                out("refuse", why=f"{result} blank row(s) found, EXPECT_BLANK is {EXPECT_BLANK}: nothing deleted "
                                  "(re-run the fill and read its remaining_blank_rows)")
                return 1
        elif action == "swap":
            result = await conn.fetchval("SELECT shared.embedding_swap($1, $2)", group, ALLOW_MISSING)
        else:
            result = await conn.fetchval("SELECT shared.embedding_rollback($1, $2)", group, ALLOW_MISSING)
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
