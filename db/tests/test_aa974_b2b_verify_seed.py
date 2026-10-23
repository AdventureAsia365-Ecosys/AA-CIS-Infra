"""AA-974 (S248): db/scripts/aa974_b2b_verify_seed.py (VND rate + departures for the commercial-rules live check).

No database, no asyncpg: the planners are pure (state in, steps out) and a fake connection answers the script's reads
and records its writes. The real-schema run (Booking migrations bk-001 .. bk-021 + the AA-973 seed + the B2B API on a
throwaway PostgreSQL) is described in docs/implementation-notes/AA-974.md.
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
PATH = "db/scripts/aa974_b2b_verify_seed.py"
_spec = importlib.util.spec_from_file_location("aa974_b2b_verify_seed", ROOT / PATH)
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

_spec973 = importlib.util.spec_from_file_location("aa973_b2b_seed", ROOT / "db/scripts/aa973_b2b_seed.py")
seed973 = importlib.util.module_from_spec(_spec973)
_spec973.loader.exec_module(seed973)

TODAY = date(2026, 10, 23)
TIERS = ('[{"fee_pct": 0, "min_days": 60}, {"fee_pct": 25, "min_days": 30}, {"fee_pct": 50, "min_days": 15}, '
         '{"fee_pct": 75, "min_days": 7}, {"fee_pct": 100, "min_days": 0}]')
POLICY = {"id": "00000000-0000-4000-8000-0000000bc021", "valid_from": date(2026, 10, 1), "tiers": TIERS}


def ids():
    n = iter(range(1, 1000))
    return lambda: f"00000000-0000-4000-8000-{next(n):012d}"


def dep(ident, offset, capacity=2, status="scheduled", seeded=True):
    return {"id": ident, "start_date": TODAY + timedelta(days=offset), "capacity": capacity, "status": status,
            "seeded": seeded}


def fx(ident, as_of, source, approved=True, created_by="someone", rate="1.1"):
    return {"id": ident, "rate_per_usd": rate, "buffer_pct": "0", "as_of": as_of, "source": source,
            "created_by": created_by, "approved": approved, "approved_by": "checker-x" if approved else None}


def aa973_state(**over):
    """What the AA-973 seed apply left on Dev (S248): plan p1 with 2 components, two 2-seat departures, no VND."""
    state = {
        "staff": {script.MAKER: {"active": False}, script.CHECKER: {"active": False}},
        "plans": [{"id": "p1", "source_id": "tour-b", "sellable": True, "components": 2}],
        "plan": {"id": "p1", "source_id": "tour-b", "sellable": True, "components": 2},
        "contract": {"id": "k1", "valid_to": TODAY + timedelta(days=90)},
        "departures": [dep("d1", 14), dep("d2", 21)],
        "fx": [],  # FX_ROWS_SQL reads VND rows only; Dev has BTN / EUR, no VND
    }
    state.update(over)
    return state


def complete_state(**over):
    """After this script's apply: our VND row approved, three 4-seat departures."""
    state = aa973_state(
        departures=[dep("d1", 14), dep("d2", 21), dep("e1", 28, 4), dep("e2", 35, 4), dep("e3", 42, 4)],
        fx=[fx("v1", TODAY, script.FX_SOURCE, created_by=script.MAKER, rate="25000.00000000")],
    )
    state.update(over)
    return state


def verbs(steps):
    return [(s.verb, s.table) for s in steps]


class ShapeTest(unittest.TestCase):
    def test_runner_accepts_the_file(self):
        # Merged as READ_ONLY = True (DRY RUN); the apply is a one-line follow-up PR, so this pins only consistency.
        source = (ROOT / PATH).read_text()
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertIs(rm.script_is_read_only(source), script.READ_ONLY)

    def test_builds_on_the_aa973_seed(self):
        self.assertEqual((script.MAKER, script.CHECKER), (seed973.MAKER, seed973.CHECKER))
        self.assertEqual(script.SUPPLIER_NAME, seed973.SUPPLIER_NAME)
        self.assertEqual(script.CONTRACT_TITLE, seed973.CONTRACT_TITLE)
        self.assertEqual(script.PARTNER_TENANT_ID, seed973.PARTNER_TENANT_ID)
        self.assertIn(seed973.LOCK_KEY, script.LOCK_KEYS)  # same plan's departures: serialised with the AA-973 seed
        self.assertNotEqual(script.DEPARTURE_CAPACITY, seed973.DEPARTURE_CAPACITY)  # ours are told apart by capacity
        self.assertEqual(script.WRITE_ROLE, "bk_owner")

    def test_constants(self):
        self.assertTrue(script.FX_SOURCE.startswith("SYNTHETIC S248"))
        self.assertLessEqual(len(script.FX_SOURCE), 64)  # contract FxLock.source / b2b_quotes_fx_chk
        self.assertEqual(script.FX_CURRENCY, "VND")
        self.assertEqual(script.DEPARTURE_OFFSETS[:3], (28, 35, 42))
        self.assertLess(script.MIN_LEAD_DAYS, min(script.DEPARTURE_OFFSETS))
        self.assertLess(max(script.DEPARTURE_OFFSETS), seed973.MIN_COVER_DAYS + 30)


class FxPlanTest(unittest.TestCase):
    def test_no_vnd_gets_one_row_by_the_maker_approved_by_the_checker(self):
        steps, row = script.plan_fx(aa973_state()["fx"], TODAY, ids())
        self.assertEqual(verbs(steps), [("insert", "fx_rates"), ("approve", "policy_approvals")])
        fid = steps[0].ident
        self.assertEqual(steps[0].args, (fid, "VND", "25000", "0", TODAY, script.FX_SOURCE, script.MAKER))
        self.assertEqual(steps[1].args[:2], (fid, script.CHECKER))  # bk-007 maker-checker: another person
        self.assertIn("'fx_rate'", steps[1].sql)
        self.assertEqual((row["as_of"], row["source"]), (TODAY, script.FX_SOURCE))

    def test_our_approved_row_is_kept_even_on_a_later_day(self):
        rows = [fx("v1", TODAY, script.FX_SOURCE, created_by=script.MAKER)]
        for day in (TODAY, TODAY + timedelta(days=9)):
            steps, row = script.plan_fx(rows, day, ids())
            self.assertEqual((steps, row["id"]), ([], "v1"))

    def test_our_row_without_approval_is_approved(self):
        rows = [fx("v1", TODAY, script.FX_SOURCE, approved=False, created_by=script.MAKER)]
        steps, row = script.plan_fx(rows, TODAY, ids())
        self.assertEqual(verbs(steps), [("approve", "policy_approvals")])
        self.assertEqual(steps[0].args[:2], ("v1", script.CHECKER))
        self.assertTrue(row["approved"])

    def test_a_real_vnd_rate_in_force_is_used_as_is(self):
        rows = [fx("real", TODAY - timedelta(days=2), "Vietcombank", rate="25400")]
        steps, row = script.plan_fx(rows, TODAY, ids())
        self.assertEqual((steps, row["id"]), ([], "real"))

    def test_a_future_or_pending_vnd_row_does_not_count(self):
        rows = [fx("future", TODAY + timedelta(days=3), "x"), fx("pending", TODAY - timedelta(days=1), "y", False)]
        steps, _ = script.plan_fx(rows, TODAY, ids())
        self.assertEqual(verbs(steps), [("insert", "fx_rates"), ("approve", "policy_approvals")])

    def test_someone_elses_pending_row_for_today_is_never_approved(self):
        steps, row = script.plan_fx([fx("pending", TODAY, "staff draft", approved=False)], TODAY, ids())
        self.assertEqual((steps, row), ([], None))


class DeparturePlanTest(unittest.TestCase):
    def test_three_four_seat_departures_at_28_35_42(self):
        steps, deps, missing = script.plan_departures(aa973_state(), TODAY, ids())
        self.assertEqual(verbs(steps), [("insert", "departures")] * 3 + [("touch", "trip_plans")])
        self.assertEqual([s.args[1:5] for s in steps[:3]],
                         [("p1", TODAY + timedelta(days=o), 4, script.MAKER) for o in (28, 35, 42)])
        self.assertEqual([d["start_date"] for d in deps], [TODAY + timedelta(days=o) for o in (28, 35, 42)])
        self.assertEqual(missing, 0)

    def test_aa973_departures_never_count(self):
        # 2-seat AA-973 departures (one sold) are not fresh seats for this check, whatever their date.
        state = aa973_state(departures=[dep("d1", 28), dep("d2", 35)])
        steps, _, _ = script.plan_departures(state, TODAY, ids())
        self.assertEqual([s.args[2] for s in steps if s.table == "departures"],
                         [TODAY + timedelta(days=o) for o in (42, 49, 56)])  # 28 / 35 taken (unique per plan)

    def test_topped_up_when_one_is_cancelled_or_too_close(self):
        state = complete_state(departures=[dep("e1", 28, 4, status="cancelled"), dep("e2", 35, 4), dep("e3", 10, 4),
                                           dep("x", 42, 4, seeded=False)])
        steps, deps, _ = script.plan_departures(state, TODAY, ids())
        self.assertEqual([s.args[2] for s in steps if s.table == "departures"],
                         [TODAY + timedelta(days=49), TODAY + timedelta(days=56)])
        self.assertEqual(deps[0]["id"], "e2")

    def test_nothing_past_the_contract(self):
        state = aa973_state(contract={"id": "k1", "valid_to": TODAY + timedelta(days=40)})
        steps, deps, missing = script.plan_departures(state, TODAY, ids())
        self.assertEqual([s.args[2] for s in steps if s.table == "departures"],
                         [TODAY + timedelta(days=28), TODAY + timedelta(days=35)])
        self.assertEqual(missing, 1)

    def test_second_run_and_a_later_day_write_nothing(self):
        for day in (TODAY, TODAY + timedelta(days=7)):
            steps, deps, missing = script.plan_departures(complete_state(), day, ids())
            self.assertEqual((steps, len(deps), missing), ([], 3, 0))


class RequireSeedTest(unittest.TestCase):
    def test_refused_without_the_aa973_seed(self):
        for over in ({"staff": {}}, {"plan": None}, {"contract": None}):
            with self.assertRaises(script.Refused):
                script.plan_all(aa973_state(**over), TODAY, ids())

    def test_full_plan_on_the_aa973_state(self):
        steps, facts = script.plan_all(aa973_state(), TODAY, ids())
        self.assertEqual(len(steps), 6)  # fx + approval + 3 departures + touch
        self.assertEqual(facts["trip_plan_id"], "p1")
        self.assertEqual(len(facts["new_ids"]), 4)


class FeeTest(unittest.TestCase):
    def test_tiers_and_fee_like_the_booking_app(self):
        self.assertEqual(script.tiers_text(TIERS), "60:0,30:25,15:50,7:75,0:100")
        self.assertEqual([script.fee_pct_for(TIERS, d) for d in (90, 60, 59, 42, 28, 15, 14, 7, 6, 0, -3)],
                         [0, 0, 25, 25, 50, 50, 75, 75, 100, 100, 100])
        self.assertIsNone(script.fee_pct_for(None, 10))


# ── run() against a fake connection ──────────────────────────────────────────


class FakeConn:
    def __init__(self, state, bk021=True, partner=("active", True), rule=TODAY - timedelta(days=9),
                 policy=POLICY, plan_policy=None):
        self.state, self.bk021, self.partner, self.rule = state, bk021, partner, rule
        self.policy, self.plan_policy = policy, plan_policy
        self.executed, self.transactions, self.rolled_back = [], 0, 0

    async def fetchval(self, sql, *args):
        if sql == script.TODAY_SQL:
            return TODAY
        if sql == script.VERSION_SQL:
            return self.bk021
        if sql == script.RULE_SQL:
            return self.rule
        if sql.startswith("SELECT current_user"):
            return "bk_owner"
        raise AssertionError(sql)

    async def fetchrow(self, sql, *args):
        if sql == script.CONTRACT_SQL:
            return self.state["contract"]
        if sql == script.PARTNER_SQL:
            return None if self.partner is None else {"status": self.partner[0], "has_client": self.partner[1]}
        if sql == script.POLICY_SQL:
            if not self.bk021:
                raise AssertionError("bk-021 table read before bk-021")
            return self.policy if args[1] is None else self.plan_policy
        raise AssertionError(sql)

    async def fetch(self, sql, *args):
        st = self.state
        if sql == script.STAFF_SQL:
            return [{"cis_user_id": k, **v} for k, v in st["staff"].items()]
        if sql == script.PLANS_SQL:
            return st["plans"] if st["plan"] is not None else []
        if sql == script.DEPARTURES_SQL:
            return st["departures"]
        if sql == script.FX_ROWS_SQL:
            return st["fx"]
        if sql == script.SETTINGS_SQL:
            return [{"key": k, "value": "3"} for k in script.SETTINGS]
        raise AssertionError(sql)

    async def execute(self, sql, *args):
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
        conn = FakeConn(aa973_state())
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn), [])
        self.assertNotIn("pg_advisory_xact_lock", " ".join(sql for sql, _ in conn.executed))
        self.assertIn("SCRIPT plan verb=insert table=fx_rates id=<new> currency=VND rate_per_usd=25000", out)
        self.assertIn("SCRIPT summary applied=false steps=6", out)
        self.assertIn("SCRIPT verify departure_id=<new> start_date=2026-11-20 capacity=4 days_ahead=28 "
                      "fee_pct_today=50", out)
        self.assertIn("SCRIPT readiness what=cancellation_policy scope=default in_force=true", out)
        self.assertIn("tiers=60:0,30:25,15:50,7:75,0:100", out)
        self.assertIn("SCRIPT verdict ready=true reasons=null", out)

    def test_apply_is_one_transaction_as_bk_owner_under_both_locks_with_one_audit_row_last(self):
        conn = FakeConn(aa973_state())
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        sqls = [sql for sql, _ in conn.executed]
        start = sqls.index("SELECT pg_advisory_xact_lock(hashtext($1))")
        self.assertEqual(sqls[start - 1], "SET LOCAL ROLE bk_owner")
        locks = [args for sql, args in conn.executed if sql.startswith("SELECT pg_advisory_xact_lock")]
        self.assertEqual(locks, [("aa973_b2b_seed",), ("aa974_b2b_verify_seed",)])
        self.assertEqual(len(writes(conn)), 7)  # 6 steps + the audit row
        self.assertTrue(writes(conn)[0].startswith("INSERT INTO booking.fx_rates"))
        self.assertTrue(writes(conn)[1].startswith("INSERT INTO booking.policy_approvals"))
        self.assertTrue(sqls[-1].startswith("INSERT INTO booking.audit_logs"))
        self.assertEqual(conn.executed[-1][1][:3], (script.ACTOR, script.AUDIT_ACTION, "p1"))
        self.assertEqual(conn.rolled_back, 0)
        self.assertRegex(out, r"SCRIPT wrote verb=insert table=fx_rates id=[0-9a-f-]{36} currency=VND")
        self.assertNotIn("<new>", out)

    def test_apply_on_a_complete_seed_writes_nothing_not_even_an_audit_row(self):
        conn = FakeConn(complete_state())
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 0)
        self.assertEqual(writes(conn), [])
        self.assertIn("SCRIPT summary applied=true steps=0", out)
        self.assertIn("SCRIPT verify fx_currency=VND fx_id=v1 rate_per_usd=25000.00000000", out)
        self.assertIn("SCRIPT verify departure_id=e3 start_date=2026-12-04 capacity=4 days_ahead=42", out)

    def test_without_the_aa973_seed_nothing_is_written(self):
        conn = FakeConn(aa973_state(plan=None))
        rc, out = run(script.run(conn, apply=True))
        self.assertEqual(rc, 1)
        self.assertIn("SCRIPT refuse what=aa973_seed", out)
        self.assertEqual(writes(conn), [])

    def test_bk021_missing_is_reported_and_its_tables_are_not_read(self):
        conn = FakeConn(aa973_state(), bk021=False)
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT readiness what=schema version=bk-021 applied=false", out)
        self.assertIn("SCRIPT verdict ready=false reasons=bk-021", out)

    def test_plan_policy_is_reported_and_drives_the_expected_fee(self):
        plan_policy = {"id": "pp", "valid_from": TODAY, "tiers": '[{"min_days": 0, "fee_pct": 10}]'}
        conn = FakeConn(aa973_state(), plan_policy=plan_policy)
        _, out = run(script.run(conn, apply=False))
        self.assertIn("SCRIPT readiness what=cancellation_policy scope=plan in_force=true id=pp", out)
        self.assertIn("days_ahead=28 fee_pct_today=10", out)

    def test_pending_vnd_of_someone_else_is_a_reason(self):
        conn = FakeConn(aa973_state(fx=[fx("pending", TODAY, "staff draft", approved=False)]))
        _, out = run(script.run(conn, apply=False))
        self.assertIn("SCRIPT warn what=fx", out)
        self.assertIn("SCRIPT verdict ready=false reasons=fx", out)

    def test_missing_partner_rule_or_policy_is_reported_not_fatal(self):
        conn = FakeConn(aa973_state(), partner=None, rule=None, policy=None)
        rc, out = run(script.run(conn, apply=False))
        self.assertEqual(rc, 0)
        self.assertIn("SCRIPT verdict ready=false reasons=partner,b2b_rule,cancellation_policy", out)

    def test_output_carries_no_money_or_client_id(self):
        _, out = run(script.run(FakeConn(aa973_state()), apply=True))
        for secret_ish in ("net_amount", "m2m_client_id", "margin", seed973.ROOM_NET, seed973.SERVICE_NET):
            self.assertNotIn(secret_ish, out)


if __name__ == "__main__":
    unittest.main()
