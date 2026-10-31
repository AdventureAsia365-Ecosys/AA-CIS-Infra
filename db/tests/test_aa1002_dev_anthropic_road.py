"""AA-1002 (S261): db/scripts/aa1002_dev_anthropic_road.py (prepare the Dev Anthropic API road without the key).

No database, no asyncpg: a fake connection holds the five tables the script reads as Python rows, answers its SELECTs,
applies its INSERT / UPDATEs and restores everything on a rollback. The SQL against a real PostgreSQL is
test_aa1002_dev_anthropic_road_pg.py (local only). Stage and model keys are invented, except the code's legacy keys.
Run: python3 -m unittest discover -s db/tests -p 'test_aa1002*' -v
"""
import asyncio
import contextlib
import copy
import importlib.util
import io
import sys
import unittest
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa1002_dev_anthropic_road.py"
_spec = importlib.util.spec_from_file_location("aa1002_dev_anthropic_road", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

AWS = ["aws_only"]
BOTH = ["aws_only", "vendor_direct"]


def conn_row(key, kind, scope, secret=None, enabled=True, budget=None, auth="api_key"):
    return {"connection_key": key, "kind": kind, "auth_mode": auth, "enabled": enabled, "data_scope": scope,
            "secret_name": secret, "monthly_budget_usd": budget}


def model(key, vendor="anthropic", provider="bedrock", style="converse", enabled=True, profile=None):
    return {"model_key": key, "vendor": vendor, "provider": provider, "api_style": style, "enabled": enabled,
            "acc3_profile": profile}


def dep(model_key, connection_key, wire, priority, enabled=True, origin="seed"):
    return {"model_key": model_key, "connection_key": connection_key, "wire_id": wire, "priority": priority,
            "enabled": enabled, "origin": origin}


def stage(key, primary, fallbacks=(), shadow=None, scopes=AWS, role="writer", active=True):
    return {"stage": key, "role": role, "is_active": active, "model_id": primary,
            "fallback_model_ids": list(fallbacks), "shadow_model_id": shadow,
            "allowed_scopes": list(scopes) if scopes is not None else None}


def dev_world():
    """A Dev-like registry: acc3 + an OpenAI API connection + anthropic-direct (off, no budget)."""
    return {
        "has_scopes": True,
        "connections": [
            conn_row("acc3", "bedrock", "aws_only", auth="assume_role"),
            conn_row("openai-direct", "openai", "vendor_direct"),
            conn_row("anthropic-direct", "anthropic", "vendor_direct", secret=script.DEV_SECRET, enabled=False),
        ],
        "policies": [],
        "catalog": [
            model("anth-alpha", profile="global.anthropic.claude-alpha-9"),
            model("anth-beta", profile="us.anthropic.claude-beta-2-v1:0"),
            model("anth-off", profile="global.anthropic.claude-off-1"),
            model("haiku", style="anthropic_native", profile="us.anthropic.claude-legacy-h-v1:0"),
            model("sonnet", style="anthropic_native", profile="us.anthropic.claude-legacy-s-v1:0"),
            model("oai-gamma", vendor="openai", profile="openai.gamma"),
            model("oai-gamma-direct", vendor="openai", provider="openai", style="openai_chat"),
        ],
        "deployments": [
            dep("anth-alpha", "acc3", "global.anthropic.claude-alpha-9", 10),
            dep("anth-alpha", "anthropic-direct", "claude-alpha-9", 100),
            dep("anth-beta", "acc3", "us.anthropic.claude-beta-2-v1:0", 10),
            dep("anth-off", "acc3", "global.anthropic.claude-off-1", 10),
            dep("anth-off", "anthropic-direct", "claude-off-1", 100, enabled=False),
            dep("haiku", "acc3", "us.anthropic.claude-legacy-h-v1:0", 10, origin="legacy_constant"),
            dep("sonnet", "acc3", "us.anthropic.claude-legacy-s-v1:0", 10, origin="legacy_constant"),
            dep("oai-gamma", "acc3", "openai.gamma", 10),
            dep("oai-gamma-direct", "openai-direct", "gamma", 10, origin="openai_wire"),
        ],
        "stages": [
            stage("w1_writer", "anth-alpha", ["oai-gamma-direct"]),
            stage("w2_writer_new", "anth-beta", ["haiku"]),
            stage("x1_legacy_only", "sonnet", ["haiku"]),
            stage("x2_switched_off", "anth-off"),
            stage("j1_judge", "oai-gamma", ["anth-alpha", "oai-gamma-direct"], scopes=BOTH, role="judge"),
            stage("t3_tenant_writer", "sonnet", ["anth-alpha"]),
            stage("t11_tenant_shadow", "oai-gamma", shadow="anth-alpha", role="judge"),
            stage("tp_planner", "anth-alpha"),
            stage("e1_embed", "oai-gamma", role="embed"),
        ],
    }


class FakeTx:
    def __init__(self, conn, readonly=False):
        self.conn, self.readonly, self.saved = conn, readonly, None

    async def start(self):
        self.saved = copy.deepcopy(self.conn.db)
        self.conn.readonly = self.readonly

    async def commit(self):
        self.saved = None
        self.conn.readonly = False

    async def rollback(self):
        if self.saved is not None:
            self.conn.db = self.saved
        self.saved = None
        self.conn.readonly = False

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *exc):
        await (self.rollback() if exc[0] else self.commit())
        return False


class FakeConn:
    """Answers the script's statements by their text; records every statement."""

    def __init__(self, db):
        self.db, self.statements, self.readonly = db, [], False

    def transaction(self, readonly=False):
        return FakeTx(self, readonly)

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if sql.startswith(("SET LOCAL", "SELECT pg_advisory_xact_lock")):
            return "OK"
        assert not self.readonly, f"write in a read-only transaction: {sql}"
        if sql.startswith("INSERT INTO shared.llm_model_deployment"):
            model_key, connection_key, wire, priority, _notes, _by = args
            if not any(d["model_key"] == model_key and d["connection_key"] == connection_key
                       for d in self.db["deployments"]):
                self.db["deployments"].append(dep(model_key, connection_key, wire, priority))
            return "INSERT 0 1"
        if sql.startswith("UPDATE shared.llm_role_config"):
            key, scopes, _by = args
            for s in self.db["stages"]:
                if s["stage"] == key:
                    s["allowed_scopes"] = list(scopes)
            return "UPDATE 1"
        if sql.startswith("UPDATE shared.llm_provider_connection"):
            key, budget, _by = args
            assert "monthly_budget_usd IS NULL" in sql
            assert "enabled" not in sql.split("WHERE")[0], "the script must never write enabled"
            for c in self.db["connections"]:
                if c["connection_key"] == key and c["monthly_budget_usd"] is None:
                    c["monthly_budget_usd"] = budget
            return "UPDATE 1"
        raise AssertionError(f"unexpected statement: {sql}")

    async def fetchval(self, sql, *args):
        self.statements.append(sql)
        if "attname = 'allowed_scopes'" in sql:
            return self.db["has_scopes"]
        if "llm_connection_cost_policy" in sql:
            return True
        raise AssertionError(f"unexpected fetchval: {sql}")

    async def fetch(self, sql, *args):
        self.statements.append(sql)
        if "FROM shared.llm_provider_connection" in sql:
            return copy.deepcopy(self.db["connections"])
        if "FROM shared.llm_connection_cost_policy" in sql:
            return copy.deepcopy(self.db["policies"])
        if "FROM shared.llm_model_catalog" in sql:
            return copy.deepcopy(self.db["catalog"])
        if "FROM shared.llm_model_deployment" in sql:
            return sorted(copy.deepcopy(self.db["deployments"]),
                          key=lambda d: (d["model_key"], d["priority"], d["connection_key"]))
        if "FROM shared.llm_role_config" in sql:
            rows = copy.deepcopy(self.db["stages"])
            if not self.db["has_scopes"]:
                for r in rows:
                    r["allowed_scopes"] = None
            return rows
        raise AssertionError(f"unexpected fetch: {sql}")


def run(conn, mode):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = asyncio.run(script.run(conn, mode))
    return code, buf.getvalue()


def lines(text, tag):
    return [ln for ln in text.splitlines() if ln.startswith(f"SCRIPT {tag} ")]


def scopes_of(db, key):
    return next(s["allowed_scopes"] for s in db["stages"] if s["stage"] == key)


def anthropic_conn(db):
    return next(c for c in db["connections"] if c["connection_key"] == "anthropic-direct")


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file(self):
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertFalse(rm.script_is_read_only(source))

    def test_mode_is_a_known_value_and_not_read_only(self):
        # Merged as "dry_run"; the one-line follow-up PR switches it to "apply" (db/scripts/README.md flow).
        self.assertIn(script.MODE, ("dry_run", "apply"))
        self.assertFalse(hasattr(script, "READ_ONLY"))
        self.assertEqual(script.WRITE_ROLE, "cis_owner")

    def test_budget_is_five_dollars_a_day(self):
        self.assertEqual(script.MONTHLY_BUDGET_USD, Decimal("150.00"))


class WireIdTest(unittest.TestCase):
    def test_migration_306_rule(self):
        self.assertEqual(script.wire_id_for("global.anthropic.claude-alpha-9"), "claude-alpha-9")
        self.assertEqual(script.wire_id_for("us.anthropic.claude-beta-2-v1:0"), "claude-beta-2")
        self.assertIsNone(script.wire_id_for("openai.gamma"))
        self.assertIsNone(script.wire_id_for(None))
        self.assertIsNone(script.wire_id_for("global.anthropic.Claude_Bad"))


class DryRunTest(unittest.TestCase):
    def setUp(self):
        self.conn = FakeConn(dev_world())
        self.before = copy.deepcopy(self.conn.db)
        self.code, self.text = run(self.conn, "dry_run")

    def test_succeeds_and_rolls_back(self):
        self.assertEqual(self.code, 0, self.text)
        self.assertEqual(self.conn.db, self.before)
        self.assertEqual(len(lines(self.text, "rolled_back")), 1)
        self.assertIn("SET LOCAL ROLE cis_owner", self.conn.statements)

    def test_widens_admin_and_tenant_stages_with_an_api_road(self):
        widened = {ln.split("stage=")[1].split()[0] for ln in lines(self.text, "widen")}
        self.assertEqual(widened, {"w2_writer_new", "t3_tenant_writer"})
        groups = {ln.split("stage=")[1].split()[0]: ln.split("group=")[1].split()[0]
                  for ln in lines(self.text, "widen")}
        self.assertEqual(groups["t3_tenant_writer"], "tenant")
        self.assertEqual(groups["w2_writer_new"], "admin")

    def test_shadow_only_stage_is_not_widened(self):
        # S261 review: a shadow alone must not turn A/B shadow calls into paid API calls.
        self.assertFalse(any("stage=t11_tenant_shadow" in ln for ln in lines(self.text, "widen")))

    def test_holds_a_stage_that_would_reach_a_live_vendor_api(self):
        # S261 review: w1_writer also falls back to a GPT model on openai-direct, which is enabled; widening it would
        # send paid traffic outside AWS before the Anthropic key exists, so the script holds it for the tech lead.
        self.assertFalse(any("stage=w1_writer " in ln for ln in lines(self.text, "widen")))
        held = [ln for ln in lines(self.text, "held") if "stage=w1_writer " in ln]
        self.assertEqual(len(held), 1)
        self.assertIn("live=oai-gamma-direct@openai-direct", held[0])

    def test_widens_with_other_vendor_connection_switched_off(self):
        world = dev_world()
        world["connections"][1]["enabled"] = False
        code, text = run(FakeConn(world), "dry_run")
        self.assertEqual(code, 0, text)
        w1 = next(ln for ln in lines(text, "widen") if "stage=w1_writer " in ln)
        self.assertIn("also_vendor=oai-gamma-direct@openai-direct", w1)

    def test_inserts_the_missing_api_deployment_behind_acc3(self):
        ins = lines(self.text, "insert")
        self.assertEqual(len(ins), 1)
        self.assertIn("model=anth-beta", ins[0])
        self.assertIn("wire_id=claude-beta-2", ins[0])
        self.assertIn("priority=100", ins[0])

    def test_reports_gaps_and_never_widens_them(self):
        gaps = {ln.split("model=")[1].split()[0] for ln in lines(self.text, "gap")}
        self.assertEqual(gaps, {"haiku", "sonnet", "anth-off"})
        self.assertFalse(any("stage=x1_legacy_only" in ln or "stage=x2_switched_off" in ln
                             for ln in lines(self.text, "widen")))

    def test_tripplanner_is_reported_not_changed(self):
        self.assertFalse(any("stage=tp_planner" in ln for ln in lines(self.text, "widen")))
        self.assertTrue(any("group=tripplanner" in ln and "stage=tp_planner" in ln
                            for ln in lines(self.text, "stage")))

    def test_sets_monthly_budget(self):
        self.assertTrue(any("after=150.00" in ln for ln in lines(self.text, "budget")))

    def test_prints_final_state_with_connection_off(self):
        c = lines(self.text, "connection")
        self.assertEqual(len(c), 1)
        self.assertIn("enabled=False", c[0])
        self.assertIn("monthly_budget_usd=150.00", c[0])


class ApplyTest(unittest.TestCase):
    def test_commits_and_is_idempotent(self):
        conn = FakeConn(dev_world())
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        db = conn.db
        for key in ("w2_writer_new", "t3_tenant_writer"):
            self.assertEqual(scopes_of(db, key), BOTH, key)
        for key in ("w1_writer", "t11_tenant_shadow", "x1_legacy_only", "x2_switched_off", "tp_planner", "e1_embed"):
            self.assertEqual(scopes_of(db, key), AWS, key)
        self.assertEqual(scopes_of(db, "j1_judge"), BOTH)
        c = anthropic_conn(db)
        self.assertFalse(c["enabled"])
        self.assertEqual(c["secret_name"], script.DEV_SECRET)
        self.assertEqual(c["monthly_budget_usd"], Decimal("150.00"))
        self.assertTrue(any(d["model_key"] == "anth-beta" and d["connection_key"] == "anthropic-direct"
                            for d in db["deployments"]))
        self.assertEqual(len(lines(text, "committed")), 1)
        self.assertTrue(lines(text, "state"))          # the read-only verification ran

        after_first = copy.deepcopy(conn.db)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        self.assertEqual(conn.db, after_first)
        self.assertIn("changes=0", lines(text, "committed")[0])

    def test_keeps_an_admin_budget(self):
        world = dev_world()
        anthropic_conn(world)["monthly_budget_usd"] = Decimal("40.00")
        conn = FakeConn(world)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        self.assertEqual(anthropic_conn(conn.db)["monthly_budget_usd"], Decimal("40.00"))
        self.assertTrue(lines(text, "budget_kept"))

    def test_zero_budget_is_named_not_changed(self):
        world = dev_world()
        anthropic_conn(world)["monthly_budget_usd"] = Decimal("0")
        conn = FakeConn(world)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        self.assertEqual(anthropic_conn(conn.db)["monthly_budget_usd"], Decimal("0"))
        self.assertTrue(lines(text, "budget_note"))

    def test_seed_row_goes_behind_a_slow_primary(self):
        world = dev_world()
        for d in world["deployments"]:
            if d["model_key"] == "anth-beta" and d["connection_key"] == "acc3":
                d["priority"] = 120
        conn = FakeConn(world)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        row = next(d for d in conn.db["deployments"]
                   if d["model_key"] == "anth-beta" and d["connection_key"] == "anthropic-direct")
        self.assertEqual(row["priority"], 121)

    def test_enabled_connection_is_left_enabled_and_noted(self):
        world = dev_world()
        anthropic_conn(world)["enabled"] = True
        conn = FakeConn(world)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        self.assertTrue(anthropic_conn(conn.db)["enabled"])
        self.assertTrue(lines(text, "note"))


class LegacyKeyTest(unittest.TestCase):
    def test_legacy_key_never_gets_an_api_road(self):
        # Even a legacy key catalogued as Converse with an anthropic-direct row: the gateway never sends it there.
        world = dev_world()
        for m in world["catalog"]:
            if m["model_key"] == "sonnet":
                m["api_style"] = "converse"
        world["deployments"].append(dep("sonnet", "anthropic-direct", "claude-legacy-s", 100))
        conn = FakeConn(world)
        code, text = run(conn, "apply")
        self.assertEqual(code, 0, text)
        self.assertEqual(scopes_of(conn.db, "x1_legacy_only"), AWS)
        self.assertTrue(any("model=sonnet" in ln and "legacy key" in ln for ln in lines(text, "gap")))


class RefuseTest(unittest.TestCase):
    def assert_refused(self, world, why):
        conn = FakeConn(world)
        before = copy.deepcopy(conn.db)
        code, text = run(conn, "apply")
        self.assertEqual(code, 1, text)
        self.assertEqual(conn.db, before)
        self.assertTrue(any(why in ln for ln in lines(text, "refuse")), text)
        self.assertFalse(lines(text, "widen"))

    def test_prod_secret_name(self):
        world = dev_world()
        anthropic_conn(world)["secret_name"] = "aa-llm/prod/anthropic-direct"
        self.assert_refused(world, "secret_name is not aa-llm/dev/anthropic-direct")

    def test_another_connection_outside_dev(self):
        world = dev_world()
        world["connections"][1]["secret_name"] = "aa-llm/prod/openai-direct"
        self.assert_refused(world, "outside aa-llm/dev/")

    def test_usage_secret_outside_dev(self):
        world = dev_world()
        world["policies"] = [{"connection_key": "openai-direct", "alert_pct": 80, "hard_stop": True,
                              "usage_secret_name": "aa-llm/stg/openai-usage"}]
        self.assert_refused(world, "usage_secret_name is outside")

    def test_no_scopes_column(self):
        world = dev_world()
        world["has_scopes"] = False
        self.assert_refused(world, "migration 311")

    def test_no_connection(self):
        world = dev_world()
        world["connections"] = world["connections"][:2]
        self.assert_refused(world, "connection anthropic-direct missing")


if __name__ == "__main__":
    unittest.main()
