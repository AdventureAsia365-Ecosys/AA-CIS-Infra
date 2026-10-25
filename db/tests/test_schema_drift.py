"""Unit tests for the AA-853 schema drift report: db/replay_migrations.py (pure parts) and db/schema_drift.py.

The replay itself needs a PostgreSQL server and runs in the DB Schema Dump workflow; these tests cover the
order, the role bootstrap, the attribution and the diff.

Run: python3 -m unittest discover -s db/tests -v
"""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gen_schema_reference as gen  # noqa: E402
import replay_migrations as rp  # noqa: E402
import schema_drift as sd  # noqa: E402


def mig(version, at, desc="x"):
    return {"version": version, "applied_at": at, "description": desc}


class PlanOrder(unittest.TestCase):
    SOURCES = {
        "cis": ["001_initial.sql", "004_legacy.sql", "007b_user.sql", "010_a.sql", "011_b.sql", "099_pending.sql"],
        "booking": ["001_b.sql", "002_b.sql"],
        "roles": ["001_r.sql"],
        "crm": ["001_c.sql"],
    }
    LIVE = [
        mig("v1.0", "2026-04-20 05:00:00", "001_initial.sql — first"),
        mig("v1.1", "2026-04-20 05:00:00", "security fix"),
        mig("010", "2026-05-01 00:00:00"),
        mig("bk-001", "2026-05-02 00:00:00"),
        mig("rl-001", "2026-05-03 00:00:00"),
        mig("011", "2026-05-04 00:00:00"),
        mig("bk-002", "2026-05-05 00:00:00"),
        mig("crm-001", "2026-05-06 00:00:00"),
    ]

    def setUp(self):
        self.plan = rp.plan_order(self.LIVE, self.SOURCES)
        self.rels = [it.rel for it in self.plan["items"]]

    def test_registered_files_follow_applied_at_across_owners(self):
        reg = [r for r, it in zip(self.rels, self.plan["items"], strict=True) if it.registered]
        self.assertEqual(reg, ["cis/001_initial.sql", "cis/010_a.sql", "booking/001_b.sql", "roles/001_r.sql",
                               "cis/011_b.sql", "booking/002_b.sql", "crm/001_c.sql"])

    def test_version_without_key_maps_through_its_description(self):
        self.assertEqual(self.plan["items"][0].key, "v1.0")
        self.assertIn("v1.1", self.plan["no_file"])

    def test_legacy_files_replay_after_the_file_before_them(self):
        self.assertEqual(self.rels[:4], ["cis/001_initial.sql", "cis/004_legacy.sql", "cis/007b_user.sql",
                                         "cis/010_a.sql"])
        self.assertEqual(self.plan["legacy"], ["cis/004_legacy.sql", "cis/007b_user.sql"])
        self.assertFalse(self.plan["items"][1].registered)

    def test_files_above_the_owner_head_are_pending(self):
        self.assertEqual(self.plan["pending"], ["cis/099_pending.sql"])
        self.assertNotIn("cis/099_pending.sql", self.rels)

    def test_file_key(self):
        self.assertEqual(rp.file_key("booking", "014_x.sql"), "bk-014")
        self.assertEqual(rp.file_key("cis", "245_x.sql"), "245")
        self.assertEqual(rp.file_key("cis", "007b_user.sql"), "")


class Roles(unittest.TestCase):
    def test_created_roles_reads_literal_create_role(self):
        texts = ["DO $$ BEGIN IF NOT EXISTS (SELECT 1) THEN CREATE ROLE bk_owner NOLOGIN; END IF; END $$;",
                 'create role "cis_app" login;', "ALTER ROLE tripplanner CONNECTION LIMIT 30;"]
        self.assertEqual(rp.created_roles(texts), {"bk_owner", "cis_app"})

    def test_bootstrap_keeps_hand_made_roles_only(self):
        live = [{"role": "aa_cis_admin", "login": True}, {"role": "tripplanner", "login": True},
                {"role": "bk_owner", "login": False}]
        self.assertEqual([r["role"] for r in rp.bootstrap_roles(live, {"bk_owner"})], ["tripplanner"])


class Attribution(unittest.TestCase):
    def test_mentioned_names_of_known_schemas_only(self):
        sql = 'ALTER TABLE acp_shared.acp_runs ADD x int; SELECT now()::date; CREATE SCHEMA IF NOT EXISTS acp_deliver;'
        names, schemas = rp.mentioned(sql, {"acp_shared", "acp_deliver"})
        self.assertEqual(names, ["acp_shared.acp_runs"])
        self.assertEqual(schemas, ["acp_deliver", "acp_shared"])


class Baseline(unittest.TestCase):
    def test_baseline_file_goes_before_its_key(self):
        order = rp.plan_order([mig("010", "2026-01-01"), mig("011", "2026-01-02")],
                              {"cis": ["010_a.sql", "011_b.sql"]})
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "replay_baseline"
            base.mkdir()
            guard = (f"-- {rp.rm.BASELINE_MARKER}\n"
                     f"DO $g$ BEGIN PERFORM current_setting('{rp.BASELINE_SETTING}'); END $g$;\n")
            (base / "000_x.sql").write_text(guard + "CREATE SCHEMA acp_shared;", encoding="utf-8")
            old = rp.DB_DIR
            rp.DB_DIR = Path(tmp)
            try:
                texts: dict = {}
                problems = rp.add_baseline(order, [{"file": "replay_baseline/000_x.sql", "before": "011"},
                                                   {"file": "../etc/passwd", "before": "start"},
                                                   {"file": "replay_baseline/000_x.sql", "before": "999"}], texts)
            finally:
                rp.DB_DIR = old
        self.assertEqual([it.rel for it in order["items"]],
                         ["cis/010_a.sql", "baseline/replay_baseline/000_x.sql", "cis/011_b.sql"])
        self.assertEqual(len(problems), 2)
        self.assertIn("replay_baseline/000_x.sql", texts["baseline"])


def dump(**over):
    base = {
        "format": 2, "generated_at": "2026-10-25T00:00:00+00:00",
        "database": {"name": "aa_cis_dev", "server_version": "15.17"},
        "schemas": [{"schema": "shared", "owner": "cis_owner", "grants": []},
                    {"schema": "booking", "owner": "bk_owner",
                     "grants": [{"grantee": "booking", "privileges": "USAGE"}]}],
        "relations": {
            "shared": {"job": {"kind": "table", "owner": "cis_owner", "columns": [
                {"name": "id", "type": "bigint", "not_null": True}, {"name": "kind", "type": "text", "not_null": True}],
                "indexes": [{"index": "job_pkey",
                             "definition": "CREATE UNIQUE INDEX job_pkey ON shared.job USING btree (id)"}],
                "constraints": [], "policies": [], "triggers": [], "grants": [], "column_grants": []}},
            "booking": {},
        },
        "functions": [], "enums": [], "default_privileges": [],
    }
    for k, v in over.items():
        base[k] = v
    return base


class Diff(unittest.TestCase):
    def test_identical_dumps_have_no_drift(self):
        d = sd.diff(dump(), dump())
        self.assertEqual((d["counts"]["unmanaged"], d["counts"]["missing"], d["counts"]["changed"]), (0, 0, 0))

    def test_unmanaged_table_folds_its_children(self):
        live = dump()
        live["relations"]["booking"]["by_hand"] = {
            "kind": "table", "owner": "bk_owner", "columns": [{"name": "a", "type": "int", "not_null": False},
                                                             {"name": "b", "type": "int", "not_null": False}],
            "indexes": [{"index": "by_hand_a", "definition": "CREATE INDEX by_hand_a ON booking.by_hand (a)"}],
            "constraints": [], "policies": [], "triggers": [], "grants": [], "column_grants": []}
        d = sd.diff(live, dump())
        self.assertEqual([f["id"] for f in d["unmanaged"]], ["relation booking.by_hand"])
        self.assertEqual(d["unmanaged"][0]["children"], 3)
        self.assertEqual(d["unmanaged"][0]["owner"], "booking")
        self.assertEqual(d["counts"]["unmanaged_objects"], 4)
        self.assertEqual(d["counts"]["open_unmanaged"], 1)

    def test_missing_and_changed(self):
        replay = dump()
        replay["relations"]["shared"]["job"]["columns"][1]["type"] = "character varying(64)"
        replay["enums"] = [{"schema": "shared", "name": "status", "labels": ["a", "b"]}]
        d = sd.diff(dump(), replay)
        self.assertEqual([f["id"] for f in d["missing"]], ["enum shared.status"])
        self.assertEqual([f["id"] for f in d["changed"]], ["column shared.job.kind"])
        self.assertEqual(d["changed"][0]["diff"]["type"], {"live": "text", "replay": "character varying(64)"})

    def test_privileges_are_separate(self):
        replay = dump()
        replay["schemas"][1]["owner"] = "aa_cis_admin"
        d = sd.diff(dump(), replay)
        self.assertEqual(d["counts"]["unmanaged"] + d["counts"]["missing"] + d["counts"]["changed"], 0)
        self.assertEqual([p["id"] for p in d["privileges"]], ["owner schema booking"])

    def test_decisions_close_findings_and_change_the_fingerprint(self):
        live = dump()
        live["schemas"].append({"schema": "acp_shared", "owner": "cis_owner", "grants": []})
        live["relations"]["acp_shared"] = {}
        before = sd.diff(live, dump())
        dec = [{"id": "schema acp_*", "class": "unmanaged", "owner": "cis", "decision": "baseline", "ref": "AA-1"}]
        after = sd.diff(live, dump(), decisions=dec)
        self.assertEqual(before["counts"]["open_unmanaged"], 1)
        self.assertEqual(after["counts"]["open_unmanaged"], 0)
        self.assertEqual(after["unmanaged"][0]["decision"]["decision"], "baseline")
        self.assertNotEqual(before["fingerprint"], after["fingerprint"])
        self.assertIsNone(sd.find_decision(dec, "missing", "schema acp_shared"))

    def test_replay_gap_explains_a_finding(self):
        live = dump()
        live["relations"]["shared"]["acp_like"] = copy.deepcopy(live["relations"]["shared"]["job"])
        results = {"items": [{"rel": "cis/030_x.sql", "status": "failed", "key": "030", "error": "boom",
                              "names": ["shared.acp_like"], "schemas": ["shared"]},
                             {"rel": "cis/031_y.sql", "status": "ok", "names": ["shared.acp_like"]}]}
        d = sd.diff(live, dump(), results)
        self.assertEqual(d["unmanaged"][0]["explained_by"], ["cis/030_x.sql"])
        self.assertEqual(d["counts"]["explained_by_replay_gap"], 1)
        self.assertEqual(d["replay"]["gaps"][0]["rel"], "cis/030_x.sql")

    def test_fingerprint_ignores_replay_noise(self):
        a = sd.diff(dump(), dump(), {"items": [], "generated_at": "1"})
        b = sd.diff(dump(), dump(), {"items": [], "generated_at": "2"})
        self.assertEqual(a["fingerprint"], b["fingerprint"])

    def test_fingerprint_leaves_out_findings_a_replay_gap_explains(self):
        live = dump()
        live["relations"]["shared"]["acp_like"] = copy.deepcopy(live["relations"]["shared"]["job"])
        gap = {"items": [{"rel": "cis/030_x.sql", "status": "failed", "names": ["shared.acp_like"]}]}
        explained = sd.diff(live, dump(), gap)
        self.assertEqual(explained["counts"]["unmanaged"], 1)              # still reported
        self.assertEqual(explained["fingerprint"], sd.diff(dump(), dump())["fingerprint"])
        self.assertNotEqual(sd.diff(live, dump())["fingerprint"], explained["fingerprint"])   # unexplained: counts


class Render(unittest.TestCase):
    def test_reference_gets_the_section_only_with_drift(self):
        live = dump()
        live["relations"]["booking"]["by_hand"] = copy.deepcopy(live["relations"]["shared"]["job"])
        d = sd.diff(live, dump())
        live_full = json.loads(json.dumps(live))
        for key in ("migrations", "roles", "role_members", "extensions", "connections", "soft_keys"):
            live_full.setdefault(key, [])
        live_full.setdefault("counts", {"indexes": 1, "policies": 0})
        live_full.setdefault("migrations_latest_per_owner", {})
        with_drift = gen.render(live_full, "test", d)
        without = gen.render(live_full, "test")
        self.assertIn("## Schema drift against a replay of all migrations (AA-853)", with_drift)
        self.assertIn(f"<!-- drift-fingerprint: {d['fingerprint']} -->", with_drift)
        self.assertIn("`relation booking.by_hand`", with_drift)
        self.assertNotIn("drift-fingerprint", without)
        self.assertEqual(gen.fingerprint(live_full), gen.fingerprint(live_full))   # schema fingerprint unchanged

    def test_failed_drift_run_keeps_masters_section(self):
        live = dump()
        live["relations"]["booking"]["by_hand"] = copy.deepcopy(live["relations"]["shared"]["job"])
        d = sd.diff(live, dump())
        live_full = json.loads(json.dumps(live))
        for key in ("migrations", "roles", "role_members", "extensions", "connections", "soft_keys"):
            live_full.setdefault(key, [])
        live_full.setdefault("counts", {"indexes": 1, "policies": 0})
        live_full.setdefault("migrations_latest_per_owner", {})
        master = gen.render(live_full, "master run", d)
        section = gen.drift_section_of(master)
        self.assertTrue(section[0].startswith(gen.DRIFT_HEADING))
        self.assertFalse(any(x.startswith("## Connections") for x in section))
        with tempfile.TemporaryDirectory() as tmp:
            old, dumpf, out = Path(tmp, "old.md"), Path(tmp, "dump.json"), Path(tmp, "new.md")
            old.write_text(master, encoding="utf-8")
            dumpf.write_text(json.dumps(live_full), encoding="utf-8")
            gen.main([str(dumpf), "--out", str(out), "--source", "failed run", "--keep-drift-from", str(old)])
            kept = out.read_text(encoding="utf-8")
            self.assertIn(f"<!-- drift-fingerprint: {d['fingerprint']} -->", kept)
            self.assertEqual(gen.drift_section_of(kept), section)
            gen.main([str(dumpf), "--out", str(out), "--keep-drift-from", str(Path(tmp, "missing.md"))])
            self.assertNotIn("drift-fingerprint", out.read_text(encoding="utf-8"))

    def test_summary_lines(self):
        lines = sd.summary_lines(sd.diff(dump(), dump()))
        self.assertTrue(lines[0].startswith("### Schema drift"))

    def test_decisions_file_in_the_repo_is_valid(self):
        path = Path(__file__).resolve().parent.parent / "schema_drift_decisions.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        self.assertIsInstance(data.get("decisions"), list)
        self.assertIsInstance(data.get("baseline"), list)
        for b in data["baseline"]:
            self.assertTrue((path.parent / b["file"]).is_file(), b)
        for fx in data.get("replay_order", []):
            self.assertTrue((fx.get("keys") or fx.get("files")) and fx.get("before") and fx.get("reason")
                            and fx.get("ref"), fx)


class RoleGaps(unittest.TestCase):
    """S251: roles a failed file would have created are filled before the next file (role_creators / roles_to_fill)."""

    LIVE = frozenset({"bk_owner", "tp_owner", "catalog_owner", "crm_ai_reader", "crm_eraser", "tripplanner"})

    def test_create_role_in_a_comment_does_not_count(self):
        sql = "-- CREATE ROLE crm_ai_reader NOLOGIN (if missing)\n/* CREATE ROLE tp_owner */ SELECT 1;"
        self.assertEqual(rp.roles_created_by(sql, self.LIVE), set())

    def test_create_role_in_a_do_block_counts(self):
        sql = "DO $$ BEGIN IF to_regrole('bk_owner') IS NULL THEN CREATE ROLE bk_owner NOLOGIN; END IF; END $$;"
        self.assertEqual(rp.roles_created_by(sql, self.LIVE), {"bk_owner"})

    def test_format_built_create_role_takes_the_live_names_of_its_strings(self):
        sql = ("DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['crm_ai_reader', 'crm_eraser', 'not_live'] LOOP "
               "EXECUTE format('CREATE ROLE %I NOLOGIN', r); END LOOP; END $$;")
        self.assertEqual(rp.roles_created_by(sql, self.LIVE), {"crm_ai_reader", "crm_eraser"})

    def test_format_built_create_role_ignores_live_names_it_only_grants_to(self):
        # review S251 #5: a live role in another literal (a GRANT target, a check) is not created by the loop
        sql = ("DO $$ DECLARE r text; BEGIN "
               "IF to_regrole('tripplanner') IS NULL THEN RAISE EXCEPTION 'apply rl-001 first'; END IF; "
               "FOREACH r IN ARRAY ARRAY['crm_ai_reader'] LOOP EXECUTE format('CREATE ROLE %I NOLOGIN', r); END LOOP; "
               "EXECUTE format('GRANT %I TO %I', 'crm_eraser', 'bk_owner'); END $$;")
        self.assertEqual(rp.roles_created_by(sql, self.LIVE), {"crm_ai_reader"})

    def test_format_built_create_role_with_literal_arguments(self):
        sql = "DO $$ BEGIN EXECUTE format('CREATE ROLE %I NOLOGIN', 'tp_owner'); END $$;"
        self.assertEqual(rp.roles_created_by(sql, self.LIVE), {"tp_owner"})

    def test_the_real_rl_004_creates_only_its_four_nologin_roles(self):
        path = Path(__file__).resolve().parent.parent / "migrations" / "roles" / "004_crm_nologin_roles.sql"
        sql = path.read_text(encoding="utf-8")
        live = frozenset({"crm_ai_reader", "crm_insights", "crm_support_reader", "crm_eraser", "crm_app", "crm_owner",
                          "aa_cis_admin"})
        self.assertEqual(rp.roles_created_by(sql, live),
                         {"crm_ai_reader", "crm_insights", "crm_support_reader", "crm_eraser"})

    def _items(self):
        order = rp.plan_order([mig("225", "2026-10-01"), mig("rl-001", "2026-10-02"), mig("243", "2026-10-03")],
                              {"cis": ["225_catalog.sql", "243_grants.sql"], "roles": ["001_x1.sql"]})
        texts = {"cis": {"225_catalog.sql": "CREATE ROLE catalog_owner NOLOGIN;", "243_grants.sql": "SELECT 1;"},
                 "roles": {"001_x1.sql": "CREATE ROLE bk_owner NOLOGIN; CREATE ROLE catalog_owner NOLOGIN;"}}
        return order["items"], texts

    def test_first_creator_wins(self):
        items, texts = self._items()
        creators = rp.role_creators(items, texts, self.LIVE)
        self.assertEqual(creators, {"catalog_owner": 0, "bk_owner": 1})

    def test_only_roles_of_earlier_files_that_the_replay_lacks_are_filled(self):
        items, texts = self._items()
        creators = rp.role_creators(items, texts, self.LIVE)
        self.assertEqual(rp.roles_to_fill(0, creators, set()), [])                 # its own creator runs first
        self.assertEqual(rp.roles_to_fill(1, creators, set()), ["catalog_owner"])  # 225 failed: rl-001 needs it
        self.assertEqual(rp.roles_to_fill(2, creators, {"catalog_owner"}), ["bk_owner"])
        self.assertEqual(rp.roles_to_fill(2, creators, {"catalog_owner", "bk_owner"}), [])

    def test_role_attributes_follow_the_live_row_without_a_password(self):
        self.assertEqual(rp.role_attributes({"login": True, "inherit": False, "connection_limit": 6}),
                         "LOGIN NOINHERIT CONNECTION LIMIT 6")
        self.assertEqual(rp.role_attributes({"login": False, "inherit": True, "connection_limit": -1}),
                         "NOLOGIN INHERIT")
        self.assertEqual(rp.role_attributes({"login": True, "createrole": True, "createdb": True}),
                         "LOGIN INHERIT CREATEROLE CREATEDB")


class OwnerTransfer(unittest.TestCase):
    def test_transfer_file_is_the_first_that_moves_the_anchor_schema(self):
        order = rp.plan_order([mig("244", "2026-10-01"), mig("245", "2026-10-02"), mig("bk-014", "2026-10-03"),
                               mig("246", "2026-10-04")],
                              {"cis": ["244_a.sql", "245_owner.sql", "246_probe.sql"], "booking": ["014_bk.sql"]})
        texts = {"cis": {"244_a.sql": "-- ALTER SCHEMA shared OWNER TO cis_owner comes in 245\nSELECT 1;",
                         "245_owner.sql": "BEGIN; ALTER SCHEMA shared OWNER TO cis_owner; COMMIT;",
                         "246_probe.sql": "ALTER SCHEMA shared OWNER TO cis_owner;"},
                 "booking": {"014_bk.sql": "ALTER SCHEMA booking OWNER TO bk_owner;"}}
        self.assertEqual(rp.transfer_files(order["items"], texts), {"cis": 1, "booking": 2})

    def test_cis_scope_moves_every_schema_but_not_the_catalog_objects(self):
        # review S251 #2: 245 item 4 moves objects in the 11 runtime schemas only; catalog's views stay
        schemas, objects = rp.transfer_scope("cis", ["shared", "catalog", "geo", "not_cis"])
        self.assertEqual(schemas, ["catalog", "geo", "shared"])
        self.assertEqual(objects, ["geo", "shared"])
        self.assertEqual(rp.transfer_scope("booking", ["booking"]), (["booking"], ["booking"]))
        self.assertEqual(rp.transfer_scope("tripplanner", []), ([], []))

    def test_every_schema_goes_to_the_new_owner_not_its_live_owner(self):
        # review S251 #1: 245 sets all 12 CIS schemas to cis_owner; a later owner change on Dev must stay drift
        stmts = rp.ownership_statements(["catalog", "shared"], [], "cis_owner")
        self.assertEqual(stmts, ['ALTER SCHEMA "catalog" OWNER TO "cis_owner"',
                                 'ALTER SCHEMA "shared" OWNER TO "cis_owner"'])

    def test_objects_follow_the_schemas_with_their_kind_keyword(self):
        objects = [("TABLE", "shared.job"), ("TYPE", "shared.tstz_window"), ("DOMAIN", "shared.iso2"),
                   ("FUNCTION", "shared.f(integer)"), ("STATISTICS", "shared.job_stx"),
                   ("TEXT SEARCH CONFIGURATION", 'shared."Simple"')]
        stmts = rp.ownership_statements(["shared"], objects, "cis_owner")
        self.assertEqual(stmts[0], 'ALTER SCHEMA "shared" OWNER TO "cis_owner"')
        self.assertEqual(stmts[1:], [f'ALTER {k} {n} OWNER TO "cis_owner"' for k, n in objects])

    def test_unknown_object_kind_is_refused(self):
        with self.assertRaises(ValueError):
            rp.ownership_statements([], [("SERVER", "x")], "cis_owner")

    def test_owned_objects_query_takes_the_kinds_245_moves(self):
        q = rp.OWNED_OBJECTS_SQL
        self.assertIn("y.typtype IN ('e', 'd', 'r')", q)                 # range types too
        self.assertIn("c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S', 'c')", q)   # standalone composite types
        self.assertIn("d.deptype = 'e'", q)                              # extension members stay
        for kind in ("pg_statistic_ext", "pg_collation", "pg_conversion", "pg_ts_dict", "pg_ts_config"):
            self.assertIn(kind, q)


class ServerVersion(unittest.TestCase):
    """review S251 #3: the replay refuses a server that is not PostgreSQL 15."""

    def test_15_is_accepted(self):
        self.assertIsNone(rp.check_server_version(150017))
        self.assertIsNone(rp.check_server_version(150000))

    def test_other_majors_are_refused(self):
        for v in (160015, 140010, 170000):
            msg = rp.check_server_version(v)
            self.assertIsNotNone(msg)
            self.assertIn(f"PostgreSQL {v // 10000}", msg)


class FillRolesCache(unittest.TestCase):
    """review S251 #6: fill_roles asks the server only when a role is due that was not seen yet."""

    def test_no_connection_when_every_due_role_was_seen(self):
        import asyncio
        calls = []

        async def fake_connect(*a, **k):
            calls.append(a)
            raise AssertionError("must not connect")

        orig = rp._connect
        rp._connect = fake_connect
        try:
            out = asyncio.run(rp.fill_roles("dsn", 5, {"bk_owner": 1, "tp_owner": 2}, {}, [], {"bk_owner", "tp_owner"}))
            self.assertEqual(out, [])
            out = asyncio.run(rp.fill_roles("dsn", 1, {"bk_owner": 1, "tp_owner": 2}, {}, [], set()))
            self.assertEqual(out, [])                                   # nothing due yet (creator not earlier)
        finally:
            rp._connect = orig
        self.assertEqual(calls, [])


class ReplayOrder(unittest.TestCase):
    LIVE = [mig("148", "2026-09-11 01:00"), mig("149", "2026-09-11 04:17"), mig("198", "2026-10-01"),
            mig("tp-001", "2026-10-11", "backfill: tripplanner schema"), mig("tp-002", "2026-10-11", "backfill: x"),
            mig("tp-007", "2026-10-11")]
    SOURCES = {"cis": ["148_a.sql", "149_b.sql", "198_c.sql"],
               "tripplanner": ["001_tp.sql", "002_dest.sql", "007_register.sql"]}

    def test_back_registered_rows_are_listed(self):
        self.assertEqual(rp.backfilled(self.LIVE), ["tp-001", "tp-002"])

    def test_moved_before_their_anchor_in_the_given_order(self):
        order = rp.plan_order(self.LIVE, self.SOURCES)
        problems = rp.apply_order_fixes(order, [{"keys": ["tp-002", "tp-001"], "before": "149"}])
        self.assertEqual(problems, [])
        self.assertEqual([it.key for it in order["items"]], ["148", "tp-002", "tp-001", "149", "198", "tp-007"])
        self.assertEqual(order["items"][1].moved_before, "149")

    def test_bad_entries_are_reported_and_change_nothing(self):
        order = rp.plan_order(self.LIVE, self.SOURCES)
        before = [it.key for it in order["items"]]
        problems = rp.apply_order_fixes(order, [{"keys": ["tp-001"], "before": "999"},
                                                {"keys": ["tp-404"], "before": "149"},
                                                {"keys": ["tp-001"], "before": "tp-001"},
                                                {"keys": [], "before": "149"}])
        self.assertEqual(len(problems), 4)
        self.assertEqual([it.key for it in order["items"]], before)


class DdlTargets(unittest.TestCase):
    KNOWN = frozenset({"shared", "silver_aa_internal", "acp_shared"})

    def test_ddl_targets_words_and_creates(self):
        sql = ("-- ALTER TABLE shared.ignored ADD x int\n"
               "CREATE TABLE IF NOT EXISTS acp_shared.audit_log (id bigint, actor text);\n"
               "ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS country_iso2 char(2);\n"
               "CREATE INDEX IF NOT EXISTS idx_x ON silver_aa_internal.raw_tours (sku);\n"
               "SELECT * FROM shared.tenants;\n"
               "DROP VIEW IF EXISTS shared.v_usage; CREATE VIEW shared.v_usage AS SELECT 1 AS n;")
        d = rp.ddl_targets(sql, self.KNOWN)
        self.assertEqual(d["names"], ["acp_shared.audit_log", "shared.v_usage", "silver_aa_internal.raw_tours"])
        self.assertEqual(d["created"], ["acp_shared.audit_log", "shared.v_usage"])
        self.assertEqual(d["recreated"], ["shared.v_usage"])
        self.assertIn("country_iso2", d["words"]["silver_aa_internal.raw_tours"])
        self.assertIn("idx_x", d["words"]["silver_aa_internal.raw_tours"])
        self.assertNotIn("shared.tenants", d["names"])          # a SELECT is not DDL
        self.assertEqual(d["dynamic"], {})

    def test_format_built_ddl_is_kind_bound(self):
        sql = ("DO $$ BEGIN EXECUTE format('CREATE POLICY tenant_isolation ON %I.%I USING (true)', 'shared', 't'); "
               "END $$; SELECT 1 FROM shared.tenants;")
        d = rp.ddl_targets(sql, self.KNOWN)
        self.assertEqual(d["dynamic"]["kinds"], ["policy"])
        self.assertIn("shared.tenants", d["dynamic"]["names"])

    def test_gap_roots_tell_lost_history_from_a_cascade(self):
        order = rp.plan_order([mig("019", "2026-05-01"), mig("078", "2026-06-01"), mig("079", "2026-06-02")],
                              {"cis": ["019_a.sql", "078_b.sql", "079_c.sql"]})
        texts = {"cis": {"019_a.sql": "ALTER TABLE acp_shared.acp_runs ADD x int;",
                         "078_b.sql": "CREATE SCHEMA IF NOT EXISTS acp_contract; SELECT pt.content_embedding;",
                         "079_c.sql": "CREATE TABLE acp_contract.tour_atoms (id int);"}}
        items = order["items"]
        for it, err in zip(items, ['relation "acp_shared.acp_runs" does not exist',
                                   "column pt.content_embedding does not exist",
                                   'schema "acp_contract" does not exist'], strict=True):
            it.status, it.error = "failed", err
        roots = {g["object"]: g for g in rp.gap_roots(items, texts, {"acp_shared", "acp_contract"})}
        self.assertTrue(roots["acp_shared.acp_runs"]["root"])                  # no file creates it
        self.assertFalse(roots["acp_contract"]["root"])                        # 078 creates it, and failed
        self.assertEqual(roots["acp_contract"]["created_by"], ["cis/078_b.sql (failed)"])


class Attribution2(unittest.TestCase):
    """S251: a failed file explains a finding only when its DDL makes that difference."""

    def _live_with_column_type(self):
        live = dump()
        live["relations"]["shared"]["job"]["columns"][1]["type"] = "character varying(64)"
        return live

    def test_ddl_on_the_same_table_without_the_column_does_not_explain_it(self):
        gap = {"items": [{"rel": "cis/004_rls.sql", "status": "partial", "names": ["shared.job"],
                          "schemas": ["shared"], "ddl": {"names": ["shared.job"], "schemas": ["shared"],
                                                         "words": {"shared.job": ["enable", "row", "level"]},
                                                         "recreated": [], "created": [], "dynamic": {}}}]}
        d = sd.diff(self._live_with_column_type(), dump(), gap)
        f = d["changed"][0]
        self.assertEqual(f["explained_by"], [])
        self.assertEqual(f["mentioned_by"], ["cis/004_rls.sql"])
        self.assertEqual(d["counts"]["unexplained"], 1)
        self.assertEqual(d["counts"]["only_mentioned_by_replay_gap"], 1)

    def test_ddl_naming_the_column_explains_it(self):
        gap = {"items": [{"rel": "cis/090_type.sql", "status": "failed", "names": ["shared.job"],
                          "ddl": {"names": ["shared.job"], "schemas": ["shared"],
                                  "words": {"shared.job": ["alter", "kind", "type", "text"]},
                                  "recreated": [], "created": [], "dynamic": {}}}]}
        d = sd.diff(self._live_with_column_type(), dump(), gap)
        self.assertEqual(d["changed"][0]["explained_by"], ["cis/090_type.sql"])
        self.assertEqual(d["counts"]["unexplained"], 0)

    def test_trigger_naming_a_column_does_not_explain_its_type(self):
        # review S251 #8: CIS 279's `CREATE TRIGGER … UPDATE OF country ON raw_tours` named country in the words of
        # raw_tours, so 279 "explained" the text/varchar difference of raw_tours.country
        gap = {"items": [{"rel": "cis/279_countries.sql", "status": "failed", "names": ["shared.job"],
                          "ddl": {"names": ["shared.job"], "schemas": ["shared"],
                                  "words": {"shared.job": ["create", "trigger", "update", "of", "kind"]},
                                  "columns": {"shared.job": ["kind_iso2"]},
                                  "recreated": [], "created": [], "dynamic": {}}}]}
        d = sd.diff(self._live_with_column_type(), dump(), gap)
        self.assertEqual(d["changed"][0]["explained_by"], [])
        self.assertEqual(d["changed"][0]["mentioned_by"], ["cis/279_countries.sql"])

    def test_column_ddl_explains_the_column(self):
        gap = {"items": [{"rel": "cis/090_type.sql", "status": "failed", "names": ["shared.job"],
                          "ddl": {"names": ["shared.job"], "schemas": ["shared"], "words": {},
                                  "columns": {"shared.job": ["kind"]},
                                  "recreated": [], "created": [], "dynamic": {}}}]}
        d = sd.diff(self._live_with_column_type(), dump(), gap)
        self.assertEqual(d["changed"][0]["explained_by"], ["cis/090_type.sql"])

    def test_the_real_279_shape_targets_only_country_iso2(self):
        sql = ("ALTER TABLE silver_aa_internal.raw_tours ADD COLUMN IF NOT EXISTS country_iso2 character(2) "
               "REFERENCES shared.countries (iso2);\n"
               "CREATE INDEX IF NOT EXISTS raw_tours_country_iso2_idx ON silver_aa_internal.raw_tours (country_iso2);\n"
               "CREATE TRIGGER raw_tours_country_iso2 BEFORE INSERT OR UPDATE OF country"
               " ON silver_aa_internal.raw_tours FOR EACH ROW EXECUTE FUNCTION shared.set_country_iso2();")
        ddl = rp.ddl_targets(sql, {"silver_aa_internal", "shared"})
        self.assertEqual(ddl["columns"], {"silver_aa_internal.raw_tours": ["country_iso2"]})
        self.assertIn("country", ddl["words"]["silver_aa_internal.raw_tours"])

    def test_column_targets_of_alter_and_create_table(self):
        ct = rp.column_targets("alter table only shared.t add column if not exists a int, alter column b type text, "
                               "add constraint c check (x in (1, 2)), rename d to e, drop column f, owner to z",
                               {"shared"})
        self.assertEqual(ct, {"shared.t": {"a", "b", "d", "e", "f"}})
        ct = rp.column_targets("create table if not exists shared.t (id int primary key, name text)", {"shared"})
        self.assertTrue({"id", "name"} <= ct["shared.t"])
        self.assertEqual(rp.column_targets("alter table other.t add column a int", {"shared"}), {})

    def test_a_results_file_without_columns_falls_back_to_words(self):
        gap = {"items": [{"rel": "cis/090_type.sql", "status": "failed", "names": ["shared.job"],
                          "ddl": {"names": ["shared.job"], "schemas": ["shared"],
                                  "words": {"shared.job": ["alter", "kind", "type", "text"]},
                                  "recreated": [], "created": [], "dynamic": {}}}]}
        d = sd.diff(self._live_with_column_type(), dump(), gap)
        self.assertEqual(d["changed"][0]["explained_by"], ["cis/090_type.sql"])

    def test_a_recreated_view_explains_its_columns(self):
        live = dump()
        live["relations"]["shared"]["job"]["columns"].append({"name": "extra", "type": "int", "not_null": False})
        gap = {"items": [{"rel": "cis/223_view.sql", "status": "failed",
                          "ddl": {"names": [], "schemas": ["shared"], "words": {}, "recreated": ["shared.job"],
                                  "created": [], "dynamic": {}}}]}
        d = sd.diff(live, dump(), gap)
        self.assertEqual(d["unmanaged"][0]["explained_by"], ["cis/223_view.sql"])
        self.assertEqual(d["counts"]["unmanaged_unexplained"], 0)

    def test_unexplained_findings_are_listed_first(self):
        live = dump()
        live["relations"]["booking"]["zz_by_hand"] = copy.deepcopy(live["relations"]["shared"]["job"])
        live["relations"]["booking"]["aa_gap"] = copy.deepcopy(live["relations"]["shared"]["job"])
        gap = {"items": [{"rel": "booking/009_x.sql", "status": "failed",
                          "ddl": {"names": ["booking.aa_gap"], "schemas": ["booking"], "words": {},
                                  "recreated": [], "created": ["booking.aa_gap"], "dynamic": {}}}],
               "gap_roots": [{"object": "booking.lost", "needed_by": ["booking/009_x.sql"], "created_by": [],
                              "root": True}],
               "notes": ["role gap before booking/010_y.sql: created bk_owner (from roles/001_r.sql) …"]}
        md = "\n".join(sd.render_markdown(sd.diff(live, dump(), gap)))
        self.assertLess(md.index("relation booking.zz_by_hand"), md.index("relation booking.aa_gap"))
        self.assertIn("`booking.lost`", md)
        self.assertIn("Role / owner fills the replay made so later files run as on Dev: 1", md)


if __name__ == "__main__":
    unittest.main()
