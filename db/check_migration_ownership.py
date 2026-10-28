"""Migration ownership lint (AA-853, data standards DM-1.2 / DM-8.1): a file in db/migrations/<owner>/ may
create, alter, drop, comment on, grant on or write to objects in its owner's schemas only.

The owner's schemas come from run_migration.OWNER_DIRS, the runner's mirror of db/owners.yaml `schemas` plus
`dropped_schemas` (schemas the owner dropped, which its older files and the drop file still name; AA-850)
(db/tests/test_owners_registry.py keeps them equal). roles/ is Infra-native (roles, extensions, public.*
leftovers, undo files of the X1 transfers) and is not checked here.

What counts as touching an object, per statement (top level, and the statements of a DO block body; function
and procedure bodies run later, as their caller, and are not read):
  * DDL: CREATE / ALTER / DROP of a schema, table, view, materialized view, sequence, function, procedure,
    aggregate, type, domain, index (its table), trigger / policy / rule (their table), statistics, collation,
    text search object, operator, foreign table; ALTER … SET SCHEMA (the new schema too); CREATE TABLE … AS.
  * COMMENT ON the same kinds (a column: its table; a constraint / trigger / policy / rule: its table).
  * GRANT / REVOKE … ON <object | SCHEMA s | ALL … IN SCHEMA s>, and ALTER DEFAULT PRIVILEGES … IN SCHEMA s.
  * Writes: INSERT INTO, UPDATE, DELETE FROM, MERGE INTO, TRUNCATE, COPY … FROM, REFRESH MATERIALIZED VIEW,
    top-level SELECT … INTO <table> (it creates the table), ALTER TABLE … ATTACH / DETACH PARTITION <table>.
  * CREATE EXTENSION … SCHEMA s (without SCHEMA the extension lands in the default schema, as CIS 226 / 234 do;
    extensions belong in roles/ from now on, but that is not this lint's rule).
  * Statements with no schema boundary, reaching whatever the named roles own or were granted in every schema:
    ALTER DEFAULT PRIVILEGES without IN SCHEMA and REASSIGN OWNED BY pass only when every role they name is the
    dir's own owner role (OWNER_ROLES, mirrors owners.yaml owner_role + view_owner_roles); DROP OWNED BY (it also
    revokes what other owners granted to the role) always fails. They belong in roles/.
Reading another owner's objects (a view over catalog.*, a foreign key REFERENCES, a function call) is not a
finding: cross-owner reads go through grants, which the isolation probe checks.

Allowed outside the owner's schemas: the version registration every file ends with (INSERT INTO
shared.schema_versions, the registry DB Migrate reads), and temporary objects (pg_temp, CREATE TEMP …).

Unqualified names resolve through the file's own `SET [LOCAL] search_path` (`RESET search_path` and
`… TO DEFAULT` clear it); without one they resolve through the session's default search_path, which is the
master's public schema on Dev, so such a name is a finding too and new files qualify every name (MIG-2). As in
PostgreSQL, a CREATE lands in the first schema of the path, but any other statement finds the first schema of
the path that holds the object: an unqualified non-CREATE name is therefore a finding as soon as the path names
a schema outside the owner's, unless the file itself created that name earlier (then it is that object). Dynamic
SQL (EXECUTE '…' in a DO block) is out of reach and is reported as a warning; the drift report of DB Schema Dump
(db/schema_drift.py) is the backstop for anything this lint cannot see.

Standard library only; imported by check_migration_files.py (Migration Copy Guard, "Migration lint and unique
numbers" job), so a PR that copies such a file fails before DB Migrate ever sees it.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_migration  # noqa: E402  (split_statements, _role_view, OWNER_DIRS, migration_path)

# Writes every owner dir makes outside its schemas on purpose: the self-registration of each file.
REGISTRY_WRITES = frozenset({("shared", "schema_versions")})
TEMP_SCHEMAS = ("pg_temp",)
# owners.yaml owner_role + view_owner_roles per dir (isolation_probe.OWNERS; the unit test keeps them equal): the
# roles whose global default privileges / REASSIGN OWNED stay inside the dir's schemas.
OWNER_ROLES = {"cis": frozenset({"cis_owner", "catalog_owner"}), "booking": frozenset({"bk_owner"}),
               "tripplanner": frozenset({"tp_owner"}), "crm": frozenset({"crm_owner"})}

_IDENT = r'(?:"(?:[^"]|"")+"|[A-Z_][A-Z0-9_$]*)'
QNAME = rf"{_IDENT}(?:\s*\.\s*{_IDENT}){{0,2}}"
# What may stand right before a statement inside a DO body once it is split on ';' (BEGIN … IF … THEN …).
_LEAD = r"(?:^|\b(?:BEGIN|THEN|ELSE|LOOP|DECLARE)\s+)"
_IFX = r"(?:IF\s+(?:NOT\s+)?EXISTS\s+)?"

# Kinds whose name is a schema-qualified object (CREATE / ALTER / DROP / COMMENT ON <kind> <qname>).
_OBJ_KINDS = (r"MATERIALIZED\s+VIEW|FOREIGN\s+TABLE|TEXT\s+SEARCH\s+(?:CONFIGURATION|DICTIONARY|PARSER|TEMPLATE)"
              r"|OPERATOR\s+(?:CLASS|FAMILY)|TABLE|VIEW|SEQUENCE|FUNCTION|PROCEDURE|ROUTINE|AGGREGATE|TYPE|DOMAIN"
              r"|INDEX|STATISTICS|COLLATION|CONVERSION|OPERATOR")
_CREATE_RE = re.compile(
    rf"{_LEAD}CREATE\s+(?:OR\s+REPLACE\s+)?(?P<mods>(?:(?:GLOBAL|LOCAL|TEMP|TEMPORARY|UNLOGGED|RECURSIVE|TRUSTED"
    rf"|PROCEDURAL)\s+)*)(?P<kind>MATERIALIZED\s+VIEW|FOREIGN\s+TABLE|TEXT\s+SEARCH\s+\w+|OPERATOR\s+(?:CLASS|FAMILY)"
    rf"|TABLE|VIEW|SEQUENCE|FUNCTION|PROCEDURE|AGGREGATE|TYPE|DOMAIN|STATISTICS|COLLATION|CONVERSION|OPERATOR)"
    rf"\s+{_IFX}(?P<name>{QNAME})")
# CREATE SCHEMA [IF NOT EXISTS] name [AUTHORIZATION r] | CREATE SCHEMA AUTHORIZATION r (the schema is named r)
_CREATE_SCHEMA_RE = re.compile(rf"{_LEAD}CREATE\s+SCHEMA\s+{_IFX}(?:AUTHORIZATION\s+(?P<role>{_IDENT})"
                               rf"|(?P<name>{_IDENT}))")
_CREATE_INDEX_RE = re.compile(
    rf"{_LEAD}CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:{_IFX}{_IDENT}\s+)?ON\s+(?:ONLY\s+)?"
    rf"(?P<name>{QNAME})")
# CREATE / ALTER / DROP TRIGGER, POLICY, RULE … ON <table> (a rule: AS ON <event> TO <table>)
_ON_TABLE_RE = re.compile(
    rf"{_LEAD}(?P<verb>CREATE|ALTER|DROP)\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?(?P<kind>TRIGGER|POLICY|RULE)\s+"
    rf"{_IFX}{_IDENT}\s+(?:AS\s+ON\s+\w+\s+TO|.*?\bON)\s+(?:ONLY\s+)?(?P<name>{QNAME})")
_ALTER_RE = re.compile(rf"{_LEAD}ALTER\s+(?P<kind>{_OBJ_KINDS})\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?(?P<name>{QNAME})")
_ALTER_SCHEMA_RE = re.compile(rf"{_LEAD}ALTER\s+SCHEMA\s+(?P<name>{_IDENT})")
_SET_SCHEMA_RE = re.compile(rf"\bSET\s+SCHEMA\s+(?P<name>{_IDENT})")
_DROP_RE = re.compile(rf"{_LEAD}DROP\s+(?P<kind>{_OBJ_KINDS}|SCHEMA)\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?"
                      rf"(?P<names>.+?)(?:\s+(?:CASCADE|RESTRICT))?$")
_COMMENT_RE = re.compile(
    rf"{_LEAD}COMMENT\s+ON\s+(?P<kind>COLUMN|CONSTRAINT|TRIGGER|POLICY|RULE|SCHEMA|{_OBJ_KINDS})\s+(?P<rest>.+?)"
    rf"\s+IS\b")
_GRANT_RE = re.compile(rf"{_LEAD}(?:GRANT|REVOKE)\b(?P<privs>.*?)\bON\s+(?P<target>.+?)\s+(?:TO|FROM)\s")
_DEFAULT_PRIVS_RE = re.compile(rf"{_LEAD}ALTER\s+DEFAULT\s+PRIVILEGES\b.*?\bIN\s+SCHEMA\s+(?P<names>.+?)\s+"
                               rf"(?:GRANT|REVOKE)\b")
_WRITE_RES = (
    ("INSERT INTO", re.compile(rf"\bINSERT\s+INTO\s+(?P<name>{QNAME})")),
    ("UPDATE", re.compile(rf"(?:^|\b(?:BEGIN|THEN|ELSE|LOOP|AS|\))\s*)UPDATE\s+(?:ONLY\s+)?(?P<name>{QNAME})"
                          rf"(?:\s+(?:AS\s+)?{_IDENT})?\s+SET\b")),
    ("DELETE FROM", re.compile(rf"\bDELETE\s+FROM\s+(?:ONLY\s+)?(?P<name>{QNAME})")),
    ("MERGE INTO", re.compile(rf"\bMERGE\s+INTO\s+(?:ONLY\s+)?(?P<name>{QNAME})")),
    ("TRUNCATE", re.compile(rf"{_LEAD}TRUNCATE\s+(?:TABLE\s+)?(?P<names>.+?)(?:\s+(?:RESTART|CONTINUE|CASCADE|RESTRICT)"
                            rf"\b.*)?$")),
    ("COPY", re.compile(rf"{_LEAD}COPY\s+(?P<name>{QNAME})(?:\s*\([^)]*\))?\s+FROM\b")),
    ("REFRESH MATERIALIZED VIEW",
     re.compile(rf"{_LEAD}REFRESH\s+MATERIALIZED\s+VIEW\s+(?:CONCURRENTLY\s+)?(?P<name>{QNAME})")),
)
_SEARCH_PATH_RE = re.compile(r"(?:^|\b(?:BEGIN|THEN|ELSE)\s+)SET\s+(?:LOCAL\s+|SESSION\s+)?SEARCH_PATH\s*(?:TO|=)\s*"
                             r"(?P<value>.+)$")
_RESET_PATH_RE = re.compile(r"(?:^|\b(?:BEGIN|THEN|ELSE)\s+)RESET\s+(?:SEARCH_PATH|ALL)$")
# Top-level SELECT … INTO <table> (in a DO body SELECT … INTO is a PL/pgSQL variable, so DO views skip it).
_SELECT_INTO_RE = re.compile(rf"^(?:WITH\b.*?)?\bSELECT\b.*?(?<!INSERT )\bINTO\s+(?P<mods>(?:(?:GLOBAL|LOCAL|TEMP"
                             rf"|TEMPORARY|UNLOGGED)\s+)*)(?:TABLE\s+)?(?P<name>{QNAME})")
_PARTITION_RE = re.compile(rf"\b(?P<verb>ATTACH|DETACH)\s+PARTITION\s+(?P<name>{QNAME})")
_EXTENSION_RE = re.compile(rf"{_LEAD}CREATE\s+EXTENSION\s+{_IFX}(?P<ext>{_IDENT})(?P<rest>.*)$")
_EXT_SCHEMA_RE = re.compile(rf"\bSCHEMA\s+(?P<name>{_IDENT})")
_GLOBAL_DEFAULT_PRIVS_RE = re.compile(rf"{_LEAD}ALTER\s+DEFAULT\s+PRIVILEGES\b(?!.*\bIN\s+SCHEMA\b)"
                                      rf"(?:\s+FOR\s+(?:ROLE|USER)\s+(?P<roles>.+?))?\s+(?:GRANT|REVOKE)\b")
_OWNED_BY_RE = re.compile(rf"{_LEAD}(?P<verb>REASSIGN|DROP)\s+OWNED\s+BY\s+(?P<roles>.+?)"
                          rf"(?:\s+(?:TO|CASCADE|RESTRICT)\b.*)?$")
# Marks a touch whose reach is every schema (no schema boundary): allowed only for the dir's own owner role.
EVERY_SCHEMA = "*"
_PATH_SKIP = ("$user", "pg_catalog", "pg_temp", "")
_SET_CONFIG_PATH_RE = re.compile(r"\bSET_CONFIG\s*\(\s*'#(?P<key>[0-9]+)'\s*,\s*'#(?P<value>[0-9]+)'")
_DYNAMIC_RE = re.compile(r"\bEXECUTE\b(?!\s+(?:ON|FUNCTION|PROCEDURE)\b)")
# GRANT … ON <kind> where the object is no schema object (database, language, role parameter, …): ignored.
_GRANT_GLOBAL_RE = re.compile(r"^(?:DATABASE|LANGUAGE|TABLESPACE|FOREIGN\s+DATA\s+WRAPPER|FOREIGN\s+SERVER"
                              r"|LARGE\s+OBJECT|PARAMETER)\b")
_GRANT_ALL_IN_RE = re.compile(r"^ALL\s+(?:TABLES|SEQUENCES|FUNCTIONS|PROCEDURES|ROUTINES)\s+IN\s+SCHEMA\s+"
                              r"(?P<names>.+)$")
_GRANT_KIND_RE = re.compile(r"^(?:TABLE|SEQUENCE|FUNCTION|PROCEDURE|ROUTINE|TYPE|DOMAIN|FOREIGN\s+TABLE)\s+")


@dataclass(frozen=True)
class Touch:
    line: int          # line of the top-level statement
    action: str        # e.g. "CREATE TABLE", "GRANT ON", "INSERT INTO"
    schema: str        # '' when the name is unqualified and the file sets no search_path; EVERY_SCHEMA: no boundary
    name: str          # object (or schema) name as written, lower case
    candidates: tuple = ()   # unqualified non-CREATE name: every schema of the active search_path it may resolve to


def _ident(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace('""', '"').lower()
    return raw.lower()


def _parts(qname: str) -> list:
    return [_ident(p) for p in re.findall(_IDENT, qname)]


def _split_top(text: str) -> list:
    """Splits on commas outside parentheses (DROP FUNCTION f(int, text), g(text))."""
    out, depth, cur = [], 0, []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return [p.strip() for p in out if p.strip()]


def _strip_args(qname: str) -> str:
    return qname.split("(", 1)[0].strip()


def _code_views(stmt) -> list:
    """The code views of one top-level statement: itself, or for a DO block the statements of its body (lexed as
    code, string literals as '#<n>'). Returns [(code, strings, top_level)]."""
    if not re.match(r"^DO\b", stmt.code):
        if _SEARCH_PATH_RE.search(stmt.code) and "'" in stmt.code:
            # A top-level literal is blanked in stmt.code (SET search_path = 'booking'): read it from the text.
            strings: list = []
            return [(run_migration._role_view(stmt.text, strings).strip().rstrip(";").strip(), strings, True)]
        return [(stmt.code, [], True)]
    strings = []
    view = run_migration._role_view(stmt.text, strings)
    view = re.sub(r"^DO\s+(?:LANGUAGE\s+\S+\s+)?", "", view)
    return [(part.strip(), strings, False) for part in view.split(";") if part.strip()]


def _path_names(value: str, strings: list) -> list:
    """Schema names of a search_path value: bare or quoted identifiers and '#<n>' literals ('a, b' or 'a')."""
    names: list = []
    for item in _split_top(value):
        lit = re.fullmatch(r"'#([0-9]+)'", item.strip())
        if lit:
            names += [n.strip().strip('"').lower() for n in strings[int(lit.group(1))].split(",")]
        else:
            names += [_ident(p) for p in re.findall(_IDENT, item)]
    return [n for n in names if n not in _PATH_SKIP]


def _search_path(code: str, strings: list) -> list | None:
    """The search_path a statement sets ([] once it is reset to the default), or None when it sets none."""
    if _RESET_PATH_RE.search(code):
        return []
    m = _SEARCH_PATH_RE.search(code)
    if m:
        value = m.group("value").strip()
        return [] if value == "DEFAULT" else _path_names(value, strings)
    m = _SET_CONFIG_PATH_RE.search(code)
    if m and strings and strings[int(m.group("key"))].strip().lower() == "search_path":
        return [n.strip().strip('"').lower() for n in strings[int(m.group("value"))].split(",")
                if n.strip().strip('"').lower() not in _PATH_SKIP]
    return None


def touches(sql: str) -> tuple:
    """(touches, warnings) for one migration file: every object the file creates, alters, drops, comments on,
    grants on or writes to, with its resolved schema."""
    found: list = []
    warnings: list = []
    path: list = []                     # the file's own search_path, in file order
    temp: set = set()                   # names of the temporary objects the file creates (unqualified later)
    created: dict = {}                  # unqualified name the file created -> the schema it landed in

    def add(line: int, action: str, qname: str, relation_parts: int = 2, creates: bool = False) -> None:
        parts = _parts(_strip_args(qname))
        if not parts:
            return
        if relation_parts == 3 and len(parts) >= 3:          # COMMENT ON COLUMN schema.table.column
            schema, name = parts[-3], parts[-2]
        elif relation_parts == 3 and len(parts) == 2:        # table.column, table unqualified
            schema, name = "", parts[0]
        elif len(parts) >= 2:
            schema, name = parts[-2], parts[-1]
        else:
            schema, name = "", parts[0]
        candidates: tuple = ()
        if not schema and name in temp:
            schema = "pg_temp"
        elif not schema and creates:
            schema = path[0] if path else ""        # CREATE lands in the first schema of the path
            if schema:
                created[name] = schema
        elif not schema and name in created:
            schema = created[name]                  # the object this file created earlier
        elif not schema and path:
            # Any other statement finds the first schema of the path that holds the name: each one may be it.
            schema, candidates = path[0], tuple(path)
        found.append(Touch(line, action, schema, name, candidates))

    def add_schema(line: int, action: str, name: str) -> None:
        found.append(Touch(line, action, _ident(name), _ident(name)))

    for stmt in run_migration.split_statements(sql):
        line = stmt.line
        for code, strings, top_level in _code_views(stmt):
            sp = _search_path(code, strings)
            if sp is not None:
                path[:] = sp
                continue
            if strings and _DYNAMIC_RE.search(code) and not any(w.startswith(f"line {line}:") for w in warnings):
                warnings.append(f"line {line}: dynamic SQL (EXECUTE) in a DO block: the ownership lint cannot see "
                                f"which objects it touches (the DB Schema Dump drift report is the backstop)")
            m = _CREATE_SCHEMA_RE.search(code)
            if m:
                add_schema(line, "CREATE SCHEMA", m.group("name") or m.group("role"))
            m = _CREATE_RE.search(code)
            if m and re.search(r"\b(?:TEMP|TEMPORARY)\b", m.group("mods") or ""):
                temp.add(_parts(_strip_args(m.group("name")))[-1])
            elif m:
                kind = " ".join(m.group("kind").split())
                add(line, f"CREATE {kind}", m.group("name"), creates=True)
            m = _SELECT_INTO_RE.search(code) if top_level else None
            if m and re.search(r"\b(?:TEMP|TEMPORARY)\b", m.group("mods") or ""):
                temp.add(_parts(m.group("name"))[-1])
            elif m:
                add(line, "SELECT INTO", m.group("name"), creates=True)
            m = _EXTENSION_RE.search(code)
            s = _EXT_SCHEMA_RE.search(m.group("rest")) if m else None
            if s:
                found.append(Touch(line, "CREATE EXTENSION", _ident(s.group("name")), _ident(m.group("ext"))))
            for p in _PARTITION_RE.finditer(code):
                add(line, f"{p.group('verb')} PARTITION", p.group("name"))
            m = _GLOBAL_DEFAULT_PRIVS_RE.search(code)
            if m:
                roles = ", ".join(_ident(r) for r in _split_top(m.group("roles") or ""))
                found.append(Touch(line, "ALTER DEFAULT PRIVILEGES without IN SCHEMA", EVERY_SCHEMA, roles))
            m = _OWNED_BY_RE.search(code)
            if m:
                found.append(Touch(line, f"{m.group('verb')} OWNED BY", EVERY_SCHEMA,
                                   ", ".join(_ident(r) for r in _split_top(m.group("roles")))))
            m = _CREATE_INDEX_RE.search(code)
            if m:
                add(line, "CREATE INDEX ON", m.group("name"))
            m = _ON_TABLE_RE.search(code)
            if m:
                add(line, f"{m.group('verb')} {m.group('kind')} ON", m.group("name"))
            m = _ALTER_SCHEMA_RE.search(code)
            if m:
                add_schema(line, "ALTER SCHEMA", m.group("name"))
            m = _ALTER_RE.search(code)
            if m:
                kind = " ".join(m.group("kind").split())
                if kind in ("INDEX", "TABLE", "MATERIALIZED VIEW") and re.match(r"ALL\b", m.group("name").upper()):
                    pass                                     # ALTER TABLE / INDEX / … ALL IN TABLESPACE
                else:
                    add(line, f"ALTER {kind}", m.group("name"))
                s = _SET_SCHEMA_RE.search(code, m.end())
                if s:
                    add_schema(line, f"ALTER {kind} SET SCHEMA", s.group("name"))
            m = _DROP_RE.search(code)
            if m and not re.match(rf"{_LEAD}DROP\s+(?:TRIGGER|POLICY|RULE)\b", code):
                kind = " ".join(m.group("kind").split())
                for name in _split_top(m.group("names")):
                    if kind == "SCHEMA":
                        add_schema(line, "DROP SCHEMA", name)
                    else:
                        add(line, f"DROP {kind}", name)
            m = _COMMENT_RE.search(code)
            if m:
                kind, rest = " ".join(m.group("kind").split()), m.group("rest")
                if kind == "SCHEMA":
                    add_schema(line, "COMMENT ON SCHEMA", rest)
                elif kind == "COLUMN":
                    add(line, "COMMENT ON COLUMN", rest, relation_parts=3)
                elif kind in ("CONSTRAINT", "TRIGGER", "POLICY", "RULE"):
                    on = re.search(rf"\bON\s+(?:DOMAIN\s+)?(?P<name>{QNAME})", rest)
                    if on:
                        add(line, f"COMMENT ON {kind}", on.group("name"))
                else:
                    add(line, f"COMMENT ON {kind}", rest)
            m = _GRANT_RE.search(code)
            if m:
                target = m.group("target").strip()
                if _GRANT_GLOBAL_RE.match(target):
                    pass
                elif target.startswith("SCHEMA "):
                    for name in _split_top(target[len("SCHEMA "):]):
                        add_schema(line, "GRANT ON SCHEMA", name)
                else:
                    a = _GRANT_ALL_IN_RE.match(target)
                    if a:
                        for name in _split_top(a.group("names")):
                            add_schema(line, "GRANT ON ALL IN SCHEMA", name)
                    else:
                        target = _GRANT_KIND_RE.sub("", target, count=1)
                        for name in _split_top(target):
                            add(line, "GRANT ON", name)
            m = _DEFAULT_PRIVS_RE.search(code)
            if m:
                for name in _split_top(m.group("names")):
                    add_schema(line, "ALTER DEFAULT PRIVILEGES IN SCHEMA", name)
            for action, rx in _WRITE_RES:
                for w in rx.finditer(code):
                    if "names" in w.groupdict() and w.group("names"):
                        for name in _split_top(w.group("names")):
                            add(line, action, name)
                    else:
                        add(line, action, w.group("name"))
    return found, warnings


# The last file number that may still name a dropped schema, per owner dir: the file that dropped it (AA-850, CIS 299).
# A later file that names one again (CREATE SCHEMA + tables) would bring back a schema the isolation probe and the RLS
# catalogue no longer watch, so the lint refuses it; a schema that comes back must return to owners.yaml schemas.
DROPPED_SCHEMAS_LAST_FILE = {"cis": 299}


def owner_schemas(owner_dir: str, number: int = None) -> tuple:
    """The schemas a file of the dir may touch: its live schemas and, for files up to the drop file, the ones it dropped
    (owners.yaml dropped_schemas, AA-850: its older files grant on them, the drop file drops them)."""
    d = run_migration.OWNER_DIRS[owner_dir]
    last = DROPPED_SCHEMAS_LAST_FILE.get(owner_dir)
    if d.dropped_schemas and (number is None or last is None or number > last):
        return d.schemas
    return d.schemas + d.dropped_schemas


def lint(sql: str, rel_path: str) -> tuple:
    """(errors, warnings) for one file. Only owner dirs (run_migration.OWNER_DIRS) are checked."""
    owner_dir, _number = run_migration.migration_path(rel_path)
    if owner_dir not in run_migration.OWNER_DIRS:
        return [], []
    mine = set(owner_schemas(owner_dir, _number))
    found, warnings = touches(sql)
    errors: list = []
    seen: set = set()
    for t in found:
        if t.schema in TEMP_SCHEMAS:
            continue
        if t.action == "INSERT INTO" and (t.schema, t.name) in REGISTRY_WRITES:
            continue
        foreign_path = [s for s in t.candidates if s not in mine]
        if t.schema in mine and not foreign_path:
            continue
        key = (t.line, t.action, t.schema, t.name)
        if key in seen:
            continue
        seen.add(key)
        qualify = f"qualify it ({', '.join(sorted(mine))}) (AA-853)"
        if t.schema == EVERY_SCHEMA:
            roles = {r.strip() for r in t.name.split(",") if r.strip()}
            own_roles = OWNER_ROLES.get(owner_dir, frozenset())
            if t.action != "DROP OWNED BY" and roles and roles <= own_roles:
                continue                                # only the dir's own owner role: stays in its schemas
            who = f"role {t.name}" if roles else "the role running the file"
            errors.append(f"line {t.line}: {t.action} ({who}): reaches every schema, not only {owner_dir}/'s "
                          f"({', '.join(sorted(mine))}); only {', '.join(sorted(own_roles))} may be named here, and "
                          f"DROP OWNED never; it belongs in roles/ (AA-853)")
            continue
        if foreign_path:
            errors.append(f"line {t.line}: {t.action} {t.name}: unqualified name under search_path "
                          f"{', '.join(t.candidates)}; PostgreSQL resolves it to the first of those schemas that holds "
                          f"it, which may be {', '.join(foreign_path)}, outside {owner_dir}/'s schemas; {qualify}")
            continue
        what = t.schema if t.action.endswith("SCHEMA") else f"{t.schema}.{t.name}" if t.schema else t.name
        if not t.schema:
            errors.append(f"line {t.line}: {t.action} {what}: unqualified name and no owner schema on the file's "
                          f"`SET search_path`, so it resolves to the session's default schema (public), outside "
                          f"{owner_dir}/'s schemas; {qualify}")
            continue
        other = next((o for o, d in run_migration.OWNER_DIRS.items()
                      if t.schema in d.schemas + d.dropped_schemas), None)
        whose = f"owner {other}" if other else "no owner in db/owners.yaml"
        errors.append(f"line {t.line}: {t.action} {what}: schema {t.schema} belongs to {whose}; a {owner_dir}/ "
                      f"migration touches only {', '.join(sorted(mine))} (db/owners.yaml schemas, AA-853)")
    return errors, warnings


def main(argv: list | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="+", help="files under db/migrations/<owner>/ (or any <owner>/NNN_x.sql)")
    args = parser.parse_args(argv)
    failed = 0
    for p in args.paths:
        errors, warnings = lint(Path(p).read_text(encoding="utf-8"), p)
        for w in warnings:
            print(f"warn  {p}: {w}")
        for e in errors:
            print(f"FAIL  {p}: {e}")
        failed += bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
