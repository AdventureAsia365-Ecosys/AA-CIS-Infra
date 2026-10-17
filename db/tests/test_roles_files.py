"""Static checks of the Infra-native role bootstrap files, db/migrations/roles/ (X1 plan S3, MIG-6, DM-8.1).

They run as the RDS master, so review is the only gate besides these checks:
  * no password in git, ever (SEC-2): passwords are written in the Console and set by DB Migrate
    mode=set-password (X1 S17/S20);
  * no SUPERUSER / BYPASSRLS / REPLICATION granted (only the NO… forms);
  * never a membership in aa_app_user or catalog_owner (X1 plan §1.4: a policy TO r also applies to the
    members of r; lesson S236);
  * rl-001 creates exactly the roles S3 lists, and restates the N3 limits with the values of CIS 234.

Run: python3 -m unittest discover -s db/tests -v
"""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import run_migration as rm  # noqa: E402

ROLES = ROOT / "db" / "migrations" / "roles"
RL001 = ROLES / "001_x1_owner_roles.sql"
CIS234 = ROOT / "db" / "migrations" / "cis" / "234_connection_limits_pg_stat_statements.sql"
FORBIDDEN_MEMBERSHIPS = ("AA_APP_USER", "CATALOG_OWNER")


def code_view(sql: str) -> str:
    """Comments dropped, string literals replaced by '#<n>', DO bodies lexed as code, upper case."""
    return rm._role_view(sql, [])


def statements(view: str) -> list:
    return [s.strip() for s in view.split(";") if s.strip()]


def membership_grants(view: str) -> list:
    """GRANT r[, …] TO x statements (role membership: no ON clause)."""
    return [s for s in statements(view) if re.match(r"^GRANT\b", s) and not re.search(r"\bON\b", s)]


def connection_limits(view: str) -> dict:
    return {m.group(1).lower(): int(m.group(2))
            for m in re.finditer(r"\bALTER ROLE (\w+)\b[^;]*?\bCONNECTION LIMIT (-?\d+)", view)}


class EveryRolesFileTest(unittest.TestCase):
    def files(self):
        files = sorted(ROLES.glob("*.sql"))
        self.assertTrue(files, "db/migrations/roles/ has no file")
        return files

    def test_no_password(self):
        for f in self.files():
            with self.subTest(file=f.name):
                self.assertNotRegex(code_view(f.read_text(encoding="utf-8")), r"\bPASSWORD\b")

    def test_no_superuser_bypassrls_or_replication(self):
        for f in self.files():
            with self.subTest(file=f.name):
                # \b keeps NOSUPERUSER / NOBYPASSRLS / NOREPLICATION out of the match.
                self.assertNotRegex(code_view(f.read_text(encoding="utf-8")),
                                    r"\b(SUPERUSER|BYPASSRLS|REPLICATION)\b")

    def test_no_membership_in_tenant_pool_or_catalog_owner(self):
        for f in self.files():
            for g in membership_grants(code_view(f.read_text(encoding="utf-8"))):
                with self.subTest(file=f.name, grant=g):
                    granted = g.split(" TO ")[0]
                    for role in FORBIDDEN_MEMBERSHIPS:
                        self.assertNotRegex(granted, rf"\b{role}\b")


class Rl001Test(unittest.TestCase):
    view = code_view(RL001.read_text(encoding="utf-8"))

    def test_creates_the_s3_roles(self):
        self.assertRegex(self.view, r"\bCREATE ROLE BK_OWNER NOLOGIN\b")
        self.assertRegex(self.view, r"\bCREATE ROLE TP_OWNER NOLOGIN\b")
        self.assertRegex(self.view, r"\bCREATE ROLE CIS_APP LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS "
                                    r"CONNECTION LIMIT 90\b")
        self.assertNotRegex(self.view, r"\bCREATE ROLE (CIS_OWNER|DB_MIGRATOR)\b")    # rl-002, S20

    def test_memberships(self):
        grants = membership_grants(self.view)
        self.assertIn("GRANT BK_OWNER, TP_OWNER TO AA_CIS_ADMIN", grants)
        self.assertIn("GRANT CIS_APP TO AA_CIS_ADMIN", grants)
        self.assertEqual(len(grants), 2, grants)

    def test_n3_limits_match_cis_234(self):
        n3 = connection_limits(code_view(CIS234.read_text(encoding="utf-8")))
        self.assertEqual(set(n3), {"tripplanner", "booking", "aa_app_user"})
        limits = connection_limits(self.view)
        for role, limit in n3.items():
            self.assertEqual(limits.get(role), limit, role)
        self.assertEqual(limits.get("cis_app"), 90)

    def test_registers_rl_001(self):
        self.assertRegex(RL001.read_text(encoding="utf-8"),
                         r"INSERT INTO shared\.schema_versions \(version, applied_at, description\)\s+"
                         r"VALUES \('rl-001',")
        self.assertRegex(self.view, r"ON CONFLICT \(VERSION\) DO NOTHING")


if __name__ == "__main__":
    unittest.main()
