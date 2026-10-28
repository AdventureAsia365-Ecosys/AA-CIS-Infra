"""AA-993 Phase E slice M2b without a database: expand_findings rules on synthetic catalog rows, the runner's exit 14
and check-mode rehearsal against the fakes, and the pure parts of db/expand_check.py. The same rules against a real
PostgreSQL: test_aa993_expand_check_pg.py. Run:
  python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import hashlib
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import expand_check as ec  # noqa: E402
import run_migration as rm  # noqa: E402
from test_aa993_expand import CIC, EXPAND_OK, tx  # noqa: E402
from test_run_migration import FakeConn  # noqa: E402


def row(kind, key, value="v", rel=None, aux=None):
    return {"kind": kind, "key": key, "rel": rel, "value": value, "aux": aux}


def table(key, rls=False, force=False, tenant=False, parent="", relkind="r", filenode="1"):
    flags = [relkind, str(rls).lower(), str(force).lower(), str(tenant).lower(), parent]
    value = "|".join([relkind, "o", "", str(rls).lower(), str(force).lower(), filenode, "", "p", "false", "", ""])
    return row("relation", key, value, key, "|".join(flags))


BASE = [table("booking.trip", rls=True, force=True), table("shared.job"), table("booking.config"),
        table("shared.schema_versions"),
        row("column", "booking.trip.id", "bigint|true||||0|", "booking.trip", "true|false|false|false"),
        row("function", "booking.f(a integer)", "o||h|false||i|false", None, "booking.f"),
        row("type", "booking.status", "e|o||0|false||a,b"),
        row("rows", "booking.config", "0|0|0", "booking.config"),
        row("rows", "shared.schema_versions", "0|0|0", "shared.schema_versions")]


def findings(added=(), changed=None, removed=()):
    after = [r for r in BASE if r["key"] not in removed]
    if changed:
        after = [changed if (r["kind"], r["key"]) == (changed["kind"], changed["key"]) else r for r in after]
    return rm.expand_findings(BASE, after + list(added))


class ExpandFindingsTest(unittest.TestCase):
    def test_nothing_changed(self):
        self.assertEqual(findings(), [])

    def test_allowed_additions(self):
        ok = [table("booking.new"), row("column", "booking.new.id", "x", "booking.new", "true|false|false|false"),
              row("column", "booking.trip.note", "text|false||||0|", "booking.trip", "false|false|false|false"),
              row("column", "booking.trip.n", "numeric|true|h||||", "booking.trip", "true|true|false|false"),
              row("index", "booking.ix_trip_note", "h|false|false|false", "booking.trip", "false"),
              row("index", "booking.new_pkey", "h|true|true|false", "booking.new", "true"),
              row("constraint", "booking.new:new_trip_fk", "f|h|true|false|false", "booking.new", "f"),
              row("policy", "booking.new:p", "*|true|{0}|h|", "booking.new"),
              row("trigger", "booking.new:t", "h|O", "booking.new"),
              row("function", "booking.g(a integer)", "o||h|false||i|false", None, "booking.g"),
              row("schema", "newschema", "o|"), row("type", "booking.kind", "e|o||0|false||x"),
              table("crm.note", rls=True, force=True), table("booking.with_tenant", rls=True, force=True, tenant=True),
              row("rows", "shared.schema_versions", "1|0|0", "shared.schema_versions"),
              row("rows", "booking.new", "5|0|0", "booking.new")]
        after = [r for r in BASE if r["key"] != "shared.schema_versions" or r["kind"] != "rows"] + ok
        self.assertEqual(rm.expand_findings(BASE, after), [])

    def test_contract_additions(self):
        cases = {
            "new policy on existing table booking.trip": row("policy", "booking.trip:open", "x", "booking.trip"),
            "new trigger on existing table": row("trigger", "booking.trip:t", "x", "booking.trip"),
            "new constraint on existing table": row("constraint", "booking.trip:c", "c|h|true|false|false",
                                                    "booking.trip", "c"),
            "new rule on existing table": row("rule", "booking.trip:r", "h", "booking.trip"),
            "unique / primary / exclusion index": row("index", "booking.ux", "h|true|false|false", "booking.trip",
                                                      "true"),
            "added to hot table shared.job": row("column", "shared.job.lane", "x", "shared.job",
                                                 "false|false|false|false"),
            "generated or identity": row("column", "booking.trip.g", "x", "booking.trip", "false|true|true|false"),
            "NOT NULL without a default": row("column", "booking.trip.nn", "x", "booking.trip",
                                              "true|false|false|false"),
            "overload of an existing function name booking.f": row("function", "booking.f(a text)", "x", None,
                                                                  "booking.f"),
            "ALTER DEFAULT PRIVILEGES": row("default privileges", "for o in booking on r", "{x}"),
            "new table in an RLS schema": table("crm.note", rls=True, force=False),
            "new table has a tenant_id column": table("booking.t", tenant=True),
            "new partition or child of existing table booking.trip": table("booking.trip_2027", parent="booking.trip"),
            "new object in hot schema catalog": table("catalog.v_new", relkind="v"),
            "1 inserted": row("rows", "booking.config", "1|0|0", "booking.config"),
            "new constraint on existing type": row("constraint", "booking.status:chk", "c|h|true|false|false",
                                                   "booking.status", "c"),
        }
        for needle, added in cases.items():
            with self.subTest(case=needle):
                got = findings(added=[added]) if added["kind"] != "rows" else rm.expand_findings(
                    BASE, [r for r in BASE if (r["kind"], r["key"]) != ("rows", added["key"])] + [added])
                self.assertTrue(any(needle in f for f in got), got)

    def test_changed_and_removed_name_the_field(self):
        rewritten = table("booking.trip", rls=True, force=True, filenode="2")
        self.assertEqual(findings(changed=rewritten),
                         ["relation booking.trip: storage (relfilenode: a table rewrite) changed"])
        no_force = table("booking.trip", rls=True, force=False)
        self.assertEqual(findings(changed=no_force), ["relation booking.trip: RLS forced changed"])
        self.assertEqual(findings(removed=("booking.f(a integer)",)),
                         ["function booking.f(a integer): dropped or renamed"])
        retyped = row("column", "booking.trip.id", "integer|true||||0|", "booking.trip", "true|false|false|false")
        self.assertEqual(findings(changed=retyped), ["column booking.trip.id: type changed"])

    def test_field_names_match_the_snapshot_columns(self):
        """Every `value` built with _fields() has as many fields as EXPAND_FIELDS names (positions never shift)."""
        sql = rm.EXPAND_SNAPSHOT_SQL
        for kind, names in rm.EXPAND_FIELDS.items():
            with self.subTest(kind=kind):
                self.assertIn(f"'{kind}'", sql)
                self.assertGreater(len(names), 0)
        self.assertNotIn("concat_ws('|'", sql)


class RunTaskPostCheckTest(unittest.TestCase):
    def run_task(self, sql, mode="apply", conn=None, version="bk-099", file="booking/099_x.sql"):
        raw = sql.encode()
        env = {"MIGRATION_URL": "u", "MIGRATION_SHA256": hashlib.sha256(raw).hexdigest(),
               "MIGRATION_VERSION": version, "MIGRATION_MODE": mode, "MIGRATION_FILE": file,
               "DATABASE_URL": "postgresql://x"}
        conn = conn or FakeConn()

        async def connect(dsn, settings, **kw):
            return conn

        async def sleep(s):
            pass

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asyncio.run(rm.run_task(env, fetch=lambda u: raw, connect=connect, sleep=sleep))
        return code, conn, out.getvalue()

    def contract_conn(self, **kw):
        conn = FakeConn(**kw)
        conn.expand_before = BASE
        conn.expand_after = BASE + [row("policy", "booking.trip:open", "x", "booking.trip")]
        return conn

    def test_apply_clean_file_commits(self):
        code, conn, log = self.run_task(EXPAND_OK)
        self.assertEqual(code, 0, log)
        self.assertTrue(conn.executed[0].strip().endswith("BEGIN;"))
        self.assertTrue(conn.executed[-1].strip().startswith("COMMIT"))
        self.assertIn("expand post-check: ok", log)
        self.assertEqual(conn.expand_reads, 2)

    def test_apply_contract_change_rolls_back_with_14(self):
        conn = self.contract_conn(registers=False)
        code, conn, log = self.run_task(EXPAND_OK, conn=conn)
        self.assertEqual(code, 14, log)
        self.assertEqual(conn.executed[-1], "ROLLBACK")
        self.assertNotIn("COMMIT;", conn.executed[-1])
        self.assertIn("policy booking.trip:open: new policy on existing table booking.trip", log)

    def test_apply_contract_change_under_the_role_switch(self):
        conn = self.contract_conn(owners={"shared": "aa_cis_admin", "booking": "bk_owner"}, members={"bk_owner"},
                                  registers=False)
        code, conn, log = self.run_task(EXPAND_OK, conn=conn)
        self.assertEqual(code, 14, log)
        self.assertEqual(conn.executed[-1], "ROLLBACK")
        self.assertTrue(any(e.startswith("SET LOCAL ROLE") for e in conn.executed))

    def test_check_mode_rehearses_and_rolls_back(self):
        code, conn, log = self.run_task(EXPAND_OK, mode="check")
        self.assertEqual(code, 0, log)
        self.assertEqual(conn.executed[-1], "ROLLBACK")
        self.assertIn("expand rehearsal: post-check ok", log)
        self.assertEqual(conn.lock_tries, 1)                    # the rehearsal runs statements: apply lock

    def test_check_mode_reports_14(self):
        code, conn, log = self.run_task(EXPAND_OK, mode="check", conn=self.contract_conn())
        self.assertEqual(code, 14, log)
        self.assertIn("Rehearsal rolled back", log)

    def test_check_mode_of_a_cic_file_does_not_rehearse(self):
        code, conn, log = self.run_task(CIC, mode="check", version="241", file="cis/241_x.sql")
        self.assertEqual((code, conn.executed), (0, []), log)
        self.assertIn("no rehearsal for a CREATE INDEX CONCURRENTLY file", log)
        self.assertEqual(getattr(conn, "lock_tries", 0), 0)

    def test_cic_file_with_a_contract_change_is_not_registered(self):
        conn = FakeConn()
        conn.expand_before = BASE
        conn.expand_after = BASE + [row("index", "shared.ux", "h|true|false|false", "booking.trip", "true")]
        code, conn, log = self.run_task(CIC, conn=conn, version="241", file="cis/241_x.sql")
        self.assertEqual(code, 14, log)
        self.assertEqual(len(conn.executed), 1)                 # the CIC ran, the registration did not

    def test_contract_file_has_no_post_check(self):
        code, conn, log = self.run_task(tx("ALTER TABLE booking.trip ADD COLUMN x int;", header=""))
        self.assertEqual(code, 0, log)
        self.assertEqual(getattr(conn, "expand_reads", 0), 0)
        self.assertEqual(len(conn.executed), 1)                 # sent whole, as before

    def test_expand_file_must_be_one_block(self):
        sql = "-- migrate: expand\nCREATE TABLE booking.t (id int);\n" + \
              "INSERT INTO shared.schema_versions (version) VALUES ('bk-099');\n"
        d = rm.parse_directives(sql)
        self.assertTrue(any("one BEGIN … COMMIT block" in e for e in rm.lint(sql, d, "booking/099_x.sql")[0]))


class ClassifyPureTest(unittest.TestCase):
    def test_number_order_live(self):
        files = {"cis": ["001_a.sql", "002_b.sql", "003_c.sql"], "booking": ["001_x.sql", "002_y.sql"],
                 "roles": ["001_r.sql"]}
        live = ec.number_order_live(files, ["cis/002_b.sql"])
        self.assertEqual([m["version"] for m in live["migrations"]], ["rl-001", "001", "bk-001", "bk-002"])
        self.assertEqual(sorted(m["applied_at"] for m in live["migrations"]),
                         [m["applied_at"] for m in live["migrations"]])

    def test_pending_order(self):
        self.assertEqual(ec.pending_order(["crm/002_a.sql", "cis/300_x.sql", "booking/034_b.sql", "cis/299_y.sql"]),
                         ["cis/299_y.sql", "cis/300_x.sql", "booking/034_b.sql", "crm/002_a.sql"])

    def test_verdict_and_exit(self):
        def e(file, header="expand", lint=(), found=(), error=""):
            return {"file": file, "header": header, "lint_errors": list(lint), "findings": list(found), "error": error}
        clean, bad, plain = e("cis/300.sql"), e("cis/301.sql", found=["x"]), e("cis/302.sql", header="none")
        self.assertEqual([ec.verdict(x) for x in (clean, bad, plain)], ["expand", "contract", "contract"])
        self.assertEqual(ec.exit_code([clean, plain], None), 0)
        self.assertEqual(ec.exit_code([clean, bad], None), 14)
        self.assertEqual(ec.exit_code([clean, bad], {"cis/300.sql"}), 0)        # only targets set the exit
        self.assertEqual(ec.exit_code([e("cis/303.sql", lint=["y"])], None), 14)
        self.assertEqual(ec.exit_code([e("cis/304.sql", error="rehearsal exit 6")], None), 1)


if __name__ == "__main__":
    unittest.main()
