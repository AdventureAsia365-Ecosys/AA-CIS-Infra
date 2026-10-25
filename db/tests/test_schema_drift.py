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
            (base / "000_x.sql").write_text("CREATE SCHEMA acp_shared;", encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()
