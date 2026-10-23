"""AA-973 (S248): db/scripts/aa973_b2b_seed.py (synthetic B2B supply for the booking.b2b.v1 live check).

No database, no asyncpg: the planners are pure (state in, steps out) and a fake connection answers the script's reads
and records its writes. The real-schema run (Booking migrations bk-001 .. bk-020 + the B2B API on a throwaway
PostgreSQL) is described in docs/implementation-notes/AA-973.md.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import sys
import unittest
from datetime import date, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa973_b2b_seed.py"
_spec = importlib.util.spec_from_file_location("aa973_b2b_seed", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

TODAY = date(2026, 10, 23)
CATALOG = {"role": "booking", "have": {}, "refused": [],
           "pick": {"source_id": "tour-b", "title": "Tour B", "country": "Laos", "duration_days": 2}}


def ids():
    n = iter(range(1, 1000))
    return lambda: f"00000000-0000-4000-8000-{next(n):012d}"


def empty_state(**over):
    state = {"staff": {}, "supplier": None, "hotel": None, "room_type": None, "service": None, "contracts": [],
             "plans": [], "components": {}, "departures": {}, "taken": ["tour-a"]}
    state.update(over)
    return state


def complete_state(**over):
    """What a finished seed run leaves (ids p1, rt1, sv1, k1, d1, d2)."""
    state = empty_state(
        staff={script.MAKER: {"active": False}, script.CHECKER: {"active": False}},
        supplier={"id": "sup1", "status": "active"}, hotel={"id": "h1", "status": "active"},
        room_type={"id": "rt1", "status": "active"}, service={"id": "sv1", "status": "active"},
        contracts=[{"id": "k1", "status": "published", "valid_from": TODAY, "rates": 2,
                    "valid_to": TODAY + timedelta(days=script.CONTRACT_DAYS)}],
        plans=[{"id": "p1", "source_id": "tour-b", "sellable": True}],
        components={"p1": [{"day_no": 1, "room_type_id": "rt1", "service_id": None},
                           {"day_no": 1, "room_type_id": None, "service_id": "sv1"}]},
        departures={"p1": [dep("d1", 14), dep("d2", 21)]},
        taken=["tour-a", "tour-b"],
    )
    state.update(over)
    return state


def dep(ident, offset, status="scheduled", seeded=True, referenced=False):
    return {"id": ident, "trip_plan_id": "p1", "start_date": TODAY + timedelta(days=offset), "capacity": 2,
            "status": status, "seeded": seeded, "referenced": referenced}


def catalog_with_plan():
    return {**CATALOG, "have": {"tour-b": CATALOG["pick"]}}


def verbs(steps):
    return [(s.verb, s.table) for s in steps]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file(self):
        # The mode lives in the file (run-script takes no arguments): merged as READ_ONLY = True / ACTION = "seed"
        # (DRY RUN); the apply and the cleanup are one-line follow-up PRs, so this test pins only consistency.
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertIs(rm.script_is_read_only(source), script.READ_ONLY)
        self.assertIn(script.ACTION, ("seed", "cleanup"))

    def test_constants(self):
        self.assertEqual(script.PARTNER_TENANT_ID, "00000000-0000-4000-8000-00000000c972")
        self.assertNotEqual(script.MAKER, script.CHECKER)  # bk-008 maker-checker
        for name in (script.SUPPLIER_NAME, script.HOTEL_NAME, script.ROOM_TYPE_NAME, script.SERVICE_TITLE,
                     script.CONTRACT_TITLE):
            self.assertTrue(name.startswith("SYNTHETIC S248 "), name)
        self.assertFalse(script.MAKER.startswith("cog:"))  # staff_users_cognito_key_chk
        self.assertLessEqual(max(script.DEPARTURE_OFFSETS), script.MIN_COVER_DAYS)
        self.assertLess(script.MIN_COVER_DAYS, script.CONTRACT_DAYS)
        self.assertEqual(script.WRITE_ROLE, "bk_owner")


class SeedPlanTest(unittest.TestCase):
    def test_fresh_dev_gets_the_whole_set_in_fk_order(self):
        steps, facts = script.plan_seed(empty_state(), CATALOG, TODAY, ids())
        self.assertEqual(verbs(steps), [
            ("insert", "staff_users"), ("insert", "staff_users"), ("insert", "suppliers"), ("insert", "hotels"),
            ("insert", "hotel_room_types"), ("insert", "services"), ("insert", "supplier_contracts"),
            ("insert", "supplier_rates"), ("insert", "supplier_rates"), ("publish", "supplier_contracts"),
            ("insert", "trip_plans"), ("insert", "trip_plan_components"), ("insert", "trip_plan_components"),
            ("insert", "departures"), ("insert", "departures"),
        ])
        staff = [s for s in steps if s.table == "staff_users"]
        self.assertEqual([s.args for s in staff], [(script.MAKER, script.STAFF[0][1], "contracting"),
                                                   (script.CHECKER, script.STAFF[1][1], "contracting")])
        self.assertIn("false)", staff[0].sql)  # inactive: can never sign in
        contract = steps[6]
        self.assertEqual(contract.args[4:7], (TODAY, TODAY + timedelta(days=90), "USD"))
        self.assertEqual(contract.args[-1], script.MAKER)
        self.assertEqual(steps[9].args, (contract.ident, script.CHECKER))  # published by the other person
        room_rate, service_rate = steps[7].args, steps[8].args
        self.assertEqual((room_rate[2], room_rate[3], room_rate[6]), (steps[4].ident, None, "room_night"))
        self.assertEqual((service_rate[2], service_rate[3], service_rate[6]), (None, steps[5].ident, "person"))
        self.assertEqual(steps[10].args[1], "tour-b")  # the catalog pick, never a tour that has a plan
        self.assertEqual([s.args[2] for s in steps[-2:]], [TODAY + timedelta(days=14), TODAY + timedelta(days=21)])
        self.assertEqual(facts["source_id"], "tour-b")
        self.assertEqual(len(facts["departure_ids"]), 2)
        self.assertTrue(facts["new_plan"])
        self.assertNotIn(("touch", "trip_plans"), verbs(steps))  # a new plan row is its own signal

    def test_second_run_writes_nothing(self):
        steps, facts = script.plan_seed(complete_state(), catalog_with_plan(), TODAY, ids())
        self.assertEqual(steps, [])
        self.assertEqual((facts["trip_plan_id"], facts["contract_id"], facts["departure_ids"]),
                         ("p1", "k1", ["d1", "d2"]))
        self.assertEqual(facts["new_ids"], set())

    def test_a_later_day_still_writes_nothing(self):
        later = TODAY + timedelta(days=10)
        steps, _ = script.plan_seed(complete_state(), catalog_with_plan(), later, ids())
        self.assertEqual(steps, [])

    def test_contract_ending_soon_is_expired_and_replaced(self):
        old = {"id": "k1", "status": "published", "valid_from": TODAY - timedelta(days=80), "rates": 2,
               "valid_to": TODAY + timedelta(days=10)}
        steps, facts = script.plan_seed(complete_state(contracts=[old]), catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps), [("expire", "supplier_contracts"), ("insert", "supplier_contracts"),
                                        ("insert", "supplier_rates"), ("insert", "supplier_rates"),
                                        ("publish", "supplier_contracts")])
        self.assertEqual(steps[0].args, ("k1", script.CHECKER))
        self.assertNotEqual(facts["contract_id"], "k1")

    def test_stray_draft_is_removed_with_its_rates(self):
        draft = {"id": "k0", "status": "draft", "valid_from": TODAY, "valid_to": None, "rates": 1}
        state = complete_state(contracts=[draft] + complete_state()["contracts"])
        steps, _ = script.plan_seed(state, catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps), [("delete", "supplier_rates"), ("delete", "supplier_contracts")])

    def test_departures_are_topped_up_on_free_dates(self):
        deps = [dep("d1", 14, status="cancelled", referenced=True), dep("d2", 21)]
        steps, facts = script.plan_seed(complete_state(departures={"p1": deps}), catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps), [("insert", "departures"), ("touch", "trip_plans")])
        self.assertEqual(steps[0].args[2], TODAY + timedelta(days=28))  # 14 and 21 are taken (unique per plan)
        self.assertEqual(facts["departure_ids"][0], "d2")

    def test_started_departures_do_not_count(self):
        deps = [dep("d1", -1), dep("d2", 0)]
        steps, _ = script.plan_seed(complete_state(departures={"p1": deps}), catalog_with_plan(), TODAY, ids())
        self.assertEqual([s.args[2] for s in steps if s.table == "departures"],
                         [TODAY + timedelta(days=14), TODAY + timedelta(days=21)])

    def test_components_are_replaced_when_they_differ(self):
        state = complete_state(components={"p1": [{"day_no": 2, "room_type_id": "rt1", "service_id": None}]})
        steps, _ = script.plan_seed(state, catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps), [("delete", "trip_plan_components"), ("insert", "trip_plan_components"),
                                        ("insert", "trip_plan_components"), ("touch", "trip_plans")])
        self.assertEqual({s.args[1:4] for s in steps[1:3]}, {(1, "rt1", None), (1, None, "sv1")})

    def test_after_cleanup_the_seed_reactivates_and_sells_again(self):
        retired = {"status": "inactive"}
        state = complete_state(
            supplier={"id": "sup1", **retired}, hotel={"id": "h1", **retired}, room_type={"id": "rt1", **retired},
            service={"id": "sv1", **retired},
            contracts=[{**complete_state()["contracts"][0], "status": "expired"}],
            plans=[{"id": "p1", "source_id": "tour-b", "sellable": False}], components={"p1": []},
            departures={"p1": [dep("d1", 14, status="cancelled", referenced=True)]},
        )
        steps, _ = script.plan_seed(state, catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps)[:4], [("reactivate", "suppliers"), ("reactivate", "hotels"),
                                            ("reactivate", "hotel_room_types"), ("reactivate", "services")])
        self.assertIn(("update", "trip_plans"), verbs(steps))
        self.assertIn(("publish", "supplier_contracts"), verbs(steps))
        self.assertEqual([s.args[2] for s in steps if s.table == "departures"],
                         [TODAY + timedelta(days=21), TODAY + timedelta(days=28)])

    def test_active_seed_staff_is_switched_off(self):
        state = complete_state(staff={script.MAKER: {"active": True}, script.CHECKER: {"active": False}})
        steps, _ = script.plan_seed(state, catalog_with_plan(), TODAY, ids())
        self.assertEqual(verbs(steps), [("deactivate", "staff_users")])

    def test_plan_whose_tour_left_the_catalog_is_not_reused(self):
        steps, facts = script.plan_seed(complete_state(), CATALOG, TODAY, ids())  # "have" is empty
        self.assertEqual(facts["source_id"], "tour-b")
        self.assertIn(("insert", "trip_plans"), verbs(steps))

    def test_no_free_tour_is_refused(self):
        with self.assertRaises(script.Refused):
            script.plan_seed(empty_state(), {**CATALOG, "pick": None}, TODAY, ids())


class CleanupPlanTest(unittest.TestCase):
    def test_unused_seed_is_removed_children_first(self):
        steps = script.plan_cleanup(complete_state())
        self.assertEqual(verbs(steps), [
            ("delete", "trip_plan_components"), ("delete", "departures"), ("delete", "departures"),
            ("delete", "trip_plans"), ("expire", "supplier_contracts"), ("retire", "hotel_room_types"),
            ("retire", "hotels"), ("retire", "services"), ("retire", "suppliers"),
        ])
        self.assertEqual(steps[4].args, ("k1", script.CHECKER))
        self.assertEqual(steps[-1].args, ("sup1", "inactive", script.MAKER))

    def test_used_departures_are_cancelled_and_the_plan_kept_unsellable(self):
        deps = [dep("d1", 14, referenced=True), dep("d2", 21), dep("dx", 30, seeded=False)]
        steps = script.plan_cleanup(complete_state(departures={"p1": deps}))
        self.assertEqual(verbs(steps)[:4], [("delete", "trip_plan_components"), ("cancel", "departures"),
                                            ("delete", "departures"), ("update", "trip_plans")])
        self.assertEqual(steps[3].args, ("p1", False, script.MAKER))
        self.assertNotIn("dx", [s.ident for s in steps])  # not the seed's: left alone

    def test_draft_contract_is_deleted_with_its_rates(self):
        state = complete_state(contracts=[{"id": "k0", "status": "draft", "valid_from": TODAY, "valid_to": None,
                                           "rates": 2}])
        steps = script.plan_cleanup(state)
        self.assertIn(("delete", "supplier_rates"), verbs(steps))
        self.assertLess(verbs(steps).index(("delete", "supplier_rates")),
                        verbs(steps).index(("delete", "supplier_contracts")))

    def test_second_cleanup_writes_nothing(self):
        retired = {"status": "inactive"}
        state = complete_state(
            supplier={"id": "sup1", **retired}, hotel={"id": "h1", **retired}, room_type={"id": "rt1", **retired},
            service={"id": "sv1", **retired},
            contracts=[{**complete_state()["contracts"][0], "status": "expired"}],
            plans=[{"id": "p1", "source_id": "tour-b", "sellable": False}], components={"p1": []},
            departures={"p1": [dep("d1", 14, status="cancelled", referenced=True)]},
        )
        self.assertEqual(script.plan_cleanup(state), [])


# ── run() against a fake connection ──────────────────────────────────────────


class FakeConn:
    """Answers the script's reads from a state dict; records every execute; can refuse role switches."""

    def __init__(self, state, refuse_roles=(), partner=("active", True), rule=TODAY - timedelta(days=9)):
        self.state, self.refuse_roles = state, set(refuse_roles)
        self.partner, self.rule = partner, rule
        self.executed, self.transactions, self.rolled_back = [], 0, 0

    async def fetchval(self, sql, *args):
        if sql == script.TODAY_SQL:
            return TODAY
        if sql == script.RULE_SQL:
            return self.rule
        if sql.startswith("SELECT current_user"):
            return "bk_owner"
        raise AssertionError(sql)

    async def fetchrow(self, sql, *args):
        st = self.state
        if sql == script.SUPPLIER_SQL:
            return st["supplier"]
        if sql == script.HOTEL_SQL:
            return st["hotel"]
        if sql == script.ROOM_TYPE_SQL:
            return st["room_type"]
        if sql == script.SERVICE_SQL:
            return st["service"]
        if sql == script.PARTNER_SQL:
            return None if self.partner is None else {"status": self.partner[0], "has_client": self.partner[1]}
        if sql == script.CATALOG_PICK_SQL:
            return CATALOG["pick"]
        raise AssertionError(sql)

    async def fetch(self, sql, *args):
        st = self.state
        if sql == script.STAFF_SQL:
            return [{"cis_user_id": k, **v} for k, v in st["staff"].items()]
        if sql == script.PLANS_SQL:
            return st["plans"]
        if sql == script.TAKEN_SQL:
            return [{"source_id": s} for s in st["taken"]]
        if sql == script.CONTRACTS_SQL:
            return st["contracts"]
        if sql == script.COMPONENTS_SQL:
            return [{"trip_plan_id": p, **c} for p, rows in st["components"].items() for c in rows]
        if sql == script.DEPARTURES_SQL:
            return [d for rows in st["departures"].values() for d in rows]
        if sql == script.SETTINGS_SQL:
            return [{"key": k, "value": "48"} for k in script.SETTINGS]
        if sql == script.CATALOG_HAS_SQL:
            return [CATALOG["pick"]] if "tour-b" in args[0] else []
        raise AssertionError(sql)

    async def execute(self, sql, *args):
        if sql.startswith("SET LOCAL ROLE ") and sql.split()[-1] in self.refuse_roles:
            raise PermissionError(sql)
        self.executed.append((" ".join(sql.split()), args))
        return "OK"

    @contextlib.asynccontextmanager
    async def transaction(self):
        self.transactions += 1
        try:
            yield
        except BaseException:
            self.rolled_back += 1
            raise


def run(coro):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(coro)
    return rc, buf.getvalue()


def writes(conn):
    return [sql for sql, _ in conn.executed if sql.split()[0] in ("INSERT", "UPDATE", "DELETE")]


class RunTest(unittest.TestCase):
    def test_dry_run_writes_nothing_and_hides_planned_ids(self):
        conn = FakeConn(empty_state())
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn), [])
        self.assertNotIn("pg_advisory_xact_lock", " ".join(sql for sql, _ in conn.executed))
        self.assertIn("SCRIPT plan verb=insert table=trip_plans id=<new> source_id=tour-b", out)
        self.assertIn("SCRIPT summary action=seed applied=false steps=15", out)
        self.assertIn("SCRIPT verify departure_id=<new> capacity=2", out)
        self.assertIn("SCRIPT verdict ready=true reasons=null", out)

    def test_apply_is_one_transaction_as_bk_owner_with_one_audit_row_last(self):
        conn = FakeConn(empty_state())
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        sqls = [sql for sql, _ in conn.executed]
        start = sqls.index("SELECT pg_advisory_xact_lock(hashtext($1))")
        self.assertEqual(sqls[start - 1], "SET LOCAL ROLE bk_owner")
        self.assertEqual(len(writes(conn)), 16)  # 15 steps + the audit row
        self.assertTrue(sqls[-1].startswith("INSERT INTO booking.audit_logs"))
        audit_args = conn.executed[-1][1]
        self.assertEqual(audit_args[:2], (script.ACTOR, script.AUDIT_ACTION))
        self.assertEqual(conn.rolled_back, 0)
        self.assertRegex(out, r"SCRIPT wrote verb=insert table=trip_plans id=[0-9a-f-]{36} source_id=tour-b")
        self.assertNotIn("<new>", out)

    def test_apply_on_a_complete_seed_writes_nothing_not_even_an_audit_row(self):
        conn = FakeConn(complete_state())
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn), [])
        self.assertIn("SCRIPT summary action=seed applied=true steps=0", out)
        self.assertIn("SCRIPT verify departure_id=d1 capacity=2", out)

    def test_catalog_falls_back_to_the_next_role(self):
        conn = FakeConn(empty_state(), refuse_roles={"booking"})
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT catalog role=tripplanner refused=booking:PermissionError", out)

    def test_no_catalog_role_is_refused_before_any_write(self):
        conn = FakeConn(empty_state(), refuse_roles=set(script.CATALOG_ROLES))
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT refuse what=catalog_read", out)
        self.assertEqual(writes(conn), [])

    def test_missing_partner_or_rule_is_reported_not_fatal(self):
        conn = FakeConn(empty_state(), partner=None, rule=None)
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT verdict ready=false reasons=partner,b2b_rule", out)

    def test_cleanup_apply_and_no_catalog_read(self):
        conn = FakeConn(complete_state(), refuse_roles=set(script.CATALOG_ROLES))
        rc, out = run(script.run(conn, apply=True, action="cleanup"))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT summary action=cleanup applied=true steps=9", out)
        self.assertTrue(writes(conn)[0].startswith("DELETE FROM booking.trip_plan_components"))
        self.assertNotIn("SCRIPT verdict", out)

    def test_unknown_action_is_refused(self):
        rc, out = run(script.run(FakeConn(empty_state()), apply=True, action="drop"))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT refuse what=action", out)

    def test_output_carries_no_money_or_client_id(self):
        conn = FakeConn(empty_state())
        _, out = run(script.run(conn, apply=True))
        for secret_ish in (script.ROOM_NET, script.SERVICE_NET, "net_amount", "m2m_client_id", "margin"):
            self.assertNotIn(secret_ish, out)


if __name__ == "__main__":
    unittest.main()
