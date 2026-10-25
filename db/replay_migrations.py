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
  --decisions FILE        db/schema_drift_decisions.json (its `baseline` and `replay_order` lists)

Steps:
  1. Role bootstrap, as the superuser: the RDS master `aa_cis_admin` (LOGIN CREATEROLE CREATEDB, NOT a superuser,
     member of a stand-in `rds_superuser`, BYPASSRLS for what rds_superuser gives it on RDS: FORCE RLS tables read
     unfiltered, which 239 / 244 check), and every live role that no migration creates (roles_created_by: a
     `CREATE ROLE` in code, comments left out; today only the TripPlanner runtime role, created by hand in
     2026). A fresh database owned by the master, and the live extensions (vector, pg_stat_statements)
     created in it by the superuser, as RDS lets its master do. A server that is not PostgreSQL 15 is
     refused (exit 1, see below).
  2. Order (plan_order, pure): every registered version mapped to its file(s), sorted by applied_at; files of an
     owner with no registry row and numbered BELOW that owner's latest registered file (CIS legacy files applied
     by hand before self-registration) are replayed right after the file before them and flagged; files ABOVE it
     are pending (not on Dev yet) and skipped; registered versions with no file are listed. Back-registered rows
     (description `backfill: …`, e.g. tp-007 wrote tp-001…tp-006 with applied_at = now()) carry the registration
     time, not when the file ran: they are listed (`backfilled`), and owner decisions in
     db/schema_drift_decisions.json `replay_order` move them before the registry key the evidence proves (S251).
     Owner-decided baseline files (`baseline`, under db/replay_baseline/, db/gen_replay_baseline.py: the lost AA-ACP-App
     lineage and recorded hand DDL) are inserted before their key or file; `replay_order` `files` move unregistered
     legacy files the same way.
  3. Each file runs the way DB Migrate ran it (run_migration.py's own code): logged in as the master, or as
     db_migrator from the X1 S22 cutover (MIGRATOR_LOGIN_FROM) on; switched to the live owner of the dir's anchor
     schema (resolve_role + run_switched, ownership post-check included); roles/ files as the master. A file that
     is one BEGIN … COMMIT block is sent whole (atomic, as DB Migrate does); a legacy file without a registry row,
     a registered file of another shape run like `psql -f` did before DB Migrate: one statement at a time, going on
     after an error ("partial"). A baseline file is sent whole, after `SET aa_replay.baseline = 'on'`, the one
     setting its guard accepts (baseline_statements). A failure is recorded and the replay goes on. No
     lint (the copies are linted by the Copy Guard; historic files predate it). Failed / partial files keep the
     `schema.name` they mention and what their DDL changes (ddl_targets), so the drift report can say "explained
     by the failed replay of …" only when that file's DDL would have made the difference.
     Gap fills (S251), so one replay gap does not take every later file down with it, each written to `notes`:
     a. role gap: before each file, every live role whose creating file (role_creators: literal CREATE ROLE, or
        format('CREATE ROLE %I') over live names) comes earlier but failed is created by the master with its live
        attributes (never a password: the scratch server's own auth). Only the role: that file's grants stay a gap.
     b. owner gap: when a dir's X1 ownership-transfer file (transfer_files: CIS 245, bk-014, tp-013) fails, the
        replay does what it does to ownership, as the master (ownership_statements, pure): every schema of the
        dir to the anchor schema's live owner (245 moves all 12 CIS schemas to cis_owner; a later owner change
        on Dev then shows as drift, it is not copied), and every object the master owns in them, extension
        members left out, to that owner: relations and composite types, enum / domain / range types, routines,
        statistics, collations, conversions, text search dictionaries and configurations, the kinds 245 moves.
        Schemas in TRANSFER_SKIP_OBJECTS keep their objects' owners (CIS: catalog, 245 item 4: its views stay
        catalog_owner's, only the schema moves). Its grants, default privileges and checks stay a gap.
     The replay targets PostgreSQL 15 (RDS 15.17, the workflow image). On 16 the CREATEROLE rules changed (a role's
     creator gets ADMIN on it and "is a member"), so rl-001 / rl-002 refuse and the owner fill cannot SET ROLE:
     a run on 16 is not comparable (S251: 64 files differ). prepare() reads server_version_num and refuses any
     other major version (check_server_version), so an image bump cannot change the counts silently.
  4. The replayed catalog is dumped with db/schema_dump.collect (the same queries as the live dump).

Output: --out results.json (one row per file: key, file, login, run_as, status, error, roles_filled,
ownership_filled, moved_before, ddl; plus the lists of step 2, `notes` and `gap_roots`: the objects failed files
needed, root = no file in any repo creates them before the first file that needs them) and --dump
replay-schema.json. Exit 0 when the replay ran to the end (failed files included), 1 when it
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
# The guard every db/replay_baseline/ file begins with (db/gen_replay_baseline.py) raises unless this session setting
# is 'on' and application_name is APPLICATION_NAME: run_item sets it for baseline files only, so a baseline file
# applied anywhere else (or as a migration of the replay) does nothing but fail.
BASELINE_SETTING = "aa_replay.baseline"
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
    roles_filled: list = field(default_factory=list)  # live roles created just before this file (role gap)
    ownership_filled: list = field(default_factory=list)  # ALTER … OWNER TO run after this failed transfer file
    moved_before: str = ""    # registry key a `replay_order` decision placed this file before ('' = registry order)
    names: list = field(default_factory=list)     # schema.name the file mentions (failed / partial files only)
    schemas: list = field(default_factory=list)   # schemas it mentions (same)
    ddl: dict = field(default_factory=dict)       # what the file changes with DDL (same; ddl_targets)

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


_ID = r'"?([a-z_][a-z0-9_$]*)"?'
_QUAL = _ID + r"\s*\.\s*" + _ID
DDL_RES = (
    # CREATE / ALTER / DROP of the object itself
    re.compile(r"\b(?:create(?:\s+or\s+replace)?(?:\s+(?:unlogged|temporary|temp))?|alter|drop)\s+"
               r"(?:table|view|materialized\s+view|sequence|type|function|procedure|domain|foreign\s+table)\s+"
               r"(?:if\s+(?:not\s+)?exists\s+)?(?:only\s+)?" + _QUAL),
    # indexes, policies and triggers name their table after ON
    re.compile(r"\bcreate\s+(?:unique\s+)?index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?"
               r"(?:\"?[a-z0-9_$]+\"?\s+)?on\s+(?:only\s+)?" + _QUAL),
    re.compile(r"\b(?:create|alter|drop)\s+policy\s+(?:if\s+exists\s+)?\"?[a-z0-9_$]+\"?\s+on\s+" + _QUAL),
    re.compile(r"\b(?:create(?:\s+or\s+replace)?(?:\s+constraint)?|drop)\s+trigger\s+(?:if\s+exists\s+)?"
               r"\"?[a-z0-9_$]+\"?\s+[^;]*?\bon\s+" + _QUAL),
    re.compile(r"\b(?:enable|disable|force|no\s+force)\s+row\s+level\s+security\b[^;]*?\bon\s+" + _QUAL),
)
RENAME_RE = re.compile(r"\balter\s+(?:table|view|materialized\s+view|sequence|type)\s+(?:if\s+exists\s+)?" + _QUAL +
                       r"\s+rename\s+to\s+" + _ID)
CREATE_RE = re.compile(r"\bcreate(?:\s+or\s+replace)?(?:\s+(?:unlogged|temporary|temp))?\s+"
                       r"(?:table|view|materialized\s+view|sequence|type|function|procedure|domain)\s+"
                       r"(?:if\s+not\s+exists\s+)?" + _QUAL)
RECREATE_RE = re.compile(r"\b(?:create(?:\s+or\s+replace)?\s+(?:materialized\s+)?view"
                         r"|drop\s+(?:materialized\s+view|view|table))\s+(?:if\s+(?:not\s+)?exists\s+)?" + _QUAL)
DDL_SCHEMA_RE = re.compile(r"\b(?:create|alter|drop)\s+schema\s+(?:if\s+(?:not\s+)?exists\s+)?" + _ID)


WORD_RE = re.compile(r"[a-z_][a-z0-9_$]*")
# Column DDL on a table: `create table x (…)` defines every column it names; `alter table x <action>, <action>`
# adds / alters / drops / renames the column each action names. Anything else on the table (an index, a trigger
# `update of country`, a constraint) does not change a column's type, nullability or default.
CREATE_TABLE_RE = re.compile(r"\bcreate(?:\s+(?:unlogged|temporary|temp))?\s+table\s+(?:if\s+not\s+exists\s+)?"
                             + _QUAL)
ALTER_TABLE_RE = re.compile(r"\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?" + _QUAL + r"\s+(.*)", re.DOTALL)
COLUMN_ACTION_RE = re.compile(r"^\s*(?:add|alter|drop|rename)\s+(?:column\s+)?(?:if\s+(?:not\s+)?exists\s+)?" + _ID
                              + r"(?:\s+to\s+" + _ID + r")?")
NOT_A_COLUMN = frozenset({"constraint", "primary", "foreign", "unique", "check", "exclude", "to", "column"})


def _split_actions(rest: str) -> list:
    """The comma-separated actions of an ALTER TABLE, commas inside parentheses kept."""
    out, depth, cur = [], 0, []
    for ch in rest:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    out.append("".join(cur))
    return out


def column_targets(stmt: str, known_schemas: set) -> dict:
    """Pure: {'schema.table': column names whose definition one (lower-case) statement sets}. CREATE TABLE: every
    word of the statement (its column list); ALTER TABLE: the column of each add / alter / drop / rename action
    (`rename a to b` gives both)."""
    out: dict = {}
    for m in CREATE_TABLE_RE.finditer(stmt):
        if m.group(1) in known_schemas:
            out.setdefault(f"{m.group(1)}.{m.group(2)}", set()).update(WORD_RE.findall(stmt))
    for m in ALTER_TABLE_RE.finditer(stmt):
        if m.group(1) not in known_schemas:
            continue
        cols = out.setdefault(f"{m.group(1)}.{m.group(2)}", set())
        for action in _split_actions(m.group(3)):
            a = COLUMN_ACTION_RE.match(action)
            if a and a.group(1) not in NOT_A_COLUMN:
                cols.add(a.group(1))
                if a.group(2):
                    cols.add(a.group(2))
    return out


DYNAMIC_KIND_RES = (           # what DDL a format()-built string does, by the drift finding kind it can explain
    ("policy", re.compile(r"\b(?:create|alter|drop)\s+policy\b[^;]*%")),
    ("index", re.compile(r"\b(?:create\s+(?:unique\s+)?index|drop\s+index)\b[^;]*%")),
    ("trigger", re.compile(r"\b(?:create(?:\s+or\s+replace)?|drop)\s+trigger\b[^;]*%")),
    ("column", re.compile(r"\balter\s+table\b[^;]*%[^;]*\b(?:(?:add|drop|alter)\s+column|type)\b")),
    ("constraint", re.compile(r"\balter\s+table\b[^;]*%[^;]*\b(?:add|drop)\s+constraint\b")),
    ("relation", re.compile(r"\b(?:create(?:\s+or\s+replace)?|drop)\s+(?:table|view|materialized\s+view)\b[^;]*%")),
    ("function", re.compile(r"\b(?:create(?:\s+or\s+replace)?|drop)\s+function\b[^;]*%")),
)


def ddl_targets(sql: str, known_schemas: set) -> dict:
    """What a file changes with DDL, for the drift report to tell "this failed file would have made that difference"
    from "this failed file only names the object" (a SELECT, a GRANT, a check). Comments are left out; string
    literals (dynamic SQL) are read as statements of their own. Keys (all sorted):
      names      'schema.name' it creates / alters / drops (relation, routine, type), puts an index / policy / trigger /
                 ROW LEVEL SECURITY on, or RENAMEs to
      schemas    schemas it creates / alters / drops, or changes an object in
      words      {'schema.name': identifiers of the statements that target it} (column, index, constraint, policy,
                 trigger names), so "adds an index to raw_tours" does not explain a raw_tours column type
      recreated  views it creates or replaces and views / tables it drops (every column of theirs is its doing)
      columns    {'schema.table': column names it defines / adds / alters / drops / renames} (column_targets): a
                 column finding is this file's doing only when its column is here (S251: CIS 279's trigger
                 `update of country` on raw_tours named `country` but does not change its type)
      created    schemas and 'schema.name' it CREATEs (or RENAMEs to): gap_roots tells a lost object from a cascade
      dynamic    for a file that builds DDL with format('CREATE POLICY %I ON %I.%I …'): the kinds of DDL its strings do,
                 the objects it names and its words (a broader claim, kind-bound in the report); {} otherwise"""
    strings: list = []
    text = (rm._role_view(sql, strings) + " ; " + " ; ".join(strings)).lower()
    names, schemas, recreated, created = set(), set(), set(), set()
    detail: dict = {}
    columns: dict = {}
    for stmt in text.split(";"):
        for rel, cols in column_targets(stmt, known_schemas).items():
            columns.setdefault(rel, set()).update(cols)
        hit = set()
        for m in CREATE_RE.finditer(stmt):
            if m.group(1) in known_schemas:
                created.add(f"{m.group(1)}.{m.group(2)}")
        for m in re.finditer(r"\bcreate\s+schema\s+(?:if\s+not\s+exists\s+)?" + _ID, stmt):
            if m.group(1) in known_schemas:
                created.add(m.group(1))
        for rx in DDL_RES:
            for m in rx.finditer(stmt):
                if m.group(1) in known_schemas:
                    hit.add(f"{m.group(1)}.{m.group(2)}")
        for m in RENAME_RE.finditer(stmt):
            if m.group(1) in known_schemas:
                hit.add(f"{m.group(1)}.{m.group(3)}")
                created.add(f"{m.group(1)}.{m.group(3)}")
        for m in RECREATE_RE.finditer(stmt):
            if m.group(1) in known_schemas:
                recreated.add(f"{m.group(1)}.{m.group(2)}")
        for m in DDL_SCHEMA_RE.finditer(stmt):
            if m.group(1) in known_schemas:
                schemas.add(m.group(1))
        if not hit:
            continue
        words = set(WORD_RE.findall(stmt))
        for n in hit:
            names.add(n)
            schemas.add(n.split(".", 1)[0])
            detail.setdefault(n, set()).update(words)
    kinds = sorted({k for k, rx in DYNAMIC_KIND_RES for x in strings if rx.search(x.lower())})
    dynamic: dict = {}
    if kinds:
        dyn_names, _ = mentioned(sql, known_schemas)
        dynamic = {"kinds": kinds, "names": dyn_names, "words": sorted(set(WORD_RE.findall(text)))}
    return {"names": sorted(names), "schemas": sorted(schemas), "recreated": sorted(recreated),
            "created": sorted(created), "words": {k: sorted(v) for k, v in sorted(detail.items())},
            "columns": {k: sorted(v) for k, v in sorted(columns.items())}, "dynamic": dynamic}


CREATE_ROLE_RE = re.compile(r"\bCREATE\s+(?:ROLE|USER)\s+\"?([A-Z_][A-Z0-9_$]*)")
DYNAMIC_CREATE_ROLE_RE = re.compile(r"\bCREATE\s+(?:ROLE|USER)\s+%(?:[0-9]+\$)?[IsL]", re.IGNORECASE)
# In run_migration's role view a string literal reads '#<n>' (its text is strings[n]).
_LIT = r"'#(\d+)'"
FORMAT_LITERAL_ARGS_RE = re.compile(r"\bFORMAT\s*\(\s*" + _LIT + r"((?:\s*,\s*" + _LIT + r")+)\s*\)")
FOREACH_ARRAY_RE = re.compile(r"\bFOREACH\s+([A-Z_][A-Z0-9_$]*)\s+IN\s+ARRAY\s+ARRAY\s*\[([^\]]*)\]\s*LOOP\b(.*?)"
                              r"\bEND\s+LOOP\b", re.DOTALL)


def _dynamic_role_names(code: str, strings: list) -> set:
    """The role names a `format('CREATE ROLE %I', …)` really creates, and only those: the literal arguments of that
    format() call, or the literals of the ARRAY[…] a FOREACH loop iterates when the loop body passes the loop
    variable to it (rl-004). Other literals of the file (a GRANT target, a check message) do not count."""
    def creates(n: str) -> bool:
        return bool(DYNAMIC_CREATE_ROLE_RE.search(strings[int(n)]))
    out: set = set()
    for m in FORMAT_LITERAL_ARGS_RE.finditer(code):
        if creates(m.group(1)):
            out |= {strings[int(n)] for n in re.findall(_LIT, m.group(2))}
    for m in FOREACH_ARRAY_RE.finditer(code):
        var, items, body = m.group(1), m.group(2), m.group(3)
        call = re.compile(r"\bFORMAT\s*\(\s*" + _LIT + r"\s*,\s*" + re.escape(var) + r"\s*\)")
        if any(creates(c.group(1)) for c in call.finditer(body)):
            out |= {strings[int(n)] for n in re.findall(_LIT, items)}
    return out


def roles_created_by(sql: str, live_names: frozenset = frozenset()) -> set:
    """Role names one file creates: a literal `CREATE ROLE x` in its code (comments left out, DO bodies read, IF NOT
    EXISTS guards included), and the live roles a `format('CREATE ROLE %I', …)` builds (_dynamic_role_names; rl-004:
    `FOREACH r IN ARRAY ARRAY['crm_ai_reader', …] LOOP … format('CREATE ROLE %I NOLOGIN', r)`). Read through
    run_migration's role lint view, so a `CREATE ROLE` inside a comment does not count."""
    strings: list = []
    code = rm._role_view(sql, strings)
    out = {m.group(1).lower() for m in CREATE_ROLE_RE.finditer(code) if not m.group(1).startswith("%")}
    if any(DYNAMIC_CREATE_ROLE_RE.search(s) for s in strings):
        out |= {s for s in _dynamic_role_names(code, strings) if s in live_names}
    return out


def created_roles(texts: list, live_names: frozenset = frozenset()) -> set:
    """Role names any of the files creates (roles_created_by)."""
    out: set = set()
    for t in texts:
        out |= roles_created_by(t, live_names)
    return out


def role_creators(items: list, texts: dict, live_names: frozenset) -> dict:
    """Pure: {live role: index in `items` of the FIRST file that creates it}. On Dev the role exists from that file
    on; when that file fails in the replay (a replay gap upstream of it), fill_roles() creates the role before the
    next file, so one lost file does not take every later role-dependent file down with it."""
    out: dict = {}
    for i, it in enumerate(items):
        for r in roles_created_by(texts[it.owner][it.file], live_names):
            if r in live_names and r != MASTER:
                out.setdefault(r, i)
    return out


def roles_to_fill(index: int, creators: dict, existing: set) -> list:
    """Pure: the live roles a file at `index` may rely on (their creating file comes earlier) that the replay does not
    have (that file failed or ran partly). Sorted, for a stable log."""
    return sorted(r for r, at in creators.items() if at < index and r not in existing)


def role_attributes(r: dict) -> str:
    """CREATE ROLE options from a live dump row: login, inherit, createrole, createdb, connection limit. Never a
    password (a LOGIN role of the replay logs in through the scratch server's trust or a throw-away password), never
    SUPERUSER / BYPASSRLS (no live role of the dump has them; the dump states it)."""
    attrs = ["LOGIN" if r.get("login") else "NOLOGIN", "INHERIT" if r.get("inherit", True) else "NOINHERIT"]
    if r.get("createrole"):
        attrs.append("CREATEROLE")
    if r.get("createdb"):
        attrs.append("CREATEDB")
    limit = r.get("connection_limit")
    if isinstance(limit, int) and limit >= 0:
        attrs.append(f"CONNECTION LIMIT {limit}")
    return " ".join(attrs)


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


REPLAY_MAJOR = 15        # RDS aa-cis-dev-db and the workflow's pgvector image


class ReplayServerError(RuntimeError):
    """The scratch server cannot give a comparable replay (main() exits 1)."""


def check_server_version(version_num: int, major: int = REPLAY_MAJOR) -> str | None:
    """Pure: None when server_version_num is of the replay's major version, else why the replay refuses to run.
    PostgreSQL 16 changed CREATEROLE (the creator gets ADMIN on the role and is a member of it): rl-001 / rl-002
    refuse there and the owner fill cannot SET ROLE, so a 16 replay differs on 64 files (S251) and its counts would
    change silently with an image bump."""
    if version_num // 10000 == major:
        return None
    return (f"the scratch server is PostgreSQL {version_num // 10000} (server_version_num {version_num}); the replay "
            f"needs PostgreSQL {major}, like RDS: role and ownership rules differ between majors, so the drift "
            f"counts would not be comparable")


async def prepare(admin_dsn: str, live: dict, created: set, db_name: str) -> list:
    """Step 1. Returns notes (server version, bootstrap roles, extensions that could not be created, …). Raises
    ReplayServerError on a server that is not PostgreSQL REPLAY_MAJOR (check_server_version)."""
    notes = []
    conn = await _connect(admin_dsn, attempts=30)
    try:
        version_num = int(await conn.fetchval("SELECT current_setting('server_version_num')"))
        problem = check_server_version(version_num)
        if problem:
            raise ReplayServerError(problem)
        notes.append(f"scratch server version {version_num}")
        await conn.execute(f"DROP DATABASE IF EXISTS {_q(db_name)} WITH (FORCE)")
        await conn.execute("DO $$ BEGIN IF to_regrole('rds_superuser') IS NULL THEN CREATE ROLE rds_superuser NOLOGIN; "
                           "END IF; END $$")
        # RDS gives rds_superuser these with ADMIN, so the master can grant them on (rl-002: db_migrator).
        await conn.execute("GRANT pg_read_all_stats, pg_signal_backend, pg_monitor TO rds_superuser WITH ADMIN OPTION")
        await conn.execute(f"DO $$ BEGIN IF to_regrole('{MASTER}') IS NULL THEN CREATE ROLE {MASTER}; END IF; END $$")
        # BYPASSRLS stands in for what rds_superuser gives the RDS master and plain PostgreSQL cannot: it reads FORCE
        # ROW LEVEL SECURITY tables unfiltered (AA-817 probe v2; 239 and 244 refuse to run when RLS is active for
        # it, 245's header). Not inherited through the stand-in rds_superuser, so it is set on the master itself.
        await conn.execute(f"ALTER ROLE {MASTER} LOGIN CREATEROLE CREATEDB NOSUPERUSER BYPASSRLS "
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
            attrs = role_attributes(r)
            await master.execute(f"DO $$ BEGIN IF to_regrole('{r['role']}') IS NULL THEN "
                                 f"CREATE ROLE {_q(r['role'])} {attrs}; END IF; END $$")
            notes.append(f"bootstrap role {r['role']} ({attrs}): live, created by no migration")
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


async def fill_roles(master_dsn: str, index: int, creators: dict, live_roles: dict, items: list,
                     seen: set) -> list:
    """Role gap (step 3a): before the file at `index`, create (as the master, as on Dev) every live role whose
    creating file comes earlier but failed in the replay. Only the role itself, with its live attributes: what else
    that file did (grants, objects) stays a replay gap and keeps explaining its findings. Returns the names.
    `seen` caches the creator roles already found on the server (a live role is never dropped by a later file:
    it exists on Dev), so the server is asked only when a role is due that was not seen yet, not before every
    file."""
    if not roles_to_fill(index, creators, seen):
        return []
    conn = await _connect(master_dsn)
    try:
        existing = {r["rolname"] for r in await conn.fetch("SELECT rolname::text FROM pg_catalog.pg_roles")}
        seen |= existing & set(creators)
        out = []
        for name in roles_to_fill(index, creators, existing):
            try:
                await conn.execute(f"CREATE ROLE {_q(name)} {role_attributes(live_roles[name])}")
                out.append(f"{name} (from {items[creators[name]].rel})")
                seen.add(name)
            except Exception as exc:      # reported, not fatal: the file that needs it then fails and says why
                out.append(f"FAILED {name} (from {items[creators[name]].rel}): {type(exc).__name__} {exc}")
    finally:
        await conn.close()
    return out


def transfer_files(items: list, texts: dict) -> dict:
    """Pure: {owner dir: index of its X1 ownership-transfer file} = the first file of the dir whose code runs
    `ALTER SCHEMA <anchor schema> OWNER TO …` (CIS 245, bk-014, tp-013; crm is born under crm_owner and has none).
    From that file on, DB Migrate runs the dir's files as the anchor's new owner (resolve_role)."""
    out: dict = {}
    for i, it in enumerate(items):
        od = rm.OWNER_DIRS.get(it.owner)
        if od is None or it.owner in out:
            continue
        code = rm._role_view(texts[it.owner][it.file], [])
        if re.search(rf"\bALTER SCHEMA \"?{od.anchor_schema.upper()}\"? OWNER TO\b", code):
            out[it.owner] = i
    return out


# Every object `$2` owns in the schemas `$1`, as CIS 245 item 4 reads them at apply time (bk-014 / tp-013 list the
# same kinds by hand): relations and standalone composite types (indexes, toast, row types and owned / identity
# sequences follow their table), enum / domain / range types (array types follow), routines, extended statistics,
# collations, conversions, text search dictionaries and configurations; extension members (pg_depend deptype e)
# left out. `name` is already quoted (format %I.%I).
OWNED_OBJECTS_SQL = """
WITH s AS (SELECT ns.oid, ns.nspname FROM pg_catalog.pg_namespace ns WHERE ns.nspname = ANY($1::text[])),
ext AS (SELECT d.classid, d.objid FROM pg_catalog.pg_depend d WHERE d.deptype = 'e'),
objects AS (
    SELECT 1 AS ord,
           CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE'
                          WHEN 'S' THEN 'SEQUENCE' WHEN 'c' THEN 'TYPE' ELSE 'TABLE' END AS kind,
           pg_catalog.format('%I.%I', s.nspname, c.relname) AS name
      FROM pg_catalog.pg_class c JOIN s ON s.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S', 'c') AND c.relowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_class'::regclass AND ext.objid = c.oid)
       AND NOT (c.relkind = 'S' AND EXISTS (
                SELECT 1 FROM pg_catalog.pg_depend d
                 WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
                   AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype IN ('a', 'i')))
    UNION ALL
    SELECT 2, CASE y.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, pg_catalog.format('%I.%I', s.nspname, y.typname)
      FROM pg_catalog.pg_type y JOIN s ON s.oid = y.typnamespace
     WHERE y.typtype IN ('e', 'd', 'r') AND y.typowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_type'::regclass AND ext.objid = y.oid)
    UNION ALL
    SELECT 3, CASE f.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
           pg_catalog.format('%I.%I(%s)', s.nspname, f.proname, pg_catalog.pg_get_function_identity_arguments(f.oid))
      FROM pg_catalog.pg_proc f JOIN s ON s.oid = f.pronamespace
     WHERE f.proowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_proc'::regclass AND ext.objid = f.oid)
    UNION ALL
    SELECT 4, 'STATISTICS', pg_catalog.format('%I.%I', s.nspname, x.stxname)
      FROM pg_catalog.pg_statistic_ext x JOIN s ON s.oid = x.stxnamespace WHERE x.stxowner = $2::regrole
    UNION ALL
    SELECT 5, 'COLLATION', pg_catalog.format('%I.%I', s.nspname, x.collname)
      FROM pg_catalog.pg_collation x JOIN s ON s.oid = x.collnamespace
     WHERE x.collowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_collation'::regclass AND ext.objid = x.oid)
    UNION ALL
    SELECT 6, 'CONVERSION', pg_catalog.format('%I.%I', s.nspname, x.conname)
      FROM pg_catalog.pg_conversion x JOIN s ON s.oid = x.connamespace
     WHERE x.conowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_conversion'::regclass AND ext.objid = x.oid)
    UNION ALL
    SELECT 7, 'TEXT SEARCH DICTIONARY', pg_catalog.format('%I.%I', s.nspname, x.dictname)
      FROM pg_catalog.pg_ts_dict x JOIN s ON s.oid = x.dictnamespace
     WHERE x.dictowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_dict'::regclass AND ext.objid = x.oid)
    UNION ALL
    SELECT 8, 'TEXT SEARCH CONFIGURATION', pg_catalog.format('%I.%I', s.nspname, x.cfgname)
      FROM pg_catalog.pg_ts_config x JOIN s ON s.oid = x.cfgnamespace
     WHERE x.cfgowner = $2::regrole
       AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_catalog.pg_ts_config'::regclass AND ext.objid = x.oid))
SELECT ord, kind, name FROM objects ORDER BY ord, name"""
OBJECT_KINDS = ("TABLE", "VIEW", "MATERIALIZED VIEW", "FOREIGN TABLE", "SEQUENCE", "TYPE", "DOMAIN", "PROCEDURE",
                "AGGREGATE", "FUNCTION", "STATISTICS", "COLLATION", "CONVERSION", "TEXT SEARCH DICTIONARY",
                "TEXT SEARCH CONFIGURATION")
# Schemas whose objects an X1 transfer file leaves with their owner (only the schema moves): CIS 245 item 4 moves
# objects in the 11 runtime schemas, not in catalog (its views stay catalog_owner's). Kept here, not on
# run_migration.OwnerDir: it describes what one historic file did, not how DB Migrate runs files.
TRANSFER_SKIP_OBJECTS = {"cis": frozenset({"catalog"})}


def transfer_scope(owner_dir: str, present: list) -> tuple:
    """Pure: (schemas whose owner the transfer file changes, schemas whose master-owned objects it moves), both
    limited to the dir's schemas that exist in the replay, in the dir's order."""
    od = rm.OWNER_DIRS[owner_dir]
    have = set(present)
    schemas = [sc for sc in od.schemas if sc in have]
    skip = TRANSFER_SKIP_OBJECTS.get(owner_dir, frozenset())
    return schemas, [sc for sc in schemas if sc not in skip]


def ownership_statements(schemas: list, objects: list, new_owner: str) -> list:
    """Pure: the ALTER … OWNER TO statements of an X1 transfer file. Every schema goes to `new_owner` (the anchor
    schema's live owner: 245 sets all 12 CIS schemas to cis_owner, so a later owner change of one schema on Dev
    stays visible as drift), schemas first (the new owner needs CREATE on them), then every object row
    (kind, quoted name) of OWNED_OBJECTS_SQL in its order."""
    owner = _q(new_owner)
    out = [f"ALTER SCHEMA {_q(sc)} OWNER TO {owner}" for sc in schemas]
    for kind, name in objects:
        if kind not in OBJECT_KINDS:
            raise ValueError(f"unexpected object kind {kind!r} for {name}")
        out.append(f"ALTER {kind} {name} OWNER TO {owner}")
    return out


async def fill_ownership(master_dsn: str, owner_dir: str, live_schema_owner: dict) -> list:
    """Owner gap (step 3b): the dir's transfer file failed in the replay (a replay gap upstream of it), so do what it
    does to ownership, the way it does it (transfer_scope + ownership_statements): every schema of the dir that
    exists goes to the anchor schema's live owner, and every object the master owns in them (TRANSFER_SKIP_OBJECTS
    left out) goes to that owner too; objects of a third owner (catalog_owner's catalog.* views) stay. Its grants,
    default privileges and checks are NOT redone: they stay a replay gap (privileges, informational). Returns the
    statements run, for the report."""
    od = rm.OWNER_DIRS[owner_dir]
    new_owner = live_schema_owner.get(od.anchor_schema)
    if not new_owner or new_owner == MASTER:
        return []
    done: list = []
    conn = await _connect(master_dsn)
    try:
        present = [r["nspname"] for r in await conn.fetch(
            "SELECT nspname::text FROM pg_catalog.pg_namespace WHERE nspname = ANY($1::text[]) ORDER BY 1",
            list(od.schemas))]
        schemas, object_schemas = transfer_scope(owner_dir, present)
        objects = [(r["kind"], r["name"]) for r in await conn.fetch(OWNED_OBJECTS_SQL, object_schemas, MASTER)]
        for st in ownership_statements(schemas, objects, new_owner):   # one by one: a refused one is reported
            try:
                await conn.execute(st)
                done.append(st)
            except Exception as exc:
                done.append(f"FAILED {st}: {type(exc).__name__} {getattr(exc, 'sqlstate', '') or ''} {exc}".strip())
    finally:
        await conn.close()
    return done


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
            if item.owner == BASELINE:
                for stmt in baseline_statements(sql):
                    await conn.execute(stmt)
            elif plan.switch:
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


def baseline_statements(sql: str) -> list:
    """Pure: what run_item sends for a baseline file: the one session setting its guard accepts (only here, only for
    baseline files), then the file whole (its own BEGIN … COMMIT: all or nothing)."""
    return [f"SET {BASELINE_SETTING} = 'on'", sql]


def _position(items: list, anchor: str) -> int | None:
    """Index of the item a decision names: a registry key ('107', 'tp-002') or an owner file ('cis/020_x.sql', for an
    unregistered legacy file, which has no key)."""
    if "/" in anchor:
        return next((i for i, it in enumerate(items) if it.rel == anchor), None)
    return next((i for i, it in enumerate(items) if it.key == anchor), None)


def add_baseline(order: dict, baseline: list, texts: dict) -> list:
    """Owner decisions (db/schema_drift_decisions.json `baseline`): SQL files under db/replay_baseline/ that recreate
    what a lost migration made (objects of a repo that no longer exists, db/gen_replay_baseline.py), each run as the
    master right BEFORE the item named in `before`: a registry key, an owner file rel (`cis/020_x.sql`) or "start".
    A file without the baseline guard is refused (it would run unguarded). Pure apart from reading the files;
    returns problems."""
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
        at = 0 if before == "start" else _position(items, before)
        if at is None:
            problems.append(f"baseline {rel}: {before!r} is neither a registry key nor a file of the replay order")
            continue
        text = path.read_text(encoding="utf-8")
        if BASELINE_SETTING not in text or rm.BASELINE_MARKER not in text:
            problems.append(f"baseline {rel}: has no replay guard (db/gen_replay_baseline.py writes it)")
            continue
        texts[BASELINE][rel] = text
        items.insert(at, Item(BASELINE, rel, f"before {before}", "", False))
    return problems


NEEDED_RES = (
    re.compile(r'relation "([a-z_][a-z0-9_$]*\.[a-z_][a-z0-9_$]*)" does not exist'),
    re.compile(r'schema "([a-z_][a-z0-9_$]*)" does not exist'),
    re.compile(r"\b([a-z_][a-z0-9_$]*\.[a-z_][a-z0-9_$]*) (?:does not exist|is missing|missing)\b"),
    re.compile(r"\bschema ([a-z_][a-z0-9_$]*) \(migration [0-9]+\) is missing"),
)


def gap_roots(items: list, texts: dict, known_schemas: set) -> list:
    """Pure: the objects the failed / partial files needed (from their first error: `relation "x.y" does not exist`,
    `schema "x" does not exist`, a guard's `x.y does not exist` / `missing`), with the files that need them and the
    files that CREATE them (ddl_targets `created`, any status). root = no file creates the object before the first file
    that needs it: history no repo holds (a baseline file, or an owner decision); otherwise the gap is a cascade of
    its creator's failure."""
    need: dict = {}
    first: dict = {}
    for i, it in enumerate(items):
        if it.status == "ok" or not it.error:
            continue
        err = it.error.lower()
        for rx in NEEDED_RES:
            found = [m.group(1) for m in rx.finditer(err) if m.group(1).split(".", 1)[0] in known_schemas]
            for obj in found:
                need.setdefault(obj, []).append(it.rel)
                first.setdefault(obj, i)
            if found:
                break
    made: dict = {}
    for i, it in enumerate(items):
        created = ddl_targets(texts[it.owner][it.file], known_schemas)["created"] if need else []
        for obj in need:
            if obj in created:
                made.setdefault(obj, []).append((i, f"{it.rel} ({it.status})"))
    return [{"object": o, "needed_by": need[o], "created_by": [r for _, r in made.get(o, [])],
             "root": not any(i < first[o] for i, _ in made.get(o, []))} for o in sorted(need)]


BACKFILL_RE = re.compile(r"^\s*backfill\b", re.IGNORECASE)


def backfilled(migrations: list) -> list:
    """Registry versions whose row was written by a later back-registration (description `backfill: …`, e.g. tp-007
    registering tp-001…tp-006): their applied_at is the registration time, not when the file ran, so their place
    in the order is only an upper bound. Reported, and placed by a `replay_order` entry when a dependency proves it."""
    return sorted(str(m["version"]) for m in migrations if BACKFILL_RE.match(str(m.get("description") or "")))


def apply_order_fixes(order: dict, fixes: list) -> list:
    """Owner decisions (db/schema_drift_decisions.json `replay_order`): move registered files whose registry
    applied_at is not when they ran (back-registered rows, `keys`) or unregistered legacy files whose name-order
    place is not when they ran (`files`: 'cis/021_x.sql', placed by the evidence of their header date) to just
    before `before` (a registry key or an owner file), in the order listed. Pure; returns problems (unknown key or
    file, a key / file moved twice, `before` in the moved set)."""
    problems: list = []
    items = order["items"]
    moved: set = set()
    for fx in fixes:
        keys = [str(k) for k in fx.get("keys", [])]
        files = [str(f) for f in fx.get("files", [])]
        names = keys + files
        before = str(fx.get("before", ""))
        if not names or not before:
            problems.append(f"replay_order entry {fx!r}: needs `keys` or `files`, and `before`")
            continue
        if before in names or set(names) & moved:
            problems.append(f"replay_order {names} before {before}: a key is moved twice or is its own anchor")
            continue
        picked = ([it for k in keys for it in items if it.key == k and it.registered]
                  + [it for f in files for it in items if it.rel == f and not it.registered])
        if len(picked) != len(names):
            problems.append(f"replay_order {names}: not every key is a registered file of the replay, or every "
                            f"file an unregistered one")
            continue
        if _position(items, before) is None:
            problems.append(f"replay_order {names}: {before!r} is not in the replay order")
            continue
        for it in picked:
            items.remove(it)
        at = _position(items, before)
        items[at:at] = picked
        for it in picked:
            it.moved_before = before
        moved |= set(names)
    return problems


async def replay(admin_dsn: str, live: dict, sources: dict, out_dump: str | None, baseline: list = (),
                 replay_order: list = ()) -> dict:
    texts = {o: {f: (Path(p) / f).read_text(encoding="utf-8") for f in os.listdir(p) if f.endswith(".sql")}
             for o, p in sources.items()}
    live_roles = {r["role"]: r for r in live.get("roles", [])}
    live_names = frozenset(live_roles)
    created = created_roles([t for fs in texts.values() for t in fs.values()], live_names)
    order = plan_order(live.get("migrations", []), {o: list(fs) for o, fs in texts.items()})
    baseline_problems = apply_order_fixes(order, list(replay_order)) + add_baseline(order, list(baseline), texts)
    creators = role_creators(order["items"], texts, live_names)
    transfers = transfer_files(order["items"], texts)
    live_schema_owner = {x["schema"]: x.get("owner") for x in live.get("schemas", [])}
    db_name = (live.get("database") or {}).get("name") or DEFAULT_DB
    notes = await prepare(admin_dsn, live, created, db_name) + baseline_problems
    admin_db = _dsn(admin_dsn, *_admin_user(admin_dsn), db_name)
    master_dsn = _dsn(admin_dsn, MASTER, SCRATCH_PASSWORD, db_name)
    migrator_dsn = _dsn(admin_dsn, MIGRATOR, SCRATCH_PASSWORD, db_name)
    known_schemas = {x["schema"] for x in live.get("schemas", [])} | {
        sc for d in rm.OWNER_DIRS.values() for sc in d.schemas}
    migrator_from = next((i for i, it in enumerate(order["items"]) if it.key == MIGRATOR_LOGIN_FROM), None)
    migrator_ready = False
    roles_seen: set = set()
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
        filled = await fill_roles(master_dsn, i, creators, live_roles, order["items"], roles_seen)
        if filled:
            item.roles_filled = filled
            notes.append(f"role gap before {item.rel}: created {', '.join(filled)} with their live attributes "
                         f"(the file that creates them on Dev failed in the replay)")
        dsn = migrator_dsn if (use_migrator and migrator_ready) else master_dsn
        await run_item(item, texts[item.owner][item.file], dsn)
        if item.status != "ok":
            item.names, item.schemas = mentioned(texts[item.owner][item.file], known_schemas)
            item.ddl = ddl_targets(texts[item.owner][item.file], known_schemas)
            if transfers.get(item.owner) == i:
                item.ownership_filled = await fill_ownership(master_dsn, item.owner, live_schema_owner)
                bad = [x for x in item.ownership_filled if x.startswith("FAILED")]
                notes.append(f"owner gap after {item.rel} (the {item.owner} ownership transfer failed in the replay): "
                             f"{len(item.ownership_filled) - len(bad)} ALTER … OWNER TO statement(s) as the master, so "
                             f"the dir's later files run as its live owner like on Dev; its grants stay a gap"
                             + (f"; {len(bad)} refused, first: {bad[0][:200]}" if bad else ""))
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
        "backfilled": backfilled(live.get("migrations", [])),
        "gap_roots": gap_roots(items, texts, known_schemas),
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
    decisions: dict = {}
    if args.decisions and Path(args.decisions).is_file():
        decisions = json.loads(Path(args.decisions).read_text(encoding="utf-8"))
    try:
        result = asyncio.run(replay(args.admin_dsn, live, parse_sources(args.source), args.dump,
                                    decisions.get("baseline", []), decisions.get("replay_order", [])))
    except ReplayServerError as exc:
        print(f"REPLAY refused: {exc}", file=sys.stderr, flush=True)
        return 1
    Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True, default=str), encoding="utf-8")
    c = result["counts"]
    print(f"REPLAY done files={c['files']} ok={c['ok']} partial={c['partial']} failed={c['failed']} "
          f"legacy={c['legacy']} "
          f"pending={c['pending']} registered_without_file={c['no_file']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
