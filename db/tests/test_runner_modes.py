"""X1 S12: DB Migrate mode=set-password and mode=run-script (db/run_migration.py).

No database, no asyncpg, no AWS: connections and the secret read are fakes. The SCRAM verifier is checked
against the RFC 7677 test vector and against an independent client-side SCRAM exchange (RFC 5802 Hi()
written out as the HMAC loop, not hashlib.pbkdf2_hmac).
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import base64
import contextlib
import hashlib
import hmac
import io
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import run_migration as rm  # noqa: E402
from test_run_migration import FakeConn, job  # noqa: E402

ROOT = HERE.parent.parent
PASSWORD = "Xk9-tR2_vL8.wQ4~zN7!pS3*hJ6(mB1)"            # 32 printable ASCII characters
assert len(PASSWORD) == 32
MASTER_DSN = "postgresql://aa_cis_admin:master-not-used@db.example:5432/aa_cis_dev"
CIS_APP_DSN = f"postgresql://cis_app:{PASSWORD}@db.example:5432/aa_cis_dev?sslmode=require"
RUNNER_URL = ("https://aa-cis-bronze-005097885195.s3.us-west-1.amazonaws.com/db-migrate/4242/run_migration.py"
              "?X-Amz-Signature=deadbeef")


# ── independent SCRAM client (RFC 5802 §3, written from the RFC, no shared code with the runner) ──
def _hi(password: bytes, salt: bytes, i: int) -> bytes:
    u = hmac.new(password, salt + b"\x00\x00\x00\x01", hashlib.sha256).digest()
    out = bytearray(u)
    for _ in range(i - 1):
        u = hmac.new(password, u, hashlib.sha256).digest()
        out = bytearray(a ^ b for a, b in zip(out, u))
    return bytes(out)


def _client_proof(password: str, salt: bytes, i: int, auth_message: bytes) -> tuple:
    salted = _hi(password.encode(), salt, i)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored = hashlib.sha256(client_key).digest()
    signature = hmac.new(stored, auth_message, hashlib.sha256).digest()
    proof = bytes(a ^ b for a, b in zip(client_key, signature))
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    return proof, hmac.new(server_key, auth_message, hashlib.sha256).digest()


VERIFIER_RE = re.compile(r"^SCRAM-SHA-256\$([0-9]+):([A-Za-z0-9+/=]+)\$([A-Za-z0-9+/=]+):([A-Za-z0-9+/=]+)$")


def _parse(verifier: str) -> tuple:
    m = VERIFIER_RE.match(verifier)
    assert m, verifier
    return int(m.group(1)), base64.b64decode(m.group(2)), base64.b64decode(m.group(3)), base64.b64decode(m.group(4))


def _server_accepts(verifier: str, proof: bytes, auth_message: bytes) -> bytes:
    """What PostgreSQL does with the stored secret (RFC 5802 §3, server side): returns ServerSignature
    when the proof is valid, raises AssertionError otherwise."""
    _, _, stored_key, server_key = _parse(verifier)
    signature = hmac.new(stored_key, auth_message, hashlib.sha256).digest()
    client_key = bytes(a ^ b for a, b in zip(proof, signature))
    assert hashlib.sha256(client_key).digest() == stored_key, "client proof rejected"
    return hmac.new(server_key, auth_message, hashlib.sha256).digest()


class ScramVerifierTest(unittest.TestCase):
    def test_rfc7677_vector(self):
        # RFC 7677 §3: user "user", password "pencil".
        salt = base64.b64decode("W22ZaJ0SNY7soEsUEjb6gQ==")
        verifier = rm.scram_sha256_verifier("pencil", salt=salt, iterations=4096)
        auth = (b"n=user,r=rOprNGfwEbeRWgbNEkqO,"
                b"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,"
                b"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0")
        proof = base64.b64decode("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        server_sig = _server_accepts(verifier, proof, auth)
        self.assertEqual(base64.b64encode(server_sig).decode(), "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        self.assertTrue(verifier.startswith("SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$"))

    def test_random_salt_and_independent_client_exchange(self):
        v1, v2 = rm.scram_sha256_verifier(PASSWORD), rm.scram_sha256_verifier(PASSWORD)
        self.assertNotEqual(v1, v2)                                  # fresh salt per call
        iterations, salt, _, _ = _parse(v1)
        self.assertEqual((iterations, len(salt)), (4096, 16))
        auth = b"n=cis_app,r=" + base64.b64encode(os.urandom(18)) + b",s=x,i=4096,c=biws"
        proof, expected_server_sig = _client_proof(PASSWORD, salt, iterations, auth)
        self.assertEqual(_server_accepts(v1, proof, auth), expected_server_sig)
        wrong, _ = _client_proof(PASSWORD + "x", salt, iterations, auth)
        with self.assertRaises(AssertionError):
            _server_accepts(v1, wrong, auth)

    def test_hi_matches_pbkdf2_for_the_record(self):
        salt = os.urandom(16)
        self.assertEqual(_hi(b"pw", salt, 50), hashlib.pbkdf2_hmac("sha256", b"pw", salt, 50))


class ModeParsingTest(unittest.TestCase):
    def test_allowed_values(self):
        self.assertEqual(rm.parse_mode("check"), rm.Mode("check"))
        self.assertEqual(rm.parse_mode("apply"), rm.Mode("apply"))
        self.assertEqual(rm.parse_mode("set-password:cis_app"), rm.Mode("set-password", "cis_app"))
        self.assertEqual(rm.parse_mode("set-password:db_migrator"), rm.Mode("set-password", "db_migrator"))
        self.assertEqual(rm.parse_mode("run-script:db/scripts/session_info.py"),
                         rm.Mode("run-script", "db/scripts/session_info.py"))

    def test_refused_values(self):
        for value in ("", "Apply", "apply ", "set-password", "set-password:", "set-password:aa_cis_admin",
                      "set-password:booking", "set-password:cis_app:x", "set-password: cis_app",
                      "run-script", "run-script:", "run-script:db/scripts/../run_migration.py",
                      "run-script:db/scripts/x.sql", "run-script:db/migrations/cis/240_x.sql",
                      "run-script:db/scripts/sub/x.py", "run-script:/db/scripts/x.py", "run-script:db/scripts/X.py",
                      "run-script:db/scripts/x.py\n", "drop:x", "check:x"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                rm.parse_mode(value)

    def test_unknown_mode_exits_10_before_any_fetch_or_connection(self):
        def boom(*a, **k):
            raise AssertionError("must not be called")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task({"MIGRATION_MODE": "set-password:aa_cis_admin"}, fetch=boom,
                                           connect=boom, get_secret=boom))
        self.assertEqual(code, 10)
        self.assertIn("not in db/owners.yaml password_roles", out.getvalue())


class DsnLoginTest(unittest.TestCase):
    def test_user_and_password_as_asyncpg_reads_them(self):
        who = rm.dsn_login("postgresql://cis_app:p%40ss%3Aw%2Fd@host:5432/db?sslmode=require")
        self.assertEqual((who.user, who.password, who.raw_password), ("cis_app", "p@ss:w/d", "p%40ss%3Aw%2Fd"))
        self.assertEqual(rm.dsn_login("postgres://u:a:b@h/d").password, "a:b")   # first ':' splits user/password
        self.assertNotIn("p@ss", repr(who))

    def test_refused_shapes_never_echo_the_value(self):
        for dsn in ("mysql://cis_app:SECRETVALUE@h/d", '{"url": "postgresql://cis_app:SECRETVALUE@h/d"}',
                    "postgresql://h/d", "postgresql://cis_app:SECRET@VALUE@h/d",
                    "postgresql://cis_app:SECRETVALUE@h/d?password=SECRETVALUE",
                    "postgresql://cis_app:SECRETVALUE@[::1/d"):
            with self.subTest(dsn=dsn[:12]):
                with self.assertRaises(ValueError) as cm:
                    rm.dsn_login(dsn)
                self.assertNotIn("SECRET", str(cm.exception))


class PwConn:
    """Master connection for set-password: records statements, optionally fails on one."""

    def __init__(self, login="aa_cis_admin", can_login=True, fail_on=None, fail_msg=""):
        self.login, self.can_login, self.fail_on, self.fail_msg = login, can_login, fail_on, fail_msg
        self.executed, self.closed = [], False

    async def fetchval(self, query, *args):
        if query == rm.SESSION_USER_SQL:
            return self.login
        if query == rm.ROLE_LOGIN_SQL:
            return self.can_login
        raise AssertionError(query)

    async def execute(self, sql):
        if self.fail_on and sql.startswith(self.fail_on):
            raise PgError("XX000", self.fail_msg.format(sql=sql))
        self.executed.append(sql)

    async def close(self):
        self.closed = True


class TestConn:
    def __init__(self, user="cis_app", limit=90):
        self.row, self.closed = {"current_user": user, "rolconnlimit": limit}, False

    async def fetchrow(self, query):
        assert query == rm.WHOAMI_SQL
        return self.row

    async def close(self):
        self.closed = True


class PgError(Exception):
    def __init__(self, sqlstate, msg):
        super().__init__(msg)
        self.sqlstate = sqlstate


class SetPasswordTest(unittest.TestCase):
    def run_sp(self, secret=CIS_APP_DSN, role="cis_app", master=None, test=None, test_error=None):
        self.master = master or PwConn()
        self.test = test or TestConn()
        self.connects, self.secret_reads, self.connect_kw = [], [], []

        async def connect(dsn, settings, **kw):
            self.connects.append((dsn, settings))
            self.connect_kw.append(kw)
            if dsn == MASTER_DSN:
                return self.master
            if test_error:
                raise test_error
            return self.test

        def get_secret(sid):
            self.secret_reads.append(sid)
            if isinstance(secret, Exception):
                raise secret
            return secret

        env = {"MIGRATION_MODE": f"set-password:{role}", "DATABASE_URL": MASTER_DSN, "RUNNER_URL": RUNNER_URL,
               "MIGRATION_URL": "", "MIGRATION_FILE": "", "MIGRATION_VERSION": "", "MIGRATION_SHA256": ""}
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = asyncio.run(rm.run_task(env, fetch=lambda u: b"", connect=connect, get_secret=get_secret))
        self.out = out.getvalue() + err.getvalue()
        return code

    def assertNoSecret(self, *extra):
        for value in (PASSWORD, CIS_APP_DSN, "SECRETVALUE", *extra):
            self.assertNotIn(value, self.out)
        self.assertNotIn("SCRAM-SHA-256$", self.out)

    def test_happy_path(self):
        self.assertEqual(self.run_sp(), 0)
        self.assertEqual(self.secret_reads, ["aa-cis/dev/rds-cis-app"])
        alter, comment = self.master.executed
        m = re.match(r"""^ALTER ROLE "cis_app" PASSWORD '(SCRAM-SHA-256\$[^']+)'$""", alter)
        self.assertTrue(m, alter)
        verifier = m.group(1)
        iterations, salt, _, _ = _parse(verifier)
        auth = b"n=cis_app,r=abc,r=abcdef,s=x,i=4096,c=biws,r=abcdef"
        proof, server_sig = _client_proof(PASSWORD, salt, iterations, auth)
        self.assertEqual(_server_accepts(verifier, proof, auth), server_sig)    # the DSN's password logs in
        self.assertRegex(comment, r"""^COMMENT ON ROLE "cis_app" IS 'x1:password-set [0-9]{4}-[0-9]{2}-[0-9]{2}T"""
                                  r"""[0-9:]{8}Z by DB Migrate set-password \(run 4242\)'$""")
        self.assertIn(rm.PASSWORD_MARKER, comment)
        self.assertEqual([d for d, _ in self.connects], [MASTER_DSN, CIS_APP_DSN])
        self.assertEqual(self.connect_kw, [{}, {"ssl": "require"}])         # test login never in cleartext
        self.assertIn("MIGRATE set-password: test login current_user=cis_app rolconnlimit=90\n", self.out)
        self.assertTrue(self.master.closed and self.test.closed)
        self.assertNoSecret(verifier, "deadbeef")

    def test_db_migrator_reads_its_own_secret_and_percent_encoded_password(self):
        pw = "a@b:c/d%e" + "f" * 30
        dsn = "postgresql://db_migrator:a%40b%3Ac%2Fd%25e" + "f" * 30 + "@db.example/aa_cis_dev"
        self.assertEqual(self.run_sp(secret=dsn, role="db_migrator", test=TestConn("db_migrator", 5)), 0)
        self.assertEqual(self.secret_reads, ["aa-cis/dev/db-migrator"])
        verifier = self.master.executed[0].split("'")[1]
        iterations, salt, _, _ = _parse(verifier)
        proof, sig = _client_proof(pw, salt, iterations, b"m")
        self.assertEqual(_server_accepts(verifier, proof, b"m"), sig)          # decoded password, as asyncpg sends
        self.assertNoSecret(pw, dsn, verifier)

    def test_refusals_before_any_change(self):
        cases = [
            ("dsn user is another role", dict(secret=CIS_APP_DSN.replace("cis_app:", "aa_app_user:"))),
            ("empty secret", dict(secret="  \n")),
            ("no password", dict(secret="postgresql://cis_app@db.example/aa_cis_dev")),
            ("short password", dict(secret="postgresql://cis_app:SECRETVALUEshort@db.example/d")),
            ("non-ascii password", dict(secret="postgresql://cis_app:" + "SECRETVALUE" + "é" * 30 + "@h/d")),
            ("json secret", dict(secret='{"dsn": "postgresql://cis_app:SECRETVALUE@h/d"}')),
            ("role missing", dict(master=PwConn(can_login=None))),
            ("role NOLOGIN", dict(master=PwConn(can_login=False))),
        ]
        for name, kw in cases:
            with self.subTest(name):
                self.assertEqual(self.run_sp(**kw), 11)
                self.assertEqual(self.master.executed, [])
                self.assertEqual(len(self.connects), 1)                         # never the test login
                self.assertIn("MIGRATE ERROR:", self.out)
                self.assertNoSecret()

    def test_unreadable_secret_logs_the_error_code_only(self):
        class ClientError(Exception):
            response = {"Error": {"Code": "ResourceNotFoundException"}}
        self.assertEqual(self.run_sp(secret=ClientError("can't find the specified secret value")), 11)
        self.assertIn("unreadable (ClientError ResourceNotFoundException)", self.out)
        self.assertEqual(self.master.executed, [])

    def test_only_the_master_may_set_passwords(self):
        self.assertEqual(self.run_sp(master=PwConn(login="db_migrator")), 8)
        self.assertEqual((self.secret_reads, self.master.executed), ([], []))

    def test_failed_test_login_does_not_mark_the_role_and_logs_class_and_sqlstate_only(self):
        escaped = PASSWORD.replace("!", "\\!")                                # a form exact replace would miss
        code = self.run_sp(test_error=PgError("28P01", f"password authentication failed ({escaped}) {CIS_APP_DSN}"))
        self.assertEqual(code, 12)
        self.assertEqual(len(self.master.executed), 1)                          # ALTER only, no COMMENT
        self.assertIn("test login as cis_app with aa-cis/dev/rds-cis-app failed: PgError 28P01. The password is set",
                      self.out)
        self.assertNotIn("password authentication failed", self.out)
        self.assertNoSecret(escaped)

    def test_target_must_equal_the_master_connection(self):
        pw = PASSWORD
        cases = [
            ("other host", f"postgresql://cis_app:{pw}@other.example:5432/aa_cis_dev"),
            ("other port", f"postgresql://cis_app:{pw}@db.example:6432/aa_cis_dev"),
            ("other database", f"postgresql://cis_app:{pw}@db.example:5432/postgres"),
            ("no database", f"postgresql://cis_app:{pw}@db.example:5432"),
            ("host in query", f"postgresql://cis_app:{pw}@db.example:5432/aa_cis_dev?host=evil.example"),
            ("two hosts", f"postgresql://cis_app:{pw}@db.example:5432,evil.example:5432/aa_cis_dev"),
        ]
        for name, dsn in cases:
            with self.subTest(name):
                self.assertEqual(self.run_sp(secret=dsn), 11)
                self.assertEqual(self.master.executed, [])
                self.assertEqual(len(self.connects), 1)
                self.assertNoSecret(dsn)
        # Default port and host case: same target.
        self.assertEqual(self.run_sp(secret=f"postgresql://cis_app:{pw}@DB.example/aa_cis_dev"), 0)

    def test_redact_covers_escaped_and_encoded_forms(self):
        secret = "a'b\\c d%"
        text = f"x {secret} {secret!r} {rm.urllib.parse.quote(secret, safe='')} y"
        out = rm._redact(text, (secret,))
        self.assertEqual(out.count("***"), 3, out)
        self.assertNotIn("b\\\\c", out)

    def test_test_login_as_another_user_is_refused(self):
        self.assertEqual(self.run_sp(test=TestConn(user="aa_cis_admin")), 12)
        self.assertEqual(len(self.master.executed), 1)

    def test_alter_failure_redacts_the_verifier(self):
        master = PwConn(fail_on="ALTER ROLE", fail_msg="syntax error near {sql}")
        self.assertEqual(self.run_sp(master=master), 6)
        self.assertIn("""syntax error near ALTER ROLE "cis_app" PASSWORD '***'""", self.out)
        self.assertNoSecret()


SCRIPT = """
import json

async def main(conn):
    who = await conn.fetchval("SELECT session_user::text")
    print("SCRIPT who=" + who)
"""


def _sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class RunScriptTest(unittest.TestCase):
    def run_rs(self, source=SCRIPT, path="db/scripts/x.py", conn=None, **extra):
        env = {"MIGRATION_MODE": f"run-script:{path}", "MIGRATION_FILE": path, "MIGRATION_URL": "u",
               "MIGRATION_SHA256": _sha(source), "MIGRATION_VERSION": "", "DATABASE_URL": "postgresql://x", **extra}
        self.conn = conn or FakeConn()
        self.sleeps = []

        async def connect(dsn, settings, **kw):
            self.settings = settings
            return self.conn

        async def sleep(s):
            self.sleeps.append(s)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda url: source.encode(), connect=connect, sleep=sleep))
        self.out = out.getvalue()
        return code

    def test_runs_main_as_master_after_the_idle_check(self):
        self.assertEqual(self.run_rs(), 0)
        self.assertIn("SCRIPT who=aa_cis_admin\n", self.out)
        self.assertIn("MIGRATE idle: shared.job running=0 queued=0\n", self.out)
        self.assertIn("MIGRATE run-script: done\n", self.out)
        self.assertEqual(self.settings, rm.DEFAULT_SETTINGS)
        self.assertTrue(self.conn.closed)

    def test_busy_refuses_without_running_and_override_proceeds(self):
        busy = ({"booking": [job("bk_x")], "shared": []}, 0)
        self.assertEqual(self.run_rs(conn=FakeConn(states=[busy])), 7)
        self.assertNotIn("SCRIPT who", self.out)
        self.assertEqual(self.sleeps, [20, 20, 20])
        self.assertIn("refusing run-script", self.out)
        self.assertEqual(self.run_rs(conn=FakeConn(states=[busy]), MIGRATION_IDLE_OVERRIDE="hotfix"), 0)
        self.assertIn("idle check OVERRIDDEN (hotfix)", self.out)

    def test_refusals(self):
        self.assertEqual(self.run_rs(MIGRATION_FILE="db/scripts/other.py"), 10)
        self.assertEqual(self.run_rs(MIGRATION_SHA256="0" * 64), 2)
        self.assertEqual(self.run_rs(source="def main(conn):\n    pass\n"), 10)
        self.assertEqual(self.run_rs(source="async def main():\n    pass\n"), 10)
        self.assertEqual(self.run_rs(source="async def main(conn:\n"), 10)
        self.assertEqual(self.run_rs(conn=FakeConn(login="db_migrator")), 8)
        self.assertNotIn("SCRIPT who", self.out)

    def test_failures_exit_13(self):
        raising = "async def main(conn):\n    raise RuntimeError('boom')\n"
        self.assertEqual(self.run_rs(source=raising), 13)
        self.assertIn("script raised RuntimeError", self.out)
        self.assertEqual(self.run_rs(source="async def main(conn):\n    return 3\n"), 13)

    def test_script_error_text_is_redacted_for_the_master_dsn(self):
        leaky = ("import os\nasync def main(conn):\n"
                 "    raise RuntimeError('cannot reach ' + os.environ['DATABASE_URL'])\n")
        dsn = "postgresql://aa_cis_admin:Mst%21Secret-Value-123456@db.example:5432/aa_cis_dev"
        rm_env = dict(os.environ, DATABASE_URL=dsn)
        old = os.environ.copy()
        os.environ.clear(); os.environ.update(rm_env)
        try:
            self.assertEqual(self.run_rs(source=leaky, DATABASE_URL=dsn), 13)
        finally:
            os.environ.clear(); os.environ.update(old)
        self.assertIn("script raised RuntimeError", self.out)
        for value in (dsn, "Mst%21Secret-Value-123456", "Mst!Secret-Value-123456"):
            self.assertNotIn(value, self.out)
        returning = "async def main(conn):\n    return 'x ' + 'Mst!Secret-Value-123456'\n"
        self.assertEqual(self.run_rs(source=returning, DATABASE_URL=dsn), 13)
        self.assertNotIn("Mst!Secret-Value-123456", self.out)

    def test_read_only_script_skips_the_wait_and_sets_the_session_read_only(self):
        busy = ({"booking": [job("bk_x")], "shared": []}, 0)
        src = "READ_ONLY = True\n" + SCRIPT
        self.assertEqual(self.run_rs(source=src, conn=FakeConn(states=[busy])), 0)
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.settings, {**rm.DEFAULT_SETTINGS, "default_transaction_read_only": "on"})
        self.assertIn("READ_ONLY script, the idle check is report-only", self.out)
        self.assertIn("SCRIPT who=aa_cis_admin\n", self.out)
        # READ_ONLY = False behaves like no declaration: waits and refuses while busy.
        self.assertEqual(self.run_rs(source="READ_ONLY = False\n" + SCRIPT, conn=FakeConn(states=[busy])), 7)
        self.assertEqual(self.settings, rm.DEFAULT_SETTINGS)

    def test_read_only_declaration_shape(self):
        bad = ["READ_ONLY = 1\n", "READ_ONLY = True\nREAD_ONLY = True\n", "READ_ONLY: bool = True\n",
               "READ_ONLY = x = True\n", "READ_ONLY = True\nSQL = 'SET default_transaction_read_only = off'\n",
               "READ_ONLY = True\nSQL = 'BEGIN READ  WRITE'\n"]
        for head in bad:
            with self.subTest(head=head):
                self.assertTrue(rm.script_errors(head + SCRIPT, "db/scripts/x.py"))
        self.assertEqual(rm.script_errors("READ_ONLY = True\n" + SCRIPT, "db/scripts/x.py"), [])
        self.assertEqual(rm.script_errors("SQL = 'SET default_transaction_read_only = off'\n" + SCRIPT,
                                          "db/scripts/x.py"), [])               # only READ_ONLY files are checked
        self.assertTrue(rm.script_is_read_only((ROOT / "db/scripts/session_info.py").read_text()))

    def test_main_guard_does_not_fire(self):
        src = SCRIPT + "\nif __name__ == '__main__':\n    raise SystemExit('ran as __main__')\n"
        self.assertEqual(self.run_rs(source=src), 0)

    def test_inspect_script_and_session_info(self):
        path = "db/scripts/session_info.py"
        out = io.StringIO()
        cwd = os.getcwd()
        os.chdir(ROOT)
        try:
            self.assertEqual(rm.inspect_script(path, out=out), 0)
        finally:
            os.chdir(cwd)
        self.assertEqual(out.getvalue().strip(), '{"errors": []}')
        self.assertEqual(rm.script_errors("x = 1\n", "db/scripts/x.py")[0][:15], "needs a top-lev")
        self.assertTrue(rm.script_errors(SCRIPT, "db/scripts/../x.py"))

        class RowConn:
            async def fetchrow(self, sql):
                return {"session_user": "aa_cis_admin", "database": "aa_cis_dev", "server_version": "15.8",
                        "application_name": "db-migrate", "lock_timeout": "5s", "statement_timeout": "15min"}

        ns = {"__name__": "db_script"}
        exec(compile((ROOT / path).read_text(), path, "exec"), ns)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            asyncio.run(ns["main"](RowConn()))
        self.assertIn("SCRIPT session_user=aa_cis_admin\n", buf.getvalue())


# ── the three workflows on the migrator task definition (X1 S12) ──
WORKFLOWS = {name: (ROOT / ".github" / "workflows" / f"{name}.yml").read_text(encoding="utf-8")
             for name in ("db-migrate", "db-schema-dump", "db-isolation-probe")}
# Every variable name the task could see before S12 (db-migrate overrides) plus the dump's two: S12 adds none.
TASK_ENV_NAMES = {"RUNNER_URL", "MIGRATION_URL", "MIGRATION_FILE", "MIGRATION_VERSION", "MIGRATION_SHA256",
                  "MIGRATION_MODE", "MIGRATION_SNAPSHOT", "MIGRATION_IDLE_OVERRIDE", "DUMP_BUCKET", "DUMP_KEY"}
JOB_ENV_NAMES = {
    "db-migrate": {"AWS_REGION", "CLUSTER", "SERVICE", "BUCKET", "LOG_GROUP", "DB_INSTANCE", "MIGRATION", "MODE",
                   "ENVIRONMENT", "OVERRIDE_BUSY_JOBS"},
}


class MigratorWorkflowTest(unittest.TestCase):
    def test_each_workflow_runs_the_migrator_revision_and_deregisters_it(self):
        for name, text in WORKFLOWS.items():
            with self.subTest(workflow=name):
                self.assertIn("run: bash .github/scripts/migrator-task.sh prepare", text)
                self.assertRegex(text, r"- name: Deregister the migrator revision\n\s+if: always\(\) && "
                                       r"steps\.td\.outputs\.arn != ''\n\s+run: bash \.github/scripts/"
                                       r"migrator-task\.sh deregister \"\$\{\{ steps\.td\.outputs\.arn \}\}\"")
                self.assertIn('--task-definition "$TASK_DEF"' if name != "db-isolation-probe"
                              else '--task-definition "$RUNTD"', text)
                self.assertIn("{containerOverrides: [{name: \"migrate\"", text)
                self.assertNotIn('name: "api"', text)
                self.assertIn('migrate/migrate/$TASK', text)
                self.assertIn('select(.name=="migrate") | .exitCode', text)
                self.assertNotIn("api/api/", text)
                self.assertNotIn("JOB_WORKER_IN_API", text)            # the migrator image never starts the api
                self.assertNotIn(".services[0].networkConfiguration' <<<", text)   # SG comes from the script

    def test_no_new_environment_variable_names(self):
        for name, text in WORKFLOWS.items():
            with self.subTest(workflow=name):
                names = set(re.findall(r'\{name: "([A-Z0-9_]+)", value:', text))
                self.assertLessEqual(names, TASK_ENV_NAMES)
        # Job-level env of DB Migrate: role/script fold into MIGRATION, no ROLE / SCRIPT variable.
        block = WORKFLOWS["db-migrate"].split("    env:\n", 1)[1].split("    steps:\n", 1)[0]
        keys = set(re.findall(r"^      ([A-Z0-9_]+):", block, re.M))
        self.assertEqual(keys, JOB_ENV_NAMES["db-migrate"])

    def test_runner_reads_only_known_names(self):
        src = (ROOT / "db" / "run_migration.py").read_text(encoding="utf-8")
        read = set(re.findall(r'env(?:\.get\(|\[)"([A-Z0-9_]+)"', src)) | set(re.findall(r'os\.environ\["([A-Z0-9_]+)"\]', src))
        self.assertIn("MIGRATION_SHA256", read)                      # the pattern sees digits too
        self.assertLessEqual(read, (TASK_ENV_NAMES - {"DUMP_BUCKET", "DUMP_KEY"}) | {"DATABASE_URL"})

    def test_db_migrate_inputs_fold_into_existing_names(self):
        text = WORKFLOWS["db-migrate"]
        self.assertIn("MIGRATION: ${{ inputs.mode == 'set-password' && inputs.role || (inputs.mode == 'run-script' "
                      "&& inputs.script || inputs.migration) }}", text)
        self.assertIn('set-password) mode_value="set-password:$MIGRATION"', text)
        self.assertIn('run-script) mode_value="run-script:$MIGRATION"', text)
        self.assertIn('if ! [[ "$MIGRATION" =~ ^db/scripts/[a-z0-9_]+\\.py$ ]]', text)
        self.assertIn("- name: Unused inputs", text)
        for code in ("7", "8", "9", "10", "11", "12", "13"):
            self.assertIn(f'if [ "$EXIT" = "{code}" ]', text)
        self.assertIn('--next-token "$TOKEN"', text)                            # every page of the task log
        self.assertIn('if [ "$STATUS" != "STOPPED" ]', text)                   # waiter ceiling reported as such


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "needs bash + jq")
class MigratorTaskScriptTest(unittest.TestCase):
    SCRIPT = ROOT / ".github" / "scripts" / "migrator-task.sh"
    BASE = {"taskDefinition": {
        "taskDefinitionArn": "arn:aws:ecs:us-west-1:005097885195:task-definition/aa-cis-dev-db-migrate:1",
        "family": "aa-cis-dev-db-migrate", "revision": 1, "status": "ACTIVE",
        "taskRoleArn": "arn:aws:iam::005097885195:role/aa-cis-dev-db-migrate-task-role",
        "executionRoleArn": "arn:aws:iam::005097885195:role/aa-cis-dev-db-migrate-execution-role",
        "networkMode": "awsvpc", "volumes": [], "placementConstraints": [], "cpu": "256", "memory": "512",
        "requiresCompatibilities": ["FARGATE"], "compatibilities": ["EC2", "FARGATE"],
        "requiresAttributes": [{"name": "ecs.capability.secrets.asm.environment-variables"}],
        "registeredAt": "2026-10-18T10:00:00+00:00", "registeredBy": "arn:aws:sts::005097885195:assumed-role/x",
        "containerDefinitions": [{
            "name": "migrate", "image": "005097885195.dkr.ecr.us-west-1.amazonaws.com/aa-cis-dev-api:latest",
            "essential": True, "command": ["python3", "-c", "raise SystemExit('x')"],
            "secrets": [{"name": "DATABASE_URL", "valueFrom": "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/rds-7K4JX3"}],
            "logConfiguration": {"logDriver": "awslogs", "options": {"awslogs-group": "/ecs/aa-cis-dev"}}}]}}

    def sh(self, *args, stdin=""):
        return subprocess.run(["bash", str(self.SCRIPT), *args], input=stdin, capture_output=True, text=True)

    def test_render_swaps_only_the_image(self):
        image = "005097885195.dkr.ecr.us-west-1.amazonaws.com/aa-cis-dev-api:dev-0123abc"
        r = self.sh("render", image, stdin=json.dumps(self.BASE))
        self.assertEqual(r.returncode, 0, r.stderr)
        got = json.loads(r.stdout)
        want = dict(self.BASE["taskDefinition"])
        for k in ("taskDefinitionArn", "revision", "status", "compatibilities", "requiresAttributes",
                  "registeredAt", "registeredBy"):
            want.pop(k)
        want["containerDefinitions"] = [dict(want["containerDefinitions"][0], image=image)]
        self.assertEqual(got, want)

    def test_render_refuses_an_unexpected_container_layout(self):
        bad = json.loads(json.dumps(self.BASE))
        bad["taskDefinition"]["containerDefinitions"][0]["name"] = "api"
        self.assertNotEqual(self.sh("render", "img", stdin=json.dumps(bad)).returncode, 0)

    def test_check_base_accepts_the_terraform_revision(self):
        r = self.sh("check-base", stdin=json.dumps(self.BASE))
        self.assertEqual(r.returncode, 0, r.stderr)
        s22 = json.loads(json.dumps(self.BASE))
        s22["taskDefinition"]["containerDefinitions"][0]["secrets"][0]["valueFrom"] = \
            "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/db-migrator-Ab12Cd"
        self.assertEqual(self.sh("check-base", stdin=json.dumps(s22)).returncode, 0)

    def test_check_base_refuses_copies_and_hand_registered_revisions(self):
        def variant(edit):
            td = json.loads(json.dumps(self.BASE))
            edit(td["taskDefinition"], td["taskDefinition"]["containerDefinitions"][0])
            return json.dumps(td)
        cases = {
            "per-run copy": lambda t, c: c.update(image="005097885195.dkr.ecr.us-west-1.amazonaws.com/aa-cis-dev-api:dev-0123abc"),
            "task role": lambda t, c: t.update(taskRoleArn="arn:aws:iam::005097885195:role/aa-cis-dev-ecs-task-role"),
            "execution role": lambda t, c: t.update(executionRoleArn="arn:aws:iam::005097885195:role/x-execution-role"),
            "cis_app secret": lambda t, c: c["secrets"][0].update(
                valueFrom="arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/rds-cis-app-Ab12Cd"),
            "two secrets": lambda t, c: c["secrets"].append({"name": "X", "valueFrom": c["secrets"][0]["valueFrom"]}),
            "secret name": lambda t, c: c["secrets"][0].update(name="DSN"),
            "plain env": lambda t, c: c.update(environment=[{"name": "A", "value": "b"}]),
            "family": lambda t, c: t.update(family="aa-cis-dev-db-migrate-x"),
        }
        for name, edit in cases.items():
            with self.subTest(name):
                r = self.sh("check-base", stdin=variant(edit))
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("not the Terraform migrator shape", r.stderr)

    def test_deregister_only_touches_the_migrator_family(self):
        r = self.sh("deregister", "arn:aws:ecs:us-west-1:005097885195:task-definition/aa-cis-dev-api:673")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not a revision of aa-cis-dev-db-migrate", r.stderr)
        self.assertNotEqual(self.sh("deregister", "").returncode, 0)


if __name__ == "__main__":
    unittest.main()
