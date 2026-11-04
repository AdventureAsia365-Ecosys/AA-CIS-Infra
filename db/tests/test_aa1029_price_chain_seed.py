"""AA-1029 (S267): db/scripts/aa1029_price_chain_seed.py (invented rate sheet + b2b RRP rule for the tour price chain
live check).

No database: the planners are pure (state in, steps out). The real-schema run (Booking migrations up to bk-039, the
Booking bridge and cost sheet on a throwaway PostgreSQL: seed, re-run = 0 steps, recompute, booking.v_from_prices
serves 235.00 USD for 2 travellers, cleanup, re-seed) is described in docs/implementation-notes/AA-1029.md.
Run: python3 -m unittest discover -s db/tests -v
"""
import importlib.util
import sys
import unittest
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa1029_price_chain_seed.py"
_spec = importlib.util.spec_from_file_location("aa1029_price_chain_seed", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

TODAY = date(2026, 11, 4)
PICK = {"source_id": "tour-b", "title": "Invented Ridge Trek", "country": "Laos", "duration_days": 3}
RULE_IN_FORCE = {"id": "r0", "valid_from": date(2026, 10, 14), "target_margin": Decimal("0.2000"),
                 "floor_margin": Decimal("0.1000"), "peak_uplift_pts": Decimal("0.0500"),
                 "card_fee_pct": Decimal("0.0300"), "rrp_markup_pct": None}


def ids():
    n = iter(range(1, 1000))
    return lambda: f"00000000-0000-4000-8000-{next(n):012d}"


def catalog(pick=PICK, plan_id="p1", have=None):
    return {"role": "booking", "have": have, "pick": pick, "pick_plan_id": plan_id, "refused": []}


def empty_state(**over):
    state = {"staff": {}, "supplier": None, "hotel": None, "room_type": None, "services": {}, "contracts": [],
             "plan": None, "components": [], "busy": ["tour-a"], "rule": dict(RULE_IN_FORCE), "rule_same_day": None}
    state.update(over)
    return state


def complete_state(**over):
    """What a finished seed run leaves (ids p1, rt1, g1, t1, k1, r1)."""
    state = empty_state(
        staff={script.MAKER: {"active": False}, script.CHECKER: {"active": False}},
        supplier={"id": "sup1", "status": "active"}, hotel={"id": "h1", "status": "active"},
        room_type={"id": "rt1", "status": "active"},
        services={"guide": {"id": "g1", "status": "active"}, "transfer": {"id": "t1", "status": "active"}},
        contracts=[{"id": "k1", "status": "published", "valid_from": TODAY, "rates": len(script.SHEET),
                    "valid_to": TODAY + timedelta(days=script.CONTRACT_DAYS)}],
        plan={"id": "p1", "source_id": "tour-b"},
        components=[{"day_no": 1, "room_type_id": "rt1", "service_id": None},
                    {"day_no": 1, "room_type_id": None, "service_id": "g1"},
                    {"day_no": 2, "room_type_id": "rt1", "service_id": None},
                    {"day_no": 2, "room_type_id": None, "service_id": "t1"}],
        busy=["tour-a", "tour-b"],
        rule={**RULE_IN_FORCE, "id": "r1", "valid_from": TODAY, "rrp_markup_pct": Decimal("0.2500")},
    )
    state.update(over)
    return state


def verbs(steps):
    return [(s.verb, s.table) for s in steps]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file(self):
        # The mode lives in the file (run-script takes no arguments): merged READ_ONLY = True / ACTION = "seed"
        # (DRY RUN); the apply and the cleanup are one-line follow-up PRs.
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertIs(rm.script_is_read_only(source), script.READ_ONLY)
        self.assertIn(script.ACTION, ("seed", "cleanup"))

    def test_constants(self):
        self.assertNotEqual(script.MAKER, script.CHECKER)  # bk-007 / bk-008 maker-checker
        for name in (script.SUPPLIER_NAME, script.HOTEL_NAME, script.ROOM_TYPE_NAME, script.CONTRACT_TITLE,
                     *(t for _, t, _ in script.SERVICES)):
            self.assertTrue(name.startswith("SYNTHETIC S267 "), name)
        self.assertFalse(script.MAKER.startswith("cog:"))  # staff_users_cognito_key_chk
        self.assertLess(script.MIN_COVER_DAYS, script.LOW_DAYS)
        self.assertLess(script.LOW_DAYS, script.CONTRACT_DAYS)
        self.assertEqual(script.WRITE_ROLE, "bk_owner")
        self.assertEqual(script.RRP_MARKUP, Decimal("0.25"))  # root ADR 0019 b15


class SeedPlanTest(unittest.TestCase):
    def test_fresh_dev_gets_the_whole_set_in_fk_order(self):
        steps, facts = script.plan_seed(empty_state(), catalog(), TODAY, ids())
        self.assertEqual(verbs(steps), [
            ("insert", "staff_users"), ("insert", "staff_users"), ("insert", "suppliers"), ("insert", "hotels"),
            ("insert", "hotel_room_types"), ("insert", "services"), ("insert", "services"),
            ("insert", "supplier_contracts"), *[("insert", "supplier_rates")] * 6, ("publish", "supplier_contracts"),
            *[("insert", "trip_plan_components")] * 4, ("touch", "trip_plans"),
            ("insert", "pricing_rules"), ("approve", "policy_approvals"),
        ])
        self.assertEqual(facts["trip_plan_id"], "p1")  # the bridge's plan of the picked key, not a new one
        self.assertFalse(facts["new_plan"])
        publish = next(s for s in steps if s.verb == "publish")
        self.assertEqual(publish.args[1], script.CHECKER)
        approve = next(s for s in steps if s.verb == "approve")
        self.assertEqual(approve.args[1], script.CHECKER)
        rule = next(s for s in steps if s.table == "pricing_rules")
        # The ratios of the rule in force are kept; only the RRP markup is added.
        self.assertEqual(rule.args[1:9], (Decimal("0.2000"), Decimal("0.1000"), Decimal("0.0500"), Decimal("0.0300"),
                                          TODAY, script.RULE_NOTE, script.MAKER, Decimal("0.25")))

    def test_rates_are_the_invented_sheet(self):
        steps, _ = script.plan_seed(empty_state(), catalog(), TODAY, ids())
        rates = [s.args for s in steps if s.table == "supplier_rates"]
        # (room_type, service, season, from, to, unit, meal, pax_min, pax_max, net)
        shape = [(r[2] is not None, r[3] is not None, r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11])
                 for r in rates]
        low_end, high_start = TODAY + timedelta(days=90), TODAY + timedelta(days=91)
        end = TODAY + timedelta(days=200)
        self.assertEqual(shape, [
            (True, False, "Low", TODAY, low_end, "room_night", "BB", 2, 2, "100.00"),
            (True, False, "Low", TODAY, low_end, "room_night", "BB", 1, 1, "80.00"),
            (True, False, "High", high_start, end, "room_night", "BB", 2, 2, "140.00"),
            (True, False, "High", high_start, end, "room_night", "BB", 1, 1, "110.00"),
            (False, True, None, TODAY, end, "group", None, None, None, "60.00"),
            (False, True, None, TODAY, end, "person", None, None, None, "20.00"),
        ])
        self.assertTrue(all(r[12] == "USD" and r[14] == script.MAKER for r in rates))

    def test_components_day_one_guide_and_night_day_two_jeep_and_night(self):
        steps, facts = script.plan_seed(empty_state(), catalog(), TODAY, ids())
        comps = sorted((s.args[1], "room" if s.args[2] else "service:" + str(s.args[3]))
                       for s in steps if s.table == "trip_plan_components")
        room, guide, jeep = facts["items"]["room"], facts["items"]["guide"], facts["items"]["transfer"]
        self.assertEqual(comps, sorted([(1, "room"), (1, f"service:{guide}"), (2, "room"), (2, f"service:{jeep}")]))
        self.assertTrue(all(s.args[2] in (None, room) for s in steps if s.table == "trip_plan_components"))

    def test_no_rule_in_force_uses_the_defaults(self):
        steps, facts = script.plan_seed(empty_state(rule=None), catalog(), TODAY, ids())
        rule = next(s for s in steps if s.table == "pricing_rules")
        self.assertEqual(rule.args[1:5], (Decimal("0.15"), Decimal("0.10"), Decimal("0"), Decimal("0.03")))
        self.assertEqual(facts["ratios"], script.DEFAULT_RATIOS)

    def test_a_rule_with_an_rrp_is_used_as_it_is(self):
        rule = {**RULE_IN_FORCE, "rrp_markup_pct": Decimal("0.3000")}
        steps, facts = script.plan_seed(empty_state(rule=rule), catalog(), TODAY, ids())
        self.assertNotIn("pricing_rules", {s.table for s in steps})
        self.assertNotIn("policy_approvals", {s.table for s in steps})
        self.assertEqual(facts["rule"], {"id": "r0", "rrp_markup_pct": Decimal("0.3000"), "new": False})

    def test_a_same_day_rule_without_rrp_is_refused(self):
        with self.assertRaises(script.Refused):
            script.plan_seed(empty_state(rule_same_day="r9"), catalog(), TODAY, ids())

    def test_no_bridge_plan_inserts_one_not_sellable(self):
        steps, facts = script.plan_seed(empty_state(), catalog(plan_id=None), TODAY, ids())
        plan = next(s for s in steps if s.table == "trip_plans" and s.verb == "insert")
        self.assertIn("false, 'b2b'", plan.sql)
        self.assertTrue(facts["new_plan"])
        self.assertNotIn(("touch", "trip_plans"), verbs(steps))

    def test_no_free_tour_is_refused(self):
        with self.assertRaises(script.Refused):
            script.plan_seed(empty_state(), catalog(pick=None), TODAY, ids())

    def test_second_run_writes_nothing(self):
        steps, facts = script.plan_seed(complete_state(), catalog(have=PICK), TODAY, ids())
        self.assertEqual(steps, [])
        self.assertEqual(facts["trip_plan_id"], "p1")

    def test_seed_plan_whose_tour_left_the_catalog_moves_to_a_new_tour(self):
        other = {**PICK, "source_id": "tour-c"}
        steps, facts = script.plan_seed(complete_state(), catalog(pick=other, plan_id="p2", have=None), TODAY, ids())
        self.assertEqual(facts["source_id"], "tour-c")
        self.assertEqual(verbs(steps), [*[("insert", "trip_plan_components")] * 4, ("touch", "trip_plans")])

    def test_contract_ending_soon_is_expired_and_replaced(self):
        short = complete_state()
        short["contracts"][0]["valid_to"] = TODAY + timedelta(days=10)
        steps, _ = script.plan_seed(short, catalog(have=PICK), TODAY, ids())
        self.assertEqual(verbs(steps)[0], ("expire", "supplier_contracts"))
        self.assertEqual(verbs(steps)[1:], [("insert", "supplier_contracts"), *[("insert", "supplier_rates")] * 6,
                                            ("publish", "supplier_contracts")])

    def test_after_cleanup_the_seed_reactivates(self):
        state = complete_state(plan=None, components=[], busy=["tour-a"])
        for key in ("supplier", "hotel", "room_type"):
            state[key]["status"] = "inactive"
        for svc in state["services"].values():
            svc["status"] = "inactive"
        state["contracts"][0]["status"] = "expired"
        steps, _ = script.plan_seed(state, catalog(), TODAY, ids())
        self.assertEqual([v for v, _ in verbs(steps)].count("reactivate"), 5)
        self.assertIn(("publish", "supplier_contracts"), verbs(steps))


class CleanupPlanTest(unittest.TestCase):
    def test_cleanup_removes_components_expires_and_retires(self):
        steps = script.plan_cleanup(complete_state())
        self.assertEqual(verbs(steps), [
            ("delete", "trip_plan_components"), ("touch", "trip_plans"), ("expire", "supplier_contracts"),
            ("retire", "hotel_room_types"), ("retire", "hotels"), ("retire", "services"), ("retire", "services"),
            ("retire", "suppliers"),
        ])
        self.assertNotIn("pricing_rules", {s.table for s in steps})  # rules are append-only

    def test_second_cleanup_writes_nothing(self):
        state = complete_state(plan=None, components=[])
        for key in ("supplier", "hotel", "room_type"):
            state[key]["status"] = "inactive"
        for svc in state["services"].values():
            svc["status"] = "inactive"
        state["contracts"][0]["status"] = "expired"
        self.assertEqual(script.plan_cleanup(state), [])


class ExpectTest(unittest.TestCase):
    def test_expected_from_price_matches_the_booking_integration_test(self):
        # Booking test_aa1029_price_chain: net 150, b2b 185 (150 / 0.82 = 182.93 -> 185), RRP 231.25 -> 235.
        got = script.expected_from_price(script.DEFAULT_RATIOS, Decimal("0.25"))
        self.assertEqual(got, {"net": Decimal("150.00"), "b2b": Decimal("185.00"), "rrp": Decimal("235.00")})

    def test_round_up_to_five(self):
        self.assertEqual(script.round_up(Decimal("180.00")), Decimal("180.00"))
        self.assertEqual(script.round_up(Decimal("180.01")), Decimal("185.00"))


if __name__ == "__main__":
    unittest.main()
