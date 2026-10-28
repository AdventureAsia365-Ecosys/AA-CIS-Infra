"""Classifies pending migration files as expand or contract from catalog evidence (AA-993 M2b, root ADR 0017 d3).

  python3 db/expand_check.py --classify --live schema.json --admin-dsn postgresql://postgres:…@127.0.0.1:55432/postgres \
      --source roles=db/migrations/roles --source cis=owners/AA-CIS-App/api/migrations … \
      [--files cis/300_x.sql booking/034_y.sql] --out classify.json [--summary "$GITHUB_STEP_SUMMARY"]

The runtime post-check itself (expand_snapshot / expand_findings, exit 14) lives in db/run_migration.py, because DB
Migrate ships that one file to the task. This tool runs the same code on a throw-away PostgreSQL 15:

1. Replay (db/replay_migrations.py): every migration applied on Dev, in the order of the latest DB Schema Dump artifact
   (`--live`, its shared.schema_versions rows; critic 19). Without an artifact, `--files` must name the targets and the
   order falls back to number order (roles, cis, booking, tripplanner, crm; each owner's files below its lowest target
   count as applied). The fallback has no live roles or extensions beyond `vector`, so files that need a hand-made
   role fail in the replay; the result says `order: number`.
2. Every pending file (registered nowhere in the live order), owner by owner in number order: its lint (`run_migration.
   lint`), then a rehearsal under the same role logic as DB Migrate (role switch, ownership post-check) with the expand
   post-check, rolled back; then the file is applied for real (run_item, as the replay does), so the next file sees it.
   A file without the header is rehearsed as if it had one: `eligible` says whether the catalog evidence would let it
   ship as expand. A CREATE INDEX CONCURRENTLY file cannot be rehearsed in a transaction: it is applied with the
   post-check before its registration.
3. One `CLASSIFY <class> <file>` line per file, JSON to `--out`, Markdown to `--summary`.

Class: `expand` = the header, no lint error, no finding, no SQL error; anything else `contract`. Exit 14 when a target
file (`--files`, default every pending file) with the expand header has a finding or a lint error, 1 when such a file
fails with a SQL error or the replay cannot start, 0 otherwise. A file without the header never fails the run: it is
a contract file by definition (manual DB Migrate apply), the evidence only labels it.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import copy
import io
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import replay_migrations as rp  # noqa: E402
import run_migration as rm  # noqa: E402

ORDER = ("roles", "cis", "booking", "tripplanner", "crm")
NUMBER_ORDER_EXTENSIONS = [{"name": "vector", "schema": "public"}]


def number_order_live(files: dict, targets: list) -> dict:
    """Pure: a stand-in for the live dump when no DB Schema Dump artifact exists. files: {owner: [file names]};
    targets: ["owner/file"]. Each owner's files below its lowest target are 'applied' in number order, owners in
    ORDER; everything from the lowest target up stays pending."""
    lowest: dict = {}
    for t in targets:
        owner, _, name = t.partition("/")
        lowest[owner] = min(lowest.get(owner, name), name)
    migrations, n = [], 0
    for owner in ORDER:
        for name in sorted(files.get(owner, [])):
            if owner in lowest and name >= lowest[owner]:
                break
            key = rp.file_key(owner, name)
            if key:
                n += 1
                migrations.append({"version": key, "applied_at": f"number-order-{n:06d}",
                                   "description": f"{name} (number order, no dump artifact)"})
    return {"migrations": migrations, "roles": [], "extensions": NUMBER_ORDER_EXTENSIONS, "schemas": []}


def pending_order(pending: list) -> list:
    """Pure: the replay's pending "owner/file" list, owner by owner (ORDER), each in number (file name) order."""
    rank = {o: i for i, o in enumerate(ORDER)}
    return sorted(pending, key=lambda rel: (rank.get(rel.split("/", 1)[0], len(ORDER)), rel.split("/", 1)[1]))


def verdict(entry: dict) -> str:
    """Pure: class of one classified file (see the module docstring)."""
    if entry["header"] == "expand" and not entry["lint_errors"] and not entry["findings"] and not entry["error"]:
        return "expand"
    return "contract"


def exit_code(entries: list, targets: set | None) -> int:
    """Pure: 14 when a target with the expand header has a finding or a lint error, 1 when one failed with a SQL
    error, else 0 (a target that is not pending is only noted by main())."""
    code = 0
    for e in entries:
        if targets is not None and e["file"] not in targets:
            continue
        if e["header"] != "expand":
            continue
        if e["lint_errors"] or e["findings"]:
            return 14
        if e["error"]:
            code = 1
    return code


async def _ensure_migrator(admin_dsn: str, db_name: str) -> bool:
    import asyncpg
    admin = await asyncpg.connect(rp._dsn(admin_dsn, *rp._admin_user(admin_dsn), db_name), timeout=30)
    try:
        if await admin.fetchval(f"SELECT to_regrole('{rp.MIGRATOR}') IS NOT NULL"):
            await admin.execute(f"ALTER ROLE {rp.MIGRATOR} PASSWORD '{rp.SCRATCH_PASSWORD}'")
            return True
        return False
    finally:
        await admin.close()


async def classify_one(rel: str, sql: str, login_dsn: str) -> dict:
    """Lint + rehearsal (expand post-check, rolled back) of one pending file, then the file applied for real."""
    import asyncpg
    owner, _, name = rel.partition("/")
    d = rm.parse_directives(sql)
    entry = {"file": rel, "header": "expand" if d.expand else "none", "no_transaction": d.no_transaction,
             "lint_errors": [], "findings": [], "error": "", "eligible": None, "applied": "", "log": []}
    if owner != rm.ROLES_DIR:
        entry["lint_errors"] = rm.lint(sql, d, rel)[0]
    buf = io.StringIO()
    if owner != rm.ROLES_DIR and (d.no_transaction or not rm.transaction_parts(sql)[3]):
        dx = copy.copy(d)
        dx.expand = True                    # header-less files: the evidence for the label
        conn = None
        try:
            conn = await asyncpg.connect(login_dsn, timeout=30,
                                         server_settings={**d.settings, "application_name": rp.APPLICATION_NAME})
            with contextlib.redirect_stdout(buf):
                plan = await rm.resolve_role(conn, owner)
                if plan.error:
                    entry["error"] = f"role: {plan.error}"
                elif d.no_transaction:
                    if d.expand:            # CIC: no transaction to roll back; applied here with its post-check
                        code = await rm.execute_file(conn, sql, d, plan, owner, report=entry["findings"])
                        entry["applied"] = "here" if code in (0, 14) else ""
                        if code not in (0, 14):
                            entry["error"] = f"exit {code}"
                    # a header-less no-transaction file: no rehearsal possible, eligible stays None
                else:
                    code = await rm.execute_file(conn, sql, dx, plan, owner, rehearse=True, report=entry["findings"])
                    if code not in (0, 14):
                        entry["error"] = f"rehearsal exit {code}"
                    entry["eligible"] = code == 0 and not entry["findings"]
                    if not d.expand and entry["findings"]:
                        entry["log"].append("not expand-eligible: " + "; ".join(entry["findings"][:5]))
        except Exception as exc:            # review S256: one file's failure is its own error, never a crash of the
            # whole run (the required check would then block unrelated copy PRs); exit_code() still fails a target
            entry["error"] = entry["error"] or f"{type(exc).__name__}: {str(exc)[:200]}"
        finally:
            if conn is not None:
                with contextlib.suppress(Exception):
                    if conn.is_in_transaction():
                        await conn.execute("ROLLBACK")
                with contextlib.suppress(Exception):
                    await conn.close()
    elif owner != rm.ROLES_DIR:
        entry["eligible"] = False
        entry["log"].append(f"shape: {rm.transaction_parts(sql)[3]}")
    if not entry["applied"]:
        item = rp.Item(owner, name, rp.file_key(owner, name), "", True)
        await rp.run_item(item, sql, login_dsn)
        entry["applied"] = item.status if item.status == "ok" else f"{item.status}: {item.error[:200]}"
    entry["log"] += [ln for ln in buf.getvalue().splitlines() if "ERROR" in ln][-5:]
    if not d.expand:
        entry["findings_if_expand"], entry["findings"] = entry["findings"], []
    entry["class"] = verdict(entry)
    return entry


async def classify(admin_dsn: str, live: dict | None, sources: dict, targets: list | None,
                   decisions: dict | None = None) -> dict:
    texts = {o: sorted(f for f in os.listdir(p) if f.endswith(".sql")) for o, p in sources.items()}
    order = "dump"
    if live is None:
        if not targets:
            raise SystemExit("no --live dump artifact: --files must name the files to classify (number-order fallback)")
        live, order = number_order_live(texts, targets), "number"
    decisions = decisions or {}
    result = await rp.replay(admin_dsn, live, sources, None, decisions.get("baseline", []),
                             decisions.get("replay_order", []), collect_dump=False)
    db_name = result["database"]
    master_dsn = rp._dsn(admin_dsn, rp.MASTER, rp.SCRATCH_PASSWORD, db_name)
    migrator_dsn = rp._dsn(admin_dsn, rp.MIGRATOR, rp.SCRATCH_PASSWORD, db_name)
    # Like the replay (and DB Migrate since X1 S22): db_migrator logs in once the order has passed CIS 246.
    migrator = any(it["key"] == rp.MIGRATOR_LOGIN_FROM for it in result["items"]) \
        and await _ensure_migrator(admin_dsn, db_name)
    entries = []
    for rel in pending_order(result["pending"]):
        owner, _, name = rel.partition("/")
        sql = (Path(sources[owner]) / name).read_text(encoding="utf-8")
        dsn = master_dsn if owner == rm.ROLES_DIR or not migrator else migrator_dsn
        e = await classify_one(rel, sql, dsn)
        entries.append(e)
        extra = [f"findings={len(e['findings'])}" if e["findings"] else "",
                 f"lint={len(e['lint_errors'])}" if e["lint_errors"] else "",
                 f"error={e['error']}" if e["error"] else "",
                 f"eligible={str(e['eligible']).lower()}" if e["header"] != "expand" and e["eligible"] is not None
                 else ""]
        print(" ".join([f"CLASSIFY {e['class']:8} {rel} header={e['header']}"] + [x for x in extra if x]), flush=True)
        for f in e["findings"] + e["lint_errors"]:
            print(f"  - {f}", flush=True)
    pending = {e["file"] for e in entries}
    missing = [t for t in (targets or []) if t not in pending]
    return {"format": 1, "order": order, "live_generated_at": live.get("generated_at"),
            "replay": result["counts"], "files": entries,
            "targets_not_pending": missing}


def summary_lines(out: dict, targets: list | None) -> list:
    lines = [f"### Expand classify (AA-993 M2b, order: {out['order']})", "",
             "| File | Header | Class | Findings / lint |", "|---|---|---|---|"]
    for e in out["files"]:
        if targets and e["file"] not in targets:
            continue
        notes = "; ".join((e["findings"] + e["lint_errors"])[:3]) or (e["error"] or "")
        if e["header"] != "expand" and e.get("eligible") is not None:
            notes = notes or ("expand-eligible by the catalog evidence" if e["eligible"] else
                              "; ".join(e.get("findings_if_expand", [])[:3]) or "not expand-eligible")
        lines.append(f"| `{e['file']}` | {e['header']} | {e['class']} | {notes.replace('|', '/')[:300]} |")
    for t in out["targets_not_pending"]:
        lines.append(f"| `{t}` | | not pending | already applied on Dev or not in the sources: not classified |")
    c = out["replay"]
    lines += ["", f"Replay: {c['ok']}/{c['files']} files ok, {c['failed']} failed, {c['partial']} partial."]
    return lines


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--classify", action="store_true", required=True, help="classify the pending files")
    parser.add_argument("--live", help="live dump JSON (the DB Schema Dump artifact's schema.json); omit for number "
                                       "order")
    parser.add_argument("--source", action="append", default=[], help="OWNER=DIR, once per migrations dir")
    parser.add_argument("--admin-dsn", default=os.environ.get("REPLAY_ADMIN_DSN"),
                        help="superuser DSN of a fresh scratch PostgreSQL 15 (or REPLAY_ADMIN_DSN)")
    parser.add_argument("--files", nargs="*", default=None, help="owner/NNN_x.sql files whose verdict sets the exit")
    parser.add_argument("--out", required=True, help="results JSON")
    parser.add_argument("--summary", help="append a Markdown table to this file (GITHUB_STEP_SUMMARY)")
    parser.add_argument("--decisions", default=str(rp.DB_DIR / "schema_drift_decisions.json"))
    args = parser.parse_args(argv)
    if not args.admin_dsn:
        print("--admin-dsn (or REPLAY_ADMIN_DSN) is required", file=sys.stderr)
        return 1
    live = json.loads(Path(args.live).read_text(encoding="utf-8")) if args.live else None
    decisions = json.loads(Path(args.decisions).read_text(encoding="utf-8")) if Path(args.decisions).is_file() else {}
    targets = args.files or None
    try:
        out = asyncio.run(classify(args.admin_dsn, live, rp.parse_sources(args.source), targets, decisions))
    except rp.ReplayServerError as exc:
        print(f"CLASSIFY refused: {exc}", file=sys.stderr, flush=True)
        return 1
    Path(args.out).write_text(json.dumps(out, indent=1, sort_keys=True, default=str), encoding="utf-8")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary_lines(out, targets)) + "\n")
    code = exit_code(out["files"], set(targets) if targets else None)
    if targets and out["targets_not_pending"]:
        print(f"CLASSIFY note: not pending (already applied on Dev, or not in the sources): "
              f"{', '.join(out['targets_not_pending'])}", flush=True)
    print(f"CLASSIFY done files={len(out['files'])} order={out['order']} exit={code}", flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
