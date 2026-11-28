"""AA-1182 (S297): db/scripts/aa1182_master_switch_check.py (read-only evidence for the RDS-managed master switch).

No database, no AWS: fake connection, fake RDS / Secrets Manager clients and a fake connect.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa1182_master_switch_check.py"
_spec = importlib.util.spec_from_file_location("aa1182_master_switch_check", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

LEGACY_DSN = "postgresql://aa_cis_admin:" + "-".join(["legacy", "value"]) + "@db.example:5432/aa_cis_dev"


class Conn:
    async def fetchval(self, sql):
        assert sql == "SELECT session_user::text"
        return "aa_cis_admin"


class Rds:
    def __init__(self, master):
        self.master = master

    def describe_db_instances(self, DBInstanceIdentifier):  # noqa: N803 — boto3 names
        assert DBInstanceIdentifier == "aa-cis-dev-db"
        return {"DBInstances": [{"MasterUserSecret": self.master} if self.master else {}]}


class Sm:
    def __init__(self, legacy):
        self.legacy = legacy

    def get_secret_value(self, SecretId):  # noqa: N803
        assert SecretId == "aa-cis/dev/rds"
        if isinstance(self.legacy, Exception):
            raise self.legacy
        return {"SecretString": self.legacy}


class InvalidPasswordError(Exception):
    pass


class ClientError(Exception):
    response = {"Error": {"Code": "InvalidRequestException"}}


class FakeDb:
    closed = False

    async def close(self):
        self.closed = True


def run(master, legacy, login_error=None):
    seen = []

    async def connect(dsn, **kw):
        seen.append(kw)
        if login_error:
            raise login_error
        return FakeDb()

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = asyncio.run(script.check(Conn(), Rds(master), Sm(legacy), connect))
    return code, out.getvalue(), seen


ACTIVE = {"SecretArn": "arn:aws:secretsmanager:us-west-1:000000000000:secret:rds!db-x-AbCdEf", "SecretStatus": "active"}


class MasterSwitchCheckTest(unittest.TestCase):
    def test_shape_passes_the_runner_contract(self):
        src = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertTrue(script.READ_ONLY)
        self.assertEqual(rm.script_errors(src, PATH), [])

    def test_old_password_refused_is_success(self):
        code, out, seen = run(ACTIVE, LEGACY_DSN, InvalidPasswordError("password authentication failed " + LEGACY_DSN))
        self.assertEqual(code, 0)
        self.assertIn("SCRIPT session_user=aa_cis_admin\n", out)
        self.assertIn("SCRIPT managed_secret status=active\n", out)
        self.assertIn("SCRIPT legacy_master=refused (InvalidPasswordError)\n", out)
        self.assertEqual(seen, [{"ssl": "require", "timeout": 30}])
        self.assertNotIn("legacy-value", out)

    def test_deleted_legacy_secret_is_success(self):
        code, out, seen = run(ACTIVE, ClientError("scheduled for deletion"))
        self.assertEqual(code, 0)
        self.assertIn("SCRIPT legacy_master=absent (ClientError InvalidRequestException)\n", out)
        self.assertEqual(seen, [])

    def test_old_password_still_working_or_no_managed_secret_fails(self):
        self.assertEqual(run(ACTIVE, LEGACY_DSN)[0], 1)
        self.assertIn("legacy_master=STILL-LOGS-IN", run(ACTIVE, LEGACY_DSN)[1])
        code, out, _ = run(None, LEGACY_DSN, InvalidPasswordError("x"))
        self.assertEqual(code, 1)
        self.assertIn("SCRIPT managed_secret status=not-managed\n", out)


if __name__ == "__main__":
    unittest.main()
