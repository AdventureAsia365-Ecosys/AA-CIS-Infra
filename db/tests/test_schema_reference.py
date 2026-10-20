"""Unit tests for db/schema_dump.py (assembly only, no DB) and db/gen_schema_reference.py (AA-807 N1).

Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import copy
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gen_schema_reference as gen  # noqa: E402
import schema_dump as sd  # noqa: E402

SCHEMAS = [{"schema": "booking", "owner": "aa_cis_admin"}, {"schema": "catalog", "owner": "aa_cis_admin"},
           {"schema": "empty_one", "owner": "aa_cis_admin"}, {"schema": "shared", "owner": "aa_cis_admin"}]


def rows():
    return {
        "database": [{"name": "aa_cis_dev", "server_version": "15.17", "size_bytes": 900_000_000,
                      "max_connections": 87, "stats_reset": None}],
        "schema_grants": [{"schema": "catalog", "grantee": "booking", "privileges": "USAGE"}],
        "relations": [
            {"schema": "shared", "name": "job", "kind": "r", "owner": "aa_cis_admin", "est_rows": 428,
             "rls": True, "rls_forced": False, "is_partition": False,
             "total_bytes": 81920, "table_bytes": 49152, "index_bytes": 32768},
            {"schema": "booking", "name": "legs", "kind": "r", "owner": "aa_cis_admin", "est_rows": -1,
             "rls": False, "rls_forced": False, "is_partition": False,
             "total_bytes": 0, "table_bytes": 0, "index_bytes": 0},
            {"schema": "catalog", "name": "v_tour", "kind": "v", "owner": "catalog_owner", "est_rows": 0,
             "rls": False, "rls_forced": False, "is_partition": False,
             "total_bytes": None, "table_bytes": None, "index_bytes": None},
        ],
        "columns": [
            {"schema": "shared", "name": "job", "column": "id", "type": "bigint", "not_null": True},
            {"schema": "shared", "name": "job", "column": "status", "type": "shared.job_status", "not_null": True},
            {"schema": "booking", "name": "legs", "column": "a", "type": "integer", "not_null": False},
            {"schema": "catalog", "name": "v_tour", "column": "name", "type": "character varying(64)", "not_null": False},
            {"schema": "public", "name": "spatial_ref_sys", "column": "srid", "type": "integer", "not_null": True},
        ],
        "indexes": [
            {"schema": "shared", "name": "job", "index": "job_pkey",
             "definition": "CREATE UNIQUE INDEX job_pkey ON shared.job USING btree (id)",
             "is_primary": True, "is_unique": True, "is_valid": True, "bytes": 16384, "scans": 12},
            {"schema": "shared", "name": "job", "index": "job_status_idx",
             "definition": "CREATE INDEX job_status_idx ON shared.job USING btree (status)",
             "is_primary": False, "is_unique": False, "is_valid": False, "bytes": 8192, "scans": 0},
        ],
        "constraints": [
            {"schema": "booking", "name": "legs", "constraint": "legs_a_fkey", "type": "f",
             "definition": "FOREIGN KEY (a, b) REFERENCES booking.trip_cases(a, b) NOT VALID", "validated": False,
             "ref_schema": "booking", "ref_name": "trip_cases", "columns": "a,b", "ref_columns": "a,b"},
            {"schema": "shared", "name": "job", "constraint": "job_kind_check", "type": "c",
             "definition": "CHECK ((kind ~ '^[a-z]'::text))", "validated": True,
             "ref_schema": None, "ref_name": None, "columns": "kind", "ref_columns": None},
        ],
        "policies": [{"schema": "shared", "name": "job", "policy": "job_tenant", "permissive": "PERMISSIVE",
                      "roles": ["aa_app_user"], "cmd": "SELECT", "qual": "(tenant_id = x)", "with_check": None}],
        "table_grants": [{"schema": "catalog", "name": "v_tour", "grantee": "booking", "privileges": "SELECT*"}],
        "column_grants": [
            {"schema": "shared", "name": "job", "column": "status", "grantee": "booking", "privileges": "SELECT"},
            {"schema": "shared", "name": "job", "column": "id", "grantee": "booking", "privileges": "SELECT"},
        ],
        "triggers": [{"schema": "booking", "name": "legs", "trigger": "legs_touch", "enabled": "O",
                      "definition": "CREATE TRIGGER legs_touch BEFORE UPDATE ON booking.legs FOR EACH ROW "
                                    "EXECUTE FUNCTION booking.touch()"}],
        "functions": [{"schema": "booking", "name": "touch", "args": "", "result": "trigger", "kind": "f",
                       "language": "plpgsql", "owner": "aa_cis_admin", "security_definer": True}],
        "default_privileges": [{"role": "aa_cis_admin", "schema": "shared", "object_type": "r",
                                "grantee": "aa_app_user", "privileges": "SELECT"}],
        "roles": [{"role": "aa_app_user", "login": True, "superuser": False, "inherit": True, "createrole": False,
                   "createdb": False, "bypassrls": False, "connection_limit": 15,
                   "config": ["statement_timeout=30s", "custom.api_key=shh"]}],
        "role_members": [{"role": "booking", "member": "aa_app_user", "admin_option": False}],
        "extensions": [{"name": "vector", "version": "0.8.0", "schema": "public"}],
        "enums": [{"schema": "shared", "name": "job_status", "labels": ["queued", "done, really"]}],
        "activity": [{"schema": "shared", "name": "job", "seq_scan": 3, "seq_tup_read": 9, "idx_scan": 40,
                      "n_tup_ins": 5, "n_tup_upd": 2, "n_tup_del": 1, "n_live_tup": 428, "n_dead_tup": 7,
                      "last_vacuum": None, "last_autovacuum": "2026-10-15 01:02:03+00:00",
                      "last_analyze": None, "last_autoanalyze": None}],
        "connections": [{"application_name": "(empty)", "role": "aa_cis_admin", "state": "idle", "sessions": 4}],
        "migrations": [
            {"version": "bk-009", "applied_at": "2026-10-15 04:28:06+00:00", "description": "trip plans"},
            {"version": "231", "applied_at": "2026-10-15 04:29:28+00:00", "description": "label | piece"},
            {"version": "007b", "applied_at": "2026-01-01 00:00:00+00:00", "description": "old"},
            {"version": "tp-010", "applied_at": "2026-10-14 10:13:49+00:00", "description": "tp"},
        ],
    }


CHECK = sd.SOFT_KEY_CHECKS[0]


def soft():
    return [sd.soft_key_result(CHECK, "ok", {"total": 10, "without_key": 2, "orphans": 1}),
            sd.soft_key_result(dict(CHECK, name="a | b"), "not_applicable")]


def dump():
    return sd.build_dump(SCHEMAS, rows(), "2026-10-15T05:00:00+00:00", soft())


class FakeConn:
    """Answers SOFT_KEY_READY_SQL with `ready` and every check SQL with `counts`; records the SQL it was given."""

    def __init__(self, ready, counts=None):
        self.ready, self.counts, self.sql = ready, counts, []

    async def fetchrow(self, sql, *args):
        self.sql.append(sql)
        return self.ready if sql == sd.SOFT_KEY_READY_SQL else self.counts


class BuildDumpTest(unittest.TestCase):
    def test_shape(self):
        d = dump()
        self.assertEqual(d["format"], 2)
        job = d["relations"]["shared"]["job"]
        self.assertEqual(job["kind"], "table")
        self.assertEqual(job["size"], {"total": 81920, "table": 49152, "index": 32768})
        self.assertTrue(job["rls"])
        self.assertEqual([c["name"] for c in job["columns"]], ["id", "status"])
        self.assertEqual(len(job["indexes"]), 2)
        self.assertEqual(job["activity"]["n_dead_tup"], 7)
        self.assertNotIn("schema", job["policies"][0])
        view = d["relations"]["catalog"]["v_tour"]
        self.assertIsNone(view["est_rows"])
        self.assertIsNone(view["size"])
        self.assertEqual(d["relations"]["empty_one"], {})
        self.assertNotIn("public", d["relations"])          # columns of unlisted relations are dropped
        self.assertEqual(d["schemas"][1]["grants"], [{"grantee": "booking", "privileges": "USAGE"}])

    def test_latest_per_owner_skips_legacy_keys(self):
        self.assertEqual(dump()["migrations_latest_per_owner"],
                         {"cis": "231", "tripplanner": "tp-010", "booking": "bk-009"})

    def test_role_config_keeps_only_allowed_keys(self):
        self.assertEqual(dump()["roles"][0]["config"], {"statement_timeout": "30s"})
        self.assertEqual(sd.role_config(None), {})

    def test_soft_key_result_rate_is_over_keyed_rows(self):
        ok, na = soft()
        self.assertEqual((ok["status"], ok["total"], ok["without_key"], ok["orphans"], ok["orphan_rate"]),
                         ("ok", 10, 2, 1, 0.125))
        self.assertEqual((na["status"], na["total"], na["orphan_rate"]), ("not_applicable", None, None))
        none_keyed = sd.soft_key_result(CHECK, "ok", {"total": 3, "without_key": 3, "orphans": 0})
        self.assertEqual(none_keyed["orphan_rate"], 0.0)
        self.assertEqual(dump()["soft_keys"][0]["name"], CHECK["name"])
        self.assertEqual(sd.build_dump(SCHEMAS, rows(), "x")["soft_keys"], [])

    def test_soft_keys_run_only_when_ready(self):
        counts = {"total": 8, "without_key": 0, "orphans": 0}
        for ready, status, ran in (
            ({"present": True, "columns": True, "readable": True}, "ok", True),
            ({"present": True, "columns": False, "readable": True}, "not_applicable", False),
            ({"present": False, "columns": False, "readable": None}, "not_applicable", False),
            ({"present": True, "columns": True, "readable": False}, "no_privilege", False),
        ):
            with self.subTest(status=status, ready=ready):
                conn = FakeConn(ready, counts)
                (row,) = asyncio.run(sd.soft_keys(conn))
                self.assertEqual(row["status"], status)
                self.assertEqual(CHECK["sql"] in conn.sql, ran)
                self.assertEqual(row["total"], 8 if ran else None)

    def test_soft_key_checks_name_their_table_and_target(self):
        for check in sd.SOFT_KEY_CHECKS:
            self.assertIn(f"FROM {check['table']} ", check["sql"])
            self.assertIn(f"FROM {check['target']} ", check["sql"])
            self.assertLessEqual({"name", "table", "columns", "target", "target_columns", "sql"}, set(check))

    def test_every_query_is_read_only(self):
        for name, sql in (list(sd.QUERIES.items()) + [("schemas", sd.SCHEMAS_SQL), ("ready", sd.SOFT_KEY_READY_SQL)]
                          + [(c["name"], c["sql"]) for c in sd.SOFT_KEY_CHECKS]):
            with self.subTest(query=name):
                self.assertTrue(sql.lstrip().upper().startswith("SELECT"), name)
        self.assertEqual(sd.SESSION_SETTINGS["default_transaction_read_only"], "on")


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.d = dump()
        self.md = gen.render(self.d, source="https://example/run/1")

    def test_header_and_compat_headings(self):
        md = self.md
        self.assertIn("**Verified:** 2026-10-15 05:00 UTC", md)
        self.assertIn("CIS **231**, TripPlanner **tp-010**, Booking **bk-009**", md)
        self.assertIn("## `shared` (1 objects)", md)
        self.assertIn("### `shared.job` (table, ~428 rows, 80 kB)", md)
        self.assertIn("### `booking.legs` (table, 0 B)", md)       # reltuples -1: no row estimate
        self.assertIn("### `catalog.v_tour` (VIEW)", md)
        self.assertIn("id bigint NN\nstatus shared.job_status NN\n", md)
        self.assertNotIn("## `empty_one`", md)
        self.assertIn("1 empty: empty_one", md)

    def test_security_details(self):
        md = self.md
        self.assertIn("- owner `aa_cis_admin` · RLS on\n", md)
        self.assertIn("- policy `job_tenant` (PERMISSIVE SELECT TO aa_app_user): USING `(tenant_id = x)`", md)
        self.assertIn("- grant `booking`: SELECT*", md)
        self.assertIn("- column grant `booking`: SELECT (id, status)", md)
        self.assertIn("| `aa_app_user` | yes | no | no | 15 | statement_timeout=30s | booking |", md)
        self.assertNotIn("shh", md)
        self.assertIn("| `aa_cis_admin` | shared | tables | `aa_app_user` | SELECT |", md)
        self.assertIn("| `booking.touch()` | trigger | plpgsql | `aa_cis_admin` | **yes** |", md)

    def test_indexes_constraints_and_fks(self):
        md = self.md
        self.assertIn("- index `job_pkey` PRIMARY KEY: UNIQUE btree (id)", md)
        self.assertIn("- index `job_status_idx`: btree (status) **INVALID**", md)
        self.assertIn("- check `job_kind_check`: CHECK ((kind ~ '^[a-z]'::text))", md)
        self.assertIn("booking.legs.(a,b) -> booking.trip_cases.(a,b)  NOT VALID", md)
        self.assertIn("- trigger `legs_touch`: BEFORE UPDATE ON booking.legs", md)
        self.assertIn("- `shared.job_status_idx` on `job` (8 kB)", md)
        self.assertIn("- `shared.job_status`: 'queued', 'done, really'", md)

    def test_tables_escape_pipes(self):
        self.assertIn("| 231 | 2026-10-15 04:29:28+00:00 | label \\| piece |", self.md)
        self.assertIn("| (empty) | aa_cis_admin | idle | 4 |", self.md)

    def test_soft_key_section(self):
        md = self.md
        self.assertIn("## Soft-key orphans (DM-4.2)", md)
        self.assertIn(f"| {CHECK['name']} | ok | 10 | 2 | 1 | 12.50% |", md)
        self.assertIn("| a \\| b | not_applicable |  |  |  |  |", md)
        empty = gen.render(sd.build_dump(SCHEMAS, rows(), "2026-10-15T05:00:00+00:00"))
        self.assertIn("| none | | | | | |", empty)

    def test_render_is_deterministic(self):
        self.assertEqual(self.md, gen.render(json.loads(json.dumps(self.d)), source="https://example/run/1"))


class RlsGuardSectionTest(unittest.TestCase):
    """X2 RLS catalogue guard (db/rls_catalogue_rules.py) in the rendered file and the --rls-guard CLI mode."""

    # One seeded violation per rule, on top of the test dump: (rule, mutation, key in the report).
    SEEDS = (
        ("a", lambda d: d["relations"]["shared"]["job"]["columns"].append(
            {"name": "tenant_id", "type": "uuid", "not_null": True}), "shared.job"),
        ("b", lambda d: d["relations"]["shared"]["job"]["policies"].append(
            {"policy": "open", "permissive": "PERMISSIVE", "roles": ["public"], "cmd": "ALL", "qual": "(id > 0)",
             "with_check": None}), "shared.job:open"),
        ("c", lambda d: d["relations"]["shared"]["job"]["policies"].append(
            {"policy": "old", "permissive": "PERMISSIVE", "roles": ["aa_app_user"], "cmd": "ALL",
             "qual": "((x)::text = current_setting('app.current_tenant'::text, true))", "with_check": None}),
         "shared.job:old"),
        ("d", lambda d: d["relations"]["shared"]["job"]["policies"].append(
            {"policy": "cast", "permissive": "PERMISSIVE", "roles": ["aa_app_user"], "cmd": "ALL",
             "qual": "(x = (current_setting('app.tenant_id'::text, true))::uuid)", "with_check": None}),
         "shared.job:cast"),
        ("e", lambda d: d["relations"]["booking"]["legs"]["constraints"].append(
            {"constraint": "legs_job_fkey", "type": "f", "definition": "FOREIGN KEY (a) REFERENCES shared.job(id)",
             "validated": True, "ref_schema": "shared", "ref_name": "job", "columns": "a", "ref_columns": "id"}),
         "booking.legs:legs_job_fkey->shared.job"),
        ("p", lambda d: d["relations"]["shared"]["job"]["grants"].append(
            {"grantee": "PUBLIC", "privileges": "SELECT"}), "shared.job"),
        ("g", lambda d: d["relations"]["shared"]["job"]["grants"].append(
            {"grantee": "tripplanner", "privileges": "SELECT"}), "shared.job:tripplanner"),
        ("t", lambda d: d["relations"]["shared"]["job"]["policies"].append(
            {"policy": "all", "permissive": "PERMISSIVE", "roles": ["aa_app_user"], "cmd": "ALL", "qual": "true",
             "with_check": None}), "shared.job:all"),
    )

    def test_section_on_the_test_dump(self):
        md = gen.render(dump())
        self.assertIn("## RLS catalogue guard (X2)", md)
        self.assertIn("RLS catalogue guard: ", md)
        # The fixture grants booking catalog USAGE/SELECT (allowlisted contract) and shared.job columns to
        # booking (not allowlisted: a cis object to a booking role).
        self.assertIn("| g | `catalog.*:booking` | 1 | contract: catalog.* views for Booking (CIS 225, 228) |", md)
        self.assertIn("- [g] `shared.job.id:booking`: cis object to booking role: SELECT", md)
        self.assertNotIn("### Violations\n\n- none", md)

    def test_each_seeded_rule_is_reported(self):
        for rule, mutate, key in self.SEEDS:
            with self.subTest(rule=rule):
                d = dump()
                mutate(d)
                md = gen.render(d)
                self.assertIn(f"- [{rule}] `{key}`:", md)
                report = gen.rls_guard_report(d)
                self.assertIn(f"::warning::RLS catalogue guard [{rule}] {key}:", report)

    def test_clean_dump_reports_no_violation(self):
        d = dump()
        d["relations"]["shared"]["job"]["column_grants"] = []
        md = gen.render(d)
        self.assertIn("**0 unallowlisted violation(s)**", md)
        self.assertIn("### Violations\n\n- none", md)
        self.assertEqual(gen.rls_guard_report(d).count("::warning::"), 0)

    def test_cli_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "dump.json"
            p.write_text(json.dumps(dump()), encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(gen.main([str(p), "--rls-guard"]), 0)
            self.assertTrue(buf.getvalue().startswith("- RLS catalogue guard (X2): 2 unallowlisted violation(s)"))

    def test_guard_outcome_moves_the_fingerprint(self):
        d = dump()
        base = gen.fingerprint(d)
        original = dict(gen.rls.ALLOWLIST["g"])
        try:
            gen.rls.ALLOWLIST["g"]["shared.job.*:booking"] = "test entry"
            self.assertNotEqual(base, gen.fingerprint(d))
        finally:
            gen.rls.ALLOWLIST["g"].clear()
            gen.rls.ALLOWLIST["g"].update(original)
        self.assertEqual(base, gen.fingerprint(d))


class FingerprintTest(unittest.TestCase):
    def test_volatile_changes_keep_the_fingerprint(self):
        a = dump()
        b = copy.deepcopy(a)
        b["generated_at"] = "2026-10-16T05:00:00+00:00"
        b["database"]["size_bytes"] += 1
        job = b["relations"]["shared"]["job"]
        job["est_rows"], job["size"]["total"] = 9999, 1
        job["activity"]["seq_scan"] += 100
        job["indexes"][0]["scans"] += 1
        job["indexes"][0]["bytes"] += 1
        b["connections"] = []
        b["soft_keys"][0].update(total=99, without_key=0, orphans=5, orphan_rate=0.0505)
        self.assertEqual(gen.fingerprint(a), gen.fingerprint(b))

    def test_structural_changes_move_the_fingerprint(self):
        base = gen.fingerprint(dump())
        for mutate in (
            lambda d: d["relations"]["shared"]["job"]["columns"].append(
                {"name": "x", "type": "int", "not_null": False}),
            lambda d: d["relations"]["shared"]["job"]["grants"].append({"grantee": "tp", "privileges": "SELECT"}),
            lambda d: d["relations"]["shared"]["job"].update(rls_forced=True),
            lambda d: d["roles"][0].update(connection_limit=30),
            lambda d: d["migrations"].insert(0, {"version": "232", "applied_at": "x", "description": "y"}),
            lambda d: d["soft_keys"][1].update(status="ok"),
        ):
            d = dump()
            mutate(d)
            self.assertNotEqual(base, gen.fingerprint(d))

    def test_fingerprint_is_embedded_and_cli_matches(self):
        d = dump()
        fp = gen.fingerprint(d)
        md = gen.render(d)
        self.assertEqual(gen.FINGERPRINT_RE.search(md).group(1), fp)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "dump.json"
            p.write_text(json.dumps(d), encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(gen.main([str(p), "--fingerprint"]), 0)
            self.assertEqual(buf.getvalue().strip(), fp)
            out = Path(tmp) / "ref.md"
            with redirect_stdout(io.StringIO()):
                self.assertEqual(gen.main([str(p), "--out", str(out)]), 0)
            self.assertEqual(out.read_text(encoding="utf-8"), md)
            p.write_text(json.dumps({"format": 1}), encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(gen.main([str(p), "--fingerprint"]), 2)


if __name__ == "__main__":
    unittest.main()
