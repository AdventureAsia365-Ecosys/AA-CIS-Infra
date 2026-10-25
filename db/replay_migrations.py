"""Replays every applied migration into a scratch PostgreSQL and dumps its catalog (AA-853).

The DB Schema Dump workflow runs this on the GitHub runner, after the live dump, against a throw-away
`pgvector/pgvector` container: no AWS, no network to the RDS. The result is the catalog the migrations alone
produce; db/schema_drift.py compares it with the live dump, so an object on Dev that no migration explains
(DDL outside DB Migrate, data standards MIG-5) shows up as "unmanaged".

Input:
  --live schema.json      the live dump (db/schema_dump.py): shared.schema_versions gives WHICH files are applied
                          and in WHAT ORDER (applied_at, then version), so cross-owner dependencies replay as on
                          Dev (rl-001 before CIS 243, CIS 269 before crm-001, …); roles and extensions come from it too
  --source OWNER=DIR      one per migrations dir: cis, booking, tripplanner, crm (the owner repos' own folders,
                          full history) and roles (db/migrations/roles here)
  --admin-dsn DSN         a SUPERUSER of a FRESH scratch server (the container's postgres user): roles are cluster
                          wide, so a server that ran a replay before keeps roles the next replay would create itself
  --decisions FILE        db/schema_drift_decisions.json (its `baseline` list)

Steps:
  1. Role bootstrap, as the superuser: the RDS master `aa_cis_admin` (LOGIN CREATEROLE CREATEDB, NOT a superuser,
     member of a stand-in `rds_superuser`), and every live role that no migration creates with a literal
     `CREATE ROLE` (e.g. the TripPlanner runtime role, created by hand in 2026). A fresh database owned by the
     master, and the live extensions (vector, pg_stat_statements) created in it by the superuser, as RDS lets
     its master do.
  2. Order (plan_order, pure): every registered version mapped to its file(s), sorted by applied_at; files of an
     owner with no registry row and numbered BELOW that owner's latest registered file (CIS legacy files applied
     by hand before self-registration) are replayed right after the file before them and flagged; files ABOVE it
     are pending (not on Dev yet) and skipped; registered versions with no file are listed. Owner-decided baseline
     files (db/schema_drift_decisions.json `baseline`, under db/replay_baseline/) are inserted before their key.
  3. Each file runs the way DB Migrate ran it (run_migration.py's own code): logged in as the master, or as
     db_migrator from the X1 S22 cutover (MIGRATOR_LOGIN_FROM) on; switched to the live owner of the dir's anchor
     schema (resolve_role + run_switched, ownership post-check included); roles/ files as the master. A file that
     is one BEGIN … COMMIT block is sent whole (atomic, as DB Migrate does); a legacy file without a registry row,
     a registered file of another shape and a baseline file run like `psql -f` did before DB Migrate: one
     statement at a time, going on after an error ("partial"). A failure is recorded and the replay goes on. No
     lint (the copies are linted by the Copy Guard; historic files predate it). Failed / partial files keep the
     `schema.name` they mention, so the drift report can say "explained by the failed replay of …".
  4. The replayed catalog is dumped with db/schema_dump.collect (the same queries as the live dump).

Output: --out results.json (one row per file: key, file, login, run_as, status, error; plus the lists of
step 2) and --dump replay-schema.json. Exit 0 when the replay ran to the end (failed files included), 1 when it
could not start. Needs asyncpg (the workflow pins it); everything else is the standard library.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import datetime
import io
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration as rm  # noqa: E402
import schema_dump  # noqa: E402

OWNERS = ("roles", "cis", "booking", "tripplanner", "crm")
KEY_PREFIX = {"cis": "", "booking": "bk-", "tripplanner": "tp-", "crm": "crm-", "roles": "rl-"}
FILE_RE = re.compile(r"^([0-9]{3})_[^/]*\.sql$")
NUMBER_RE = re.compile(r"^([0-9]{3})")
MASTER = rm.MASTER_ROLE                      # aa_cis_admin
MIGRATOR = "db_migrator"
# The first registry entry applied under the db_migrator login (X1 S22: CIS 246 is the probe that passes only
# as db_migrator switched to cis_owner). Owner-dir files from there on log in as db_migrator, like DB Migrate.
MIGRATOR_LOGIN_FROM = "246"
DEFAULT_DB = "aa_cis_dev"                   # the live database name (rl-002 refuses another one); live dump wins
BASELINE = "baseline"                       # pseudo owner of the owner-decided baseline files
DB_DIR = Path(__file__).resolve().parent
SCRATCH_PASSWORD = "replay-scratch"          # throw-away container, never a real credential
APPLICATION_NAME = "db-replay"


@dataclass
class Item:
    owner: str
    file: str                 # file name inside the owner dir
    key: str                  # registry key the file is mapped to ('' for an unregistered legacy file)
    applied_at: str           # live applied_at ('' for an unregistered legacy file)
    registered: bool
    login: str = ""
    run_as: str = ""
    status: str = "pending"   # ok | partial (legacy file, some statements failed) | failed
    error: str = ""
    log_tail: list = field(default_factory=list)
    names: list = field(default_factory=list)     # schema.name the file mentions (failed / partial files only)
    schemas: list = field(default_factory=list)   # schemas it mentions (same)

    @property
    def rel(self) -> str:
        return f"{self.owner}/{self.file}"


def file_key(owner: str, name: str) -> str:
    m = FILE_RE.match(name)
    return f"{KEY_PREFIX[owner]}{m.group(1)}" if m else ""


def _owner_of(version: str) -> str:
    for owner in ("booking", "tripplanner", "crm", "roles"):
        if version.startswith(KEY_PREFIX[owner]):
            return owner
    return "cis"


def plan_order(migrations: list, sources: dict) -> dict:
    """Pure: {"items": [Item, ...] in replay order, "pending": [rel], "no_file": [version], "legacy": [rel]}.

    migrations: live shared.schema_versions rows (version, applied_at, description). sources: {owner: [file
    names]}. A registered version maps to the files named NNN_*.sql of its owner, or, for a version that is not a
    key (CIS v1.0 … v3.0), to the file its description starts with."""
    names = {o: sorted(fs) for o, fs in sources.items()}
    by_key: dict = {}
    for o, fs in names.items():
        for f in fs:
            k = file_key(o, f)
            if k:
                by_key.setdefault(k, []).append((o, f))
    rows = sorted(migrations, key=lambda m: (str(m.get("applied_at") or ""), str(m["version"])))
    items: list = []
    taken: set = set()
    no_file: list = []
    for m in rows:
        v = str(m["version"])
        files = by_key.get(v)
        if not files:
            desc = str(m.get("description") or "")
            first = desc.split()[0] if desc.split() else ""
            files = [(o, f) for o, fs in names.items() for f in fs if f == first]
        files = [x for x in files if x not in taken]
        if not files:
            no_file.append(v)
            continue
        for o, f in files:
            taken.add((o, f))
            items.append(Item(o, f, v, str(m.get("applied_at") or ""), True))
    pending, legacy = [], []
    for o, fs in names.items():
        mine = [i for i, it in enumerate(items) if it.owner == o]
        last_name = max((items[i].file for i in mine), default="")
        for f in fs:
            if (o, f) in taken:
                continue
            if not mine or f > last_name:
                pending.append(f"{o}/{f}")
                continue
            before = [i for i in mine if items[i].file < f]
            at = (max(before) + 1) if before else min(mine)
            # after the unregistered files already placed behind the same anchor (name order)
            while at < len(items) and items[at].owner == o and not items[at].registered and items[at].file < f:
                at += 1
            items.insert(at, Item(o, f, "", "", False))
            legacy.append(f"{o}/{f}")
            mine = [i for i, it in enumerate(items) if it.owner == o]
    return {"items": items, "pending": pending, "no_file": no_file, "legacy": legacy}


QUALIFIED_RE = re.compile(r'"?\b([a-z_][a-z0-9_]*)"?\s*\.\s*"?([a-z_][a-z0-9_]*)\b')


def mentioned(sql: str, known_schemas: set) -> tuple:
    """(sorted 'schema.name', sorted schemas) a file names, for the known schemas only: the drift report links an
    object missing from the replay to the failed file that would have created it."""
    names, schemas = set(), set()
    for m in QUALIFIED_RE.finditer(sql.lower()):
        if m.group(1) in known_schemas:
            names.add(f"{m.group(1)}.{m.group(2)}")
            schemas.add(m.group(1))
    for m in re.finditer(r"\bschema\s+(?:if\s+(?:not\s+)?exists\s+)?\"?([a-z_][a-z0-9_]*)", sql.lower()):
        if m.group(1) in known_schemas:
            schemas.add(m.group(1))
    return sorted(names), sorted(schemas)


def created_roles(texts: list) -> set:
    """Role names a migration creates with a literal CREATE ROLE (IF NOT EXISTS guards included)."""
    out = set()
    for t in texts:
        for m in re.finditer(r"\bCREATE\s+(?:ROLE|USER)\s+\"?([A-Za-z_][A-Za-z0-9_$]*)", t, re.IGNORECASE):
            out.add(m.group(1).lower())
    return out


def bootstrap_roles(live_roles: list, created: set) -> list:
    """Live roles to create before the replay: those no migration creates (never the master, made first)."""
    keep = []
    for r in live_roles:
        name = r["role"]
        if name == MASTER or name in created:
            continue
        keep.append(r)
    return keep


def _q(name: str) -> str:
    return rm._quote_ident(name)


def _dsn(base: str, user: str, password: str, db: str) -> str:
    m = re.match(r"^(postgres(?:ql)?://)(?:[^@/]*@)?([^/?]+)", base)
    if not m:
        raise ValueError("admin DSN must look like postgresql://user:pass@host:port/db")
    return f"{m.group(1)}{user}:{password}@{m.group(2)}/{db}"


async def _connect(dsn: str, attempts: int = 1):
    """A session; with attempts > 1 it waits (2 s apart) for a container that is still starting."""
    import asyncpg
    for attempt in range(1, attempts + 1):
        try:
            return await asyncpg.connect(dsn, timeout=30, server_settings={"application_name": APPLICATION_NAME})
        except (OSError, asyncpg.CannotConnectNowError, asyncpg.ConnectionDoesNotExistError):
            if attempt == attempts:
                raise
            await asyncio.sleep(2)


async def prepare(admin_dsn: str, live: dict, created: set, db_name: str) -> list:
    """Step 1. Returns notes (bootstrap roles, extensions that could not be created, …)."""
    notes = []
    conn = await _connect(admin_dsn, attempts=30)
    try:
        await conn.execute(f"DROP DATABASE IF EXISTS {_q(db_name)} WITH (FORCE)")
        await conn.execute("DO $$ BEGIN IF to_regrole('rds_superuser') IS NULL THEN CREATE ROLE rds_superuser NOLOGIN; "
                           "END IF; END $$")
        # RDS gives rds_superuser these with ADMIN, so the master can grant them on (rl-002: db_migrator).
        await conn.execute("GRANT pg_read_all_stats, pg_signal_backend, pg_monitor TO rds_superuser WITH ADMIN OPTION")
        await conn.execute(f"DO $$ BEGIN IF to_regrole('{MASTER}') IS NULL THEN CREATE ROLE {MASTER}; END IF; END $$")
        await conn.execute(f"ALTER ROLE {MASTER} LOGIN CREATEROLE CREATEDB NOSUPERUSER NOBYPASSRLS "
                           f"PASSWORD '{SCRATCH_PASSWORD}'")
        await conn.execute(f"GRANT rds_superuser TO {MASTER}")
        await conn.execute(f"CREATE DATABASE {_q(db_name)} OWNER {MASTER}")
    finally:
        await conn.close()
    # Roles made by hand on Dev are created BY THE MASTER, as they were: from PostgreSQL 16 a CREATEROLE role may
    # alter only roles it administers (rl-001 sets CONNECTION LIMIT on the TripPlanner role); on 15 it makes no
    # difference.
    master = await _connect(_dsn(admin_dsn, MASTER, SCRATCH_PASSWORD, db_name))
    try:
        for r in bootstrap_roles(live.get("roles", []), created):
            attrs = ["LOGIN" if r.get("login") else "NOLOGIN", "INHERIT" if r.get("inherit", True) else "NOINHERIT"]
            if r.get("createrole"):
                attrs.append("CREATEROLE")
            if r.get("createdb"):
                attrs.append("CREATEDB")
            await master.execute(f"DO $$ BEGIN IF to_regrole('{r['role']}') IS NULL THEN "
                                 f"CREATE ROLE {_q(r['role'])} {' '.join(attrs)}; END IF; END $$")
            notes.append(f"bootstrap role {r['role']} ({' '.join(attrs)}): live, created by no migration")
    finally:
        await master.close()
    db = await _connect(_dsn(admin_dsn, *_admin_user(admin_dsn), db_name))
    try:
        for e in live.get("extensions", []):
            if e["name"] == "plpgsql":
                continue
            try:
                await db.execute(f"CREATE EXTENSION IF NOT EXISTS {_q(e['name'])} SCHEMA {_q(e['schema'])}")
                notes.append(f"extension {e['name']} {e.get('version', '')}: created by the superuser in "
                             f"{e['schema']} before the replay (RDS lets its master do it)")
            except Exception as exc:        # an image without the extension: the files that need it fail, noted
                notes.append(f"extension {e['name']}: NOT created ({type(exc).__name__}: {exc})")
    finally:
        await db.close()
    return notes


def _admin_user(admin_dsn: str) -> tuple:
    m = re.match(r"^postgres(?:ql)?://([^:@/]+)(?::([^@/]*))?@", admin_dsn)
    if not m:
        raise ValueError("admin DSN must carry user:password")
    return m.group(1), m.group(2) or ""


def _is_one_block(sql: str) -> bool:
    """True for a file that is exactly one BEGIN … COMMIT block (sent whole, atomic, as DB Migrate does)."""
    return rm.transaction_parts(sql)[3] == ""


async def run_item(item: Item, sql: str, login_dsn: str) -> None:
    """Step 3 for one file, with run_migration's own role logic; fills item.status / error / run_as."""
    d = rm.parse_directives(sql)
    buf = io.StringIO()
    conn = None
    try:
        with contextlib.redirect_stdout(buf):
            import asyncpg
            conn = await asyncpg.connect(login_dsn, timeout=30, server_settings={
                **d.settings, "application_name": APPLICATION_NAME})
            plan = (rm.RolePlan(MASTER, MASTER, "baseline file, runs as the master") if item.owner == BASELINE
                    else await rm.resolve_role(conn, item.owner))
            item.login = plan.login
            if plan.error:
                raise RuntimeError(f"role: {plan.error}")
            item.run_as = plan.run_as
            if plan.switch:
                shape = rm.registration_error(sql) if d.no_transaction else rm.transaction_parts(sql)[3]
                if shape:
                    raise RuntimeError(f"role: {shape}")
                code = await rm.run_switched(conn, sql, d, plan, item.owner)
                if code:
                    raise RuntimeError(f"run_switched exit {code}")
            elif d.no_transaction:
                for s in rm.split_statements(sql):
                    await conn.execute(s.text)
            elif not item.registered or not _is_one_block(sql):
                # Applied by hand before DB Migrate (psql -f: one statement at a time, going on after an error; inside a
                # failed BEGIN block the rest errors until its COMMIT, which rolls back, as in psql).
                failed = []
                for s in rm.split_statements(sql):
                    try:
                        await conn.execute(s.text)
                    except Exception as exc:
                        failed.append(f"line {s.line}: {type(exc).__name__} {getattr(exc, 'sqlstate', '') or ''} "
                                      f"{exc}".strip())
                if failed:
                    item.status, item.error = "partial", f"{len(failed)} statement(s) failed; first: {failed[0]}"[:500]
                    return
            else:
                await conn.execute(sql)
        item.status = "ok"
    except Exception as exc:
        item.status = "failed"
        state = getattr(exc, "sqlstate", "") or ""
        item.error = f"{type(exc).__name__} {state} {exc}".strip()[:500]
    finally:
        if conn is not None:
            await conn.close()
        item.log_tail = [ln for ln in buf.getvalue().splitlines() if "ERROR" in ln][-5:]


def add_baseline(order: dict, baseline: list, texts: dict) -> list:
    """Owner decisions (db/schema_drift_decisions.json `baseline`): SQL files under db/ that recreate what a lost
    migration made (e.g. objects of a repo that no longer exists), each run as the master right BEFORE the
    registry key named in `before` ("start" = first). Pure apart from reading the files; returns problems."""
    problems = []
    items = order["items"]
    texts.setdefault(BASELINE, {})
    for b in baseline:
        rel = str(b.get("file", ""))
        path = DB_DIR / rel
        if not rel.startswith("replay_baseline/") or not path.is_file():
            problems.append(f"baseline {rel!r}: not a file under db/replay_baseline/")
            continue
        before = str(b.get("before", "start"))
        at = 0 if before == "start" else next((i for i, it in enumerate(items) if it.key == before), None)
        if at is None:
            problems.append(f"baseline {rel}: registry key {before!r} is not in the replay order")
            continue
        texts[BASELINE][rel] = path.read_text(encoding="utf-8")
        items.insert(at, Item(BASELINE, rel, f"before {before}", "", False))
    return problems


async def replay(admin_dsn: str, live: dict, sources: dict, out_dump: str | None, baseline: list = ()) -> dict:
    texts = {o: {f: (Path(p) / f).read_text(encoding="utf-8") for f in os.listdir(p) if f.endswith(".sql")}
             for o, p in sources.items()}
    created = created_roles([t for fs in texts.values() for t in fs.values()])
    order = plan_order(live.get("migrations", []), {o: list(fs) for o, fs in texts.items()})
    baseline_problems = add_baseline(order, list(baseline), texts)
    db_name = (live.get("database") or {}).get("name") or DEFAULT_DB
    notes = await prepare(admin_dsn, live, created, db_name) + baseline_problems
    admin_db = _dsn(admin_dsn, *_admin_user(admin_dsn), db_name)
    master_dsn = _dsn(admin_dsn, MASTER, SCRATCH_PASSWORD, db_name)
    migrator_dsn = _dsn(admin_dsn, MIGRATOR, SCRATCH_PASSWORD, db_name)
    known_schemas = {x["schema"] for x in live.get("schemas", [])} | {
        sc for d in rm.OWNER_DIRS.values() for sc in d.schemas}
    migrator_from = next((i for i, it in enumerate(order["items"]) if it.key == MIGRATOR_LOGIN_FROM), None)
    migrator_ready = False
    for i, item in enumerate(order["items"]):
        use_migrator = item.owner not in (rm.ROLES_DIR, BASELINE) and migrator_from is not None and i >= migrator_from
        if use_migrator and not migrator_ready:
            admin = await _connect(admin_db)
            try:
                if await admin.fetchval(f"SELECT to_regrole('{MIGRATOR}') IS NOT NULL"):
                    await admin.execute(f"ALTER ROLE {MIGRATOR} PASSWORD '{SCRATCH_PASSWORD}'")
                    migrator_ready = True
            finally:
                await admin.close()
        dsn = migrator_dsn if (use_migrator and migrator_ready) else master_dsn
        await run_item(item, texts[item.owner][item.file], dsn)
        if item.status != "ok":
            item.names, item.schemas = mentioned(texts[item.owner][item.file], known_schemas)
        print(f"REPLAY {item.status:6} {item.rel} key={item.key or '-'} login={item.login or '-'} "
              f"as={item.run_as or '-'}{' ' + item.error[:160] if item.error else ''}", flush=True)
    import asyncpg
    conn = await asyncpg.connect(admin_db, timeout=30, server_settings=schema_dump.SESSION_SETTINGS)
    try:
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            dump = await schema_dump.collect(conn)
    finally:
        await conn.close()
    if out_dump:
        Path(out_dump).write_text(json.dumps(dump, default=str, indent=1, sort_keys=True), encoding="utf-8")
    items = order["items"]
    return {
        "format": 1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
        "live_generated_at": live.get("generated_at"),
        "server_version": (dump.get("database") or {}).get("server_version") if dump else None,
        "database": db_name,
        "counts": {"files": len(items), "ok": sum(it.status == "ok" for it in items),
                   "partial": sum(it.status == "partial" for it in items),
                   "failed": sum(it.status == "failed" for it in items), "legacy": len(order["legacy"]),
                   "pending": len(order["pending"]), "no_file": len(order["no_file"])},
        "items": [{**{k: v for k, v in asdict(it).items()}, "rel": it.rel} for it in items],
        "pending": order["pending"], "no_file": order["no_file"], "legacy": order["legacy"], "notes": notes,
    }


def parse_sources(values: list) -> dict:
    out = {}
    for v in values:
        owner, _, path = v.partition("=")
        if owner not in OWNERS or not path or not Path(path).is_dir():
            raise SystemExit(f"--source {v!r}: expected OWNER=DIR with OWNER in {', '.join(OWNERS)} and an "
                             f"existing DIR")
        out[owner] = path
    return out


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--live", required=True, help="live dump JSON (db/schema_dump.py)")
    parser.add_argument("--source", action="append", default=[], help="OWNER=DIR, once per migrations dir")
    parser.add_argument("--admin-dsn", default=os.environ.get("REPLAY_ADMIN_DSN"),
                        help="superuser DSN of the scratch server (or REPLAY_ADMIN_DSN)")
    parser.add_argument("--out", required=True, help="results JSON")
    parser.add_argument("--dump", required=True, help="catalog dump JSON of the replayed database")
    parser.add_argument("--decisions", default=str(DB_DIR / "schema_drift_decisions.json"),
                        help="owner decisions; its `baseline` list adds files to the replay")
    args = parser.parse_args(argv)
    if not args.admin_dsn:
        print("--admin-dsn (or REPLAY_ADMIN_DSN) is required", file=sys.stderr)
        return 1
    live = json.loads(Path(args.live).read_text(encoding="utf-8"))
    baseline = []
    if args.decisions and Path(args.decisions).is_file():
        baseline = json.loads(Path(args.decisions).read_text(encoding="utf-8")).get("baseline", [])
    result = asyncio.run(replay(args.admin_dsn, live, parse_sources(args.source), args.dump, baseline))
    Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True, default=str), encoding="utf-8")
    c = result["counts"]
    print(f"REPLAY done files={c['files']} ok={c['ok']} partial={c['partial']} failed={c['failed']} "
          f"legacy={c['legacy']} "
          f"pending={c['pending']} registered_without_file={c['no_file']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
