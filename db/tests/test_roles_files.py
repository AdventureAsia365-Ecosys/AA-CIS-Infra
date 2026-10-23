"""Static checks of the Infra-native role bootstrap files, db/migrations/roles/ (X1 plan S3, MIG-6, DM-8.1).

They run as the RDS master, so review is the only gate besides these checks:
  * no password in git, ever (SEC-2): passwords are written in the Console and set by DB Migrate
    mode=set-password (X1 S17/S20);
  * no SUPERUSER / BYPASSRLS / REPLICATION granted (only the NO… forms);
  * memberships scoped by grantee (X1 plan §1.4: a policy TO r also applies to the members of r;
    lesson S236; X1 review S241): aa_app_user is granted to no role at all, catalog_owner only to
    db_migrator (the S22 login, which needs it for the catalog recipe: SET ROLE checks the session
    user). Never to the master, cis_owner, cis_app, booking, tripplanner or any *_owner role;
  * db_migrator's memberships equal db/owners.yaml migrator_member_of, which covers every owner role
    and every set_local_roles target (the roles a file can be switched to after S22);
  * rl-001 creates exactly the roles S3 lists, and restates the N3 limits with the values of CIS 234;
  * rl-002 creates exactly the roles S20 lists (cis_owner NOLOGIN, db_migrator LOGIN NOCREATEROLE limit 5),
    grants exactly the S20 memberships, and its guard's membership list equals migrator_member_of.

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
RL002 = ROLES / "002_x1_cis_owner_db_migrator.sql"
CIS234 = ROOT / "db" / "migrations" / "cis" / "234_connection_limits_pg_stat_statements.sql"
# Granted role -> the only grantees allowed in a roles/ file (X1 plan §1.4, review S241). aa_app_user:
# nobody (the tenant pool's policies would reach the member). catalog_owner: only db_migrator, whose
# query results are never tenant evidence (the probe uses each runtime role's own login).
MEMBERSHIP_GRANTEES = {"AA_APP_USER": frozenset(), "CATALOG_OWNER": frozenset({"DB_MIGRATOR"})}
MEMBERSHIP_RE = re.compile(r"\bGRANT\b(?P<roles>[^;]*?)\bTO\b(?P<to>[^;]*)")
# X1 plan S20: rl-002's membership line (kept here so the plan and the registry cannot drift apart).
PLANNED_RL002 = """BEGIN;
CREATE ROLE db_migrator LOGIN NOCREATEROLE NOCREATEDB NOBYPASSRLS CONNECTION LIMIT 5;
GRANT bk_owner, tp_owner, cis_owner, catalog_owner, cis_app TO db_migrator;
GRANT pg_read_all_stats TO db_migrator;
COMMIT;
"""


def code_view(sql: str) -> str:
    """Comments dropped, string literals replaced by '#<n>', DO bodies lexed as code, upper case."""
    return rm._role_view(sql, [])


def statements(view: str) -> list:
    return [s.strip() for s in view.split(";") if s.strip()]


def membership_grants(view: str) -> list:
    """GRANT r[, …] TO x statements (role membership: no ON clause)."""
    return [s for s in statements(view) if re.match(r"^GRANT\b", s) and not re.search(r"\bON\b", s)]


def memberships(view: str) -> list:
    """[(granted roles, grantees)] of every membership GRANT (no ON clause) in a code view, DO blocks
    included (the lexer reads their bodies as code); WITH … / GRANTED BY … options dropped."""
    out = []
    for m in MEMBERSHIP_RE.finditer(view):
        if re.search(r"\bON\b", m.group("roles")) or view[max(0, m.start() - 5):m.start()].rstrip().endswith("WITH"):
            continue
        to = re.split(r"\b(?:WITH|GRANTED)\b", m.group("to"), maxsplit=1)[0]
        out.append(([r.strip() for r in m.group("roles").split(",") if r.strip()],
                    [g.strip() for g in to.split(",") if g.strip()]))
    return out


def membership_violations(view: str) -> list:
    bad = []
    for granted, grantees in memberships(view):
        for role in granted:
            allowed = MEMBERSHIP_GRANTEES.get(role)
            if allowed is None:
                continue
            for g in grantees:
                if g not in allowed:
                    bad.append(f"GRANT {role} TO {g}")
    return bad


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

    def test_memberships_scoped_by_grantee(self):
        for f in self.files():
            with self.subTest(file=f.name):
                self.assertEqual(membership_violations(code_view(f.read_text(encoding="utf-8"))), [])


class MembershipRuleTest(unittest.TestCase):
    """The grantee-scoped rule itself (X1 review S241: the planned rl-002 must pass, the S236 cases fail)."""

    def test_planned_rl002_passes(self):
        self.assertEqual(membership_violations(code_view(PLANNED_RL002)), [])

    def test_forbidden_grantees(self):
        cases = {
            "GRANT catalog_owner TO aa_cis_admin;": ["GRANT CATALOG_OWNER TO AA_CIS_ADMIN"],
            "GRANT catalog_owner TO CURRENT_USER;": ["GRANT CATALOG_OWNER TO CURRENT_USER"],
            "GRANT cis_owner, catalog_owner TO tp_owner;": ["GRANT CATALOG_OWNER TO TP_OWNER"],
            "GRANT catalog_owner TO cis_app WITH ADMIN OPTION;": ["GRANT CATALOG_OWNER TO CIS_APP"],
            "GRANT catalog_owner TO db_migrator, cis_owner;": ["GRANT CATALOG_OWNER TO CIS_OWNER"],
            "GRANT aa_app_user TO db_migrator;": ["GRANT AA_APP_USER TO DB_MIGRATOR"],
            "GRANT aa_app_user TO booking GRANTED BY aa_cis_admin;": ["GRANT AA_APP_USER TO BOOKING"],
            "DO $$ BEGIN IF true THEN GRANT catalog_owner TO tripplanner; END IF; END $$;":
                ["GRANT CATALOG_OWNER TO TRIPPLANNER"],
        }
        for sql, expected in cases.items():
            with self.subTest(sql=sql):
                self.assertEqual(membership_violations(code_view(sql)), expected)

    def test_object_grants_are_not_memberships(self):
        sql = ("GRANT SELECT ON catalog.v_tour TO catalog_owner;\nGRANT USAGE ON SCHEMA catalog TO aa_app_user;\n"
               "GRANT SELECT ON ALL TABLES IN SCHEMA shared TO cis_app WITH GRANT OPTION;")
        self.assertEqual(memberships(code_view(sql)), [])


try:
    import yaml
except ImportError:                                  # optional outside CI (owners.yaml needs PyYAML)
    yaml = None


@unittest.skipIf(yaml is None, "PyYAML is not installed: migrator registry checks skipped")
class MigratorMembershipTest(unittest.TestCase):
    """db_migrator (X1 S20/S22) must reach every role a file can be switched to (X1 review S241):
    SET ROLE checks the session user, so a missing membership is 42501 at apply."""

    @classmethod
    def setUpClass(cls):
        cls.reg = yaml.safe_load((ROOT / "db" / "owners.yaml").read_text(encoding="utf-8"))
        cls.members = set(cls.reg["migrator_member_of"])
        cls.schema_owners = {k: v for k, v in cls.reg["owners"].items() if not v.get("native")}

    def test_registry_covers_every_switch_target(self):
        self.assertEqual(self.reg["migrator_role"], "db_migrator")
        self.assertEqual(self.reg["migrator_member_of"], sorted(self.members))
        for name, o in self.schema_owners.items():
            with self.subTest(owner=name):
                self.assertIn(o["owner_role"], self.members)
                self.assertLessEqual(set(o["set_local_roles"]), self.members)
        self.assertIn("pg_read_all_stats", self.members)
        # Never the tenant pool, the master or the bypass roles (X1 plan §1.4, SEC-1).
        self.assertFalse(self.members & {"aa_app_user", self.reg["master_role"], "rds_superuser",
                                         "pg_read_all_data", "pg_write_all_data"})

    def test_planned_rl002_grants_are_in_the_registry(self):
        # rl-002 is applied history: a later roles/ file (a new owner's bootstrap, AA-826) extends migrator_member_of
        # and leaves rl-002 as is. The union of every roles/ file must equal the registry (test below).
        granted = {r.lower() for roles, to in memberships(code_view(PLANNED_RL002)) if to == ["DB_MIGRATOR"]
                   for r in roles}
        self.assertLessEqual(granted, self.members)

    def test_roles_files_grant_db_migrator_exactly_the_registry(self):
        views = [code_view(f.read_text(encoding="utf-8")) for f in sorted(ROLES.glob("*.sql"))]
        created = any(re.search(r"\bCREATE ROLE DB_MIGRATOR\b", v) for v in views)
        granted = {r.lower() for v in views for roles, to in memberships(v) if "DB_MIGRATOR" in to for r in roles}
        self.assertTrue(created, "no roles/ file creates db_migrator (rl-002, X1 S20)")
        self.assertEqual(granted, self.members)

    def test_rl002_guard_list_is_its_own_grants(self):
        # The guard compares db_migrator's direct memberships with a literal array (sorted, COLLATE "C"): it must
        # list exactly what rl-002 grants (a later roles/ file that extends migrator_member_of leaves rl-002 as is;
        # the test above checks the union of all files against the registry).
        m = re.search(r"expected\s+text\[\]\s*:=\s*ARRAY\[([^\]]*)\]", RL002.read_text(encoding="utf-8"))
        self.assertIsNotNone(m, "rl-002 guard: `expected text[] := ARRAY[...]` not found")
        listed = [s.strip().strip("'") for s in m.group(1).split(",")]
        granted = {r.lower() for roles, to in memberships(code_view(RL002.read_text(encoding="utf-8")))
                   if "DB_MIGRATOR" in to for r in roles}
        self.assertEqual(listed, sorted(granted))


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


class Rl002Test(unittest.TestCase):
    """X1 plan S20: cis_owner + db_migrator, no password, no object ownership."""
    view = code_view(RL002.read_text(encoding="utf-8"))

    def test_creates_the_s20_roles(self):
        self.assertRegex(self.view, r"\bCREATE ROLE CIS_OWNER NOLOGIN;")
        self.assertRegex(self.view, r"\bCREATE ROLE DB_MIGRATOR LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS "
                                    r"CONNECTION LIMIT 5;")
        self.assertEqual(re.findall(r"\bCREATE ROLE (\w+)", self.view), ["CIS_OWNER", "DB_MIGRATOR"])
        self.assertRegex(self.view, r"\bALTER ROLE CIS_OWNER NOLOGIN;")
        self.assertNotRegex(self.view, r"\bNOINHERIT\b")              # review A1: db_migrator stays INHERIT

    def test_memberships(self):
        self.assertEqual(membership_grants(self.view), [
            "GRANT CIS_OWNER TO AA_CIS_ADMIN",
            "GRANT BK_OWNER, TP_OWNER, CIS_OWNER, CATALOG_OWNER, CIS_APP TO DB_MIGRATOR",
            "GRANT PG_READ_ALL_STATS TO DB_MIGRATOR",
        ])
        # Same membership lines as the plan text kept above (PLANNED_RL002).
        self.assertEqual(membership_grants(code_view(PLANNED_RL002)), membership_grants(self.view)[1:])

    def test_create_on_database_only_to_cis_owner(self):
        object_grants = [s for s in statements(self.view) if re.match(r"^GRANT\b", s) and re.search(r"\bON\b", s)]
        self.assertEqual(object_grants, ["GRANT CREATE ON DATABASE AA_CIS_DEV TO CIS_OWNER"])

    def test_connection_limit(self):
        self.assertEqual(connection_limits(self.view), {"db_migrator": 5})

    def test_owns_nothing_and_no_default_privileges(self):
        # Ownership and default privileges FOR ROLE cis_owner come with CIS 245 (S21), not here.
        self.assertNotRegex(self.view, r"\bOWNER TO\b|\bAUTHORIZATION\b|\bALTER DEFAULT PRIVILEGES\b")

    def test_registers_rl_002(self):
        self.assertRegex(RL002.read_text(encoding="utf-8"),
                         r"INSERT INTO shared\.schema_versions \(version, applied_at, description\)\s+"
                         r"VALUES \('rl-002',")
        self.assertRegex(self.view, r"ON CONFLICT \(VERSION\) DO NOTHING")


RL003 = ROLES / "003_crm_roles.sql"
RL004 = ROLES / "004_crm_nologin_roles.sql"
CRM_READERS = ["CRM_AI_READER", "CRM_INSIGHTS", "CRM_SUPPORT_READER", "CRM_ERASER"]


class Rl003Test(unittest.TestCase):
    """AA-932: the partner CRM's role bootstrap is the template, rendered with the owners.yaml values (ADR 0008
    playbook step 3) and the C2.2 connection limit (crm_app 6, data standards v1.3)."""

    def test_is_the_rendered_template(self):
        sys.path.insert(0, str(ROOT / "db" / "templates"))
        import render_new_owner_roles as tmpl
        expected = tmpl.render("003", "crm", "crm_owner", "crm_app", "crm", "crm-", 6, "AA-932")
        self.assertEqual(RL003.read_text(encoding="utf-8"), expected)

    def test_limits_and_memberships(self):
        view = code_view(RL003.read_text(encoding="utf-8"))
        self.assertEqual(connection_limits(view), {"crm_app": 6})
        self.assertEqual(membership_grants(view), ["GRANT CRM_OWNER TO AA_CIS_ADMIN", "GRANT CRM_OWNER TO DB_MIGRATOR"])


class Rl004Test(unittest.TestCase):
    """AA-932: the CRM NOLOGIN roles (design v3 §3.1), granted to crm_app only; crm_app NOINHERIT."""
    view = code_view(RL004.read_text(encoding="utf-8"))

    def test_readers_are_nologin_and_granted_to_crm_app_only(self):
        for r in CRM_READERS:
            self.assertRegex(self.view, rf"\bALTER ROLE {r} NOLOGIN;")
        self.assertEqual(membership_grants(self.view), [f"GRANT {', '.join(CRM_READERS)} TO CRM_APP"])
        self.assertRegex(self.view, r"\bALTER ROLE CRM_APP NOINHERIT;")

    def test_no_object_grant_no_limit_change(self):
        self.assertEqual([s for s in statements(self.view) if re.match(r"^GRANT\b", s) and re.search(r"\bON\b", s)],
                         [])
        self.assertEqual(connection_limits(self.view), {})
        self.assertNotRegex(self.view, r"\bOWNER TO\b|\bAUTHORIZATION\b|\bALTER DEFAULT PRIVILEGES\b")

    def test_registers_rl_004(self):
        self.assertRegex(RL004.read_text(encoding="utf-8"),
                         r"INSERT INTO shared\.schema_versions \(version, applied_at, description\)\s+"
                         r"VALUES \('rl-004',")


if __name__ == "__main__":
    unittest.main()
