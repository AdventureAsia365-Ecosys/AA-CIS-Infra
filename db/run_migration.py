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
  * a lint runs before any connection: unknown or misplaced directives, CONCURRENTLY outside a
    no-transaction file, destructive statements without the header, transaction control inside a
    no-transaction file. A lint error stops check and apply alike.

Exit codes: 0 ok · 2 sha256 mismatch · 3 file ran but did not register · 4 lint error ·
5 destructive apply without a snapshot · 6 PostgreSQL error (lock/statement timeout included).

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
CONCURRENTLY_RE = re.compile(r"\bCONCURRENTLY\b")
DESTRUCTIVE_RES = (
    (re.compile(r"^DROP (TABLE|SCHEMA|MATERIALIZED VIEW)\b"), "DROP {0}"),
    (re.compile(r"^TRUNCATE\b"), "TRUNCATE"),
    # ALTER TABLE … DROP [COLUMN] x — but not DROP CONSTRAINT/DEFAULT/NOT NULL/IDENTITY/EXPRESSION.
    (re.compile(r"^ALTER TABLE\b.*\bDROP (?!CONSTRAINT\b|DEFAULT\b|NOT\b|IDENTITY\b|EXPRESSION\b)"),
     "ALTER TABLE … DROP COLUMN"),
)
DELETE_RE = re.compile(r"^(WITH\b.*\b)?DELETE FROM\b")


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


def lint(sql: str, d: Directives) -> tuple:
    """Returns (errors, warnings) for one migration file, given its parsed directives."""
    errors, warnings = list(d.errors), []
    stmts = split_statements(sql)
    for s in stmts:
        if CONCURRENTLY_RE.search(s.code) and not d.no_transaction:
            errors.append(f"line {s.line}: CONCURRENTLY cannot run inside a transaction — put it in its own "
                          f"file with `-- migrate: no-transaction` (MIG-10)")
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


def _fetch(url: str) -> bytes:
    return urllib.request.urlopen(url, timeout=30).read()


async def _connect(dsn: str, settings: dict):
    import asyncpg   # only inside the task: the lint path and CI run without asyncpg
    return await asyncpg.connect(dsn, timeout=30, server_settings=settings)


async def run_task(env=None, fetch=_fetch, connect=_connect) -> int:
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
    errors, warnings = lint(sql, d)
    log(f"directives: transaction={'no' if d.no_transaction else 'yes'} destructive={'yes' if d.destructive else 'no'} "
        f"lock_timeout={d.settings['lock_timeout']} statement_timeout={d.settings['statement_timeout']}")
    for w in warnings:
        log(f"WARNING: {w}")
    if errors:
        for e in errors:
            log(f"ERROR: {e}")
        return 4

    conn = await connect(env["DATABASE_URL"], d.settings)
    try:
        latest = await conn.fetchval(
            "SELECT version FROM shared.schema_versions WHERE version ~ $1 ORDER BY version DESC LIMIT 1",
            version_pattern(version))
        applied = await conn.fetchval("SELECT applied_at FROM shared.schema_versions WHERE version = $1", version)
        log(f"before: latest_registered_same_owner={latest} this_version_applied_at={applied}")
        if mode != "apply":
            return 0
        if applied:
            log("skip: already applied")
            return 0
        if d.destructive:
            snapshot = (env.get("MIGRATION_SNAPSHOT") or "").strip()
            if not snapshot:
                log("ERROR: destructive migration needs the RDS snapshot DB Migrate takes first "
                    "(MIGRATION_SNAPSHOT is empty) — run it through db-migrate.yml")
                return 5
            log(f"snapshot taken before apply: {snapshot}")
        try:
            if d.no_transaction:
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
    errors, warnings = lint(sql, d)
    print(json.dumps({**d.as_json(), "errors": errors, "warnings": warnings}), file=out)
    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--inspect":
        sys.exit(inspect(sys.argv[2]))
    sys.exit(asyncio.run(run_task()))
