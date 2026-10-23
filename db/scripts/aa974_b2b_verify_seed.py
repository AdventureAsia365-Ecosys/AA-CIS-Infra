"""AA-974 (S248), Dev only: the synthetic data the booking.b2b.v1 commercial-rules live check needs on top of AA-973.

AA-Booking bk-021 / AA-974 adds VND quotes, cancel with a fee (+ dry run), extend once (409 `extend_limit`) and the
daily re-hold limit (429 `rehold_limit`, per proposal ref and per departure). Checking them live on Dev needs two
things the AA-973 seed (`db/scripts/aa973_b2b_seed.py`) does not provide:

- an APPROVED VND FX row in force today (Dev has only BTN and EUR rows; a VND quote without one is 503
  `unavailable`): one row `booking.fx_rates` (VND, 25000 per USD, buffer 0, `as_of` = today UTC, source
  `SYNTHETIC S248 AA-974`) written by the inactive AA-973 seed maker, plus its `booking.policy_approvals` row by the
  inactive AA-973 seed checker (bk-007 maker-checker: the trigger refuses an approval by the row's creator);
- fresh seats: three more departures of the AA-973 seed plan, 4 seats each, 28 / 35 / 42 days ahead (or the next free
  7-day offsets inside the seed contract), `scheduled`, `auto_confirm`: one for extend + confirm + cancel, one for the
  per-proposal re-hold loop, one for the per-departure re-hold loop (the AA-973 departures have 2 seats and the first
  one is sold). Written by the AA-973 seed maker, so the AA-973 seed's cleanup (`ACTION = "cleanup"`) retires them too.

It needs the AA-973 seed applied (seed staff rows, the seed plan with components, the published seed contract) and
refuses otherwise (`SCRIPT refuse`, exit 13, nothing written). It reports, without writing: bk-021 applied, the
synthetic partner (tenant `00000000-0000-4000-8000-00000000c972`), an approved `b2b` rule in force, the B2B settings
(incl. bk-021 `b2b_hold_extend_hours` / `b2b_rehold_limit_per_day`), the B2B cancellation policy in force (its tiers,
so the live check knows the expected fee) and any plan-specific policy, then `SCRIPT verdict ready=true|false`.

Idempotent: the FX row is found by its source, the departures by (seed plan, seed maker, capacity 4, 14+ days
ahead); a second run prints `SCRIPT summary steps=0` and writes nothing (no audit row either). A VND row already in
force from another source is used as it is (no synthetic row written). No cleanup action: `fx_rates` and its approvals
are append-only by design (a quote keeps the rate it was priced at); a later real VND row supersedes the synthetic one
(newest approved `as_of` wins). The departures go with the AA-973 seed cleanup.

Modes (DB Migrate mode=run-script runs it as the RDS master; db/scripts/README.md). run-script takes no arguments, so
the mode is in the file:
- READ_ONLY = True (this file as merged): DRY RUN. The runner opens a read-only session; the script prints the plan
  (`SCRIPT plan ...` per row it would write) and writes nothing.
- Apply: a one-line follow-up PR sets READ_ONLY = False; dispatch again. One transaction, as `bk_owner` (owner of schema
  booking; the master is a member, rl-001), under the AA-973 seed's advisory lock and its own (same plan's departures).
- Local test: `python3 db/scripts/aa974_b2b_verify_seed.py <DSN> [--apply]` (DRY RUN without --apply).

Prints ids, dates, statuses, counts, the FX rate (public through `GET /b2b/v1/fx-rates`) and the fee tiers (the
agency-facing schedule) only: no net amount, margin, client id or personal data (the Actions log of this public repo
is readable).
"""

import json
import uuid
from datetime import timedelta

READ_ONLY = True

SCRIPT_NAME = "aa974_b2b_verify_seed"
ACTOR = f"script:{SCRIPT_NAME}"
AUDIT_ACTION = "seed.b2b_verify_aa974"
LOCK_KEYS = ("aa973_b2b_seed", SCRIPT_NAME)  # same plan's departures as the AA-973 seed: serialise with it
TAG = "SYNTHETIC S248"

# The AA-973 seed's rows this script builds on (db/scripts/aa973_b2b_seed.py).
MAKER = "seed-s248-aa973-maker"
CHECKER = "seed-s248-aa973-checker"
SUPPLIER_NAME = f"{TAG} Supplier"
CONTRACT_TITLE = f"{TAG} B2B verification contract"

PARTNER_TENANT_ID = "00000000-0000-4000-8000-00000000c972"
SETTINGS = ("b2b_quote_valid_hours", "b2b_hold_hours", "b2b_hold_extend_hours", "b2b_rehold_limit_per_day")
REQUIRED_VERSION = "bk-021"

FX_CURRENCY = "VND"
FX_RATE = "25000"   # VND per USD (synthetic, round so a reader can check a quote by hand)
FX_BUFFER = "0"     # selling rate = plain rate
FX_SOURCE = f"{TAG} AA-974"
FX_APPROVAL_NOTE = f"{TAG}: Dev-only synthetic VND rate for the AA-974 live check (seed checker)."

DEPARTURE_OFFSETS = (28, 35, 42, 49, 56, 63, 70)  # days ahead
DEPARTURES_WANTED = 3
DEPARTURE_CAPACITY = 4
MIN_LEAD_DAYS = 14  # a departure closer than this does not count as fresh (extend cap, fee tier)

WRITE_ROLE = "bk_owner"

# ── Reads ────────────────────────────────────────────────────────────────────

TODAY_SQL = "SELECT (now() AT TIME ZONE 'UTC')::date"
# As the master, before the role switch (shared.schema_versions is not booking's).
VERSION_SQL = "SELECT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = $1)"
STAFF_SQL = "SELECT cis_user_id, active FROM booking.staff_users WHERE cis_user_id = ANY($1::text[])"
PLANS_SQL = """
SELECT p.id::text AS id, p.source_id, p.sellable,
       (SELECT count(*) FROM booking.trip_plan_components c WHERE c.trip_plan_id = p.id)::int AS components
  FROM booking.trip_plans p
 WHERE p.source_system = 'cis' AND p.created_by = $1
 ORDER BY p.created_at, p.id
"""
CONTRACT_SQL = """
SELECT k.id::text AS id, k.valid_to
  FROM booking.supplier_contracts k
  JOIN booking.suppliers s ON s.id = k.supplier_id
 WHERE s.created_by = $1 AND s.company_name = $2 AND k.title = $3 AND k.status = 'published'
   AND k.valid_from <= $4 AND k.valid_to >= $4
 ORDER BY k.valid_to DESC, k.id
 LIMIT 1
"""
DEPARTURES_SQL = """
SELECT d.id::text AS id, d.start_date, d.capacity, d.status, d.created_by = $2 AS seeded
  FROM booking.departures d
 WHERE d.trip_plan_id = $1::uuid
 ORDER BY d.start_date, d.id
"""
FX_ROWS_SQL = """
SELECT f.id::text AS id, f.rate_per_usd, f.buffer_pct, f.as_of, f.source, f.created_by,
       a.id IS NOT NULL AS approved, a.approved_by
  FROM booking.fx_rates f
  LEFT JOIN booking.policy_approvals a ON a.fx_rate_id = f.id
 WHERE f.currency = $1
 ORDER BY f.as_of DESC, f.created_at DESC, f.id
"""
PARTNER_SQL = """
SELECT status, m2m_client_id IS NOT NULL AND m2m_client_id <> '' AS has_client
  FROM booking.b2b_partners WHERE tenant_id = $1::uuid
"""
# AA-Booking app/pricing/repository.py RULE_SQL: the newest APPROVED b2b row in force.
RULE_SQL = """
SELECT r.valid_from FROM booking.pricing_rules r
  JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
 WHERE r.channel = 'b2b' AND r.valid_from <= $1
 ORDER BY r.valid_from DESC LIMIT 1
"""
SETTINGS_SQL = "SELECT key, value::text AS value FROM booking.settings WHERE key = ANY($1::text[])"
# bk-021 (only read when it is applied): the approved B2B policy in force today, default (plan NULL) or the plan's.
POLICY_SQL = """
SELECT p.id::text AS id, p.valid_from, p.tiers::text AS tiers
  FROM booking.cancellation_policies p
  JOIN booking.policy_approvals a ON a.cancellation_policy_id = p.id
 WHERE p.channel = 'b2b' AND p.trip_plan_id IS NOT DISTINCT FROM $2::uuid AND p.valid_from <= $1
 ORDER BY p.valid_from DESC, p.created_at DESC
 LIMIT 1
"""

# ── Writes (as bk_owner, one transaction) ────────────────────────────────────

INSERT_FX_SQL = """
INSERT INTO booking.fx_rates (id, currency, rate_per_usd, buffer_pct, as_of, source, created_by)
VALUES ($1::uuid, $2, $3::numeric, $4::numeric, $5::date, $6, $7)
"""
# bk-007: a separate append-only approval row by someone else than the creator (trigger policy_approvals_maker_checker).
APPROVE_FX_SQL = """
INSERT INTO booking.policy_approvals (entity_type, fx_rate_id, approved_by, note) VALUES ('fx_rate', $1::uuid, $2, $3)
"""
INSERT_DEPARTURE_SQL = """
INSERT INTO booking.departures (id, trip_plan_id, start_date, capacity, status, auto_confirm, created_by, updated_by)
VALUES ($1::uuid, $2::uuid, $3::date, $4, 'scheduled', true, $5, $5)
"""
TOUCH_PLAN_SQL = "UPDATE booking.trip_plans SET updated_at = now() WHERE id = $1::uuid"
AUDIT_SQL = """
INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, after, entity_label, summary)
VALUES ('system', $1, $2, 'trip_plan', $3::uuid, $4::jsonb, $5, $6)
"""


class Refused(Exception):
    """The AA-973 seed is not in place: nothing is planned or written."""


class Step:
    """One write of the plan: what it does (printed) and the statement that does it (run on apply)."""

    def __init__(self, verb, table, ident, sql, args, new=False, **detail):
        self.verb, self.table, self.ident = verb, table, ident
        self.sql, self.args, self.new, self.detail = sql, tuple(args), new, detail

    def line(self, applied: bool) -> str:
        shown = self.ident if (applied or not self.new) else "<new>"
        return fields(("wrote" if applied else "plan"), verb=self.verb, table=self.table, id=shown, **self.detail)

    def __repr__(self) -> str:
        return f"Step({self.verb} {self.table} {self.ident})"


def fields(kind: str, **values) -> str:
    """`SCRIPT <kind> k=v ...`; a value with a space or quote is JSON-quoted."""
    parts = []
    for key, value in values.items():
        text = value.isoformat() if hasattr(value, "isoformat") else str(value)
        if value is None:
            text = "null"
        elif isinstance(value, bool):
            text = "true" if value else "false"
        if any(c in text for c in ' "=') or text == "":
            text = json.dumps(text)
        parts.append(f"{key}={text}")
    return f"SCRIPT {kind} " + " ".join(parts) if parts else f"SCRIPT {kind}"


def out(kind: str, **values) -> None:
    print(fields(kind, **values), flush=True)


def new_uuid() -> str:
    return str(uuid.uuid4())


def tiers_text(raw) -> str | None:
    """`60:0,30:25,...` (min_days:fee_pct, most days first) from the policy's tiers JSON."""
    if raw is None:
        return None
    tiers = json.loads(raw) if isinstance(raw, str) else raw
    tiers = sorted(tiers, key=lambda t: -t["min_days"])
    return ",".join(f"{t['min_days']}:{t['fee_pct']}" for t in tiers)


def fee_pct_for(raw, days_before: int):
    """The fee % of the tier with the largest min_days <= max(days, 0) (AA-Booking app/b2b/cancellation.py)."""
    if raw is None:
        return None
    tiers = json.loads(raw) if isinstance(raw, str) else raw
    days = max(days_before, 0)
    fitting = [t for t in tiers if t["min_days"] <= days]
    return max(fitting, key=lambda t: t["min_days"])["fee_pct"] if fitting else None


# ── State ────────────────────────────────────────────────────────────────────


async def load_state(conn, today) -> dict:
    """Everything the plan decides on, read in schema booking (call as bk_owner)."""
    plans = [dict(r) for r in await conn.fetch(PLANS_SQL, MAKER)]
    plan = next((p for p in plans if p["sellable"] and p["components"] > 0), None)
    return {
        "staff": {r["cis_user_id"]: dict(r) for r in await conn.fetch(STAFF_SQL, [MAKER, CHECKER])},
        "plans": plans,
        "plan": plan,
        "contract": (lambda r: dict(r) if r is not None else None)(
            await conn.fetchrow(CONTRACT_SQL, MAKER, SUPPLIER_NAME, CONTRACT_TITLE, today)),
        "departures": [dict(r) for r in await conn.fetch(DEPARTURES_SQL, plan["id"], MAKER)] if plan else [],
        "fx": [dict(r) for r in await conn.fetch(FX_ROWS_SQL, FX_CURRENCY)],
    }


async def load_readiness(conn, today, plan_id, has_bk021: bool) -> dict:
    partner = await conn.fetchrow(PARTNER_SQL, PARTNER_TENANT_ID)
    settings = {r["key"]: r["value"] for r in await conn.fetch(SETTINGS_SQL, list(SETTINGS))}
    policy = plan_policy = None
    if has_bk021:
        row = await conn.fetchrow(POLICY_SQL, today, None)
        policy = dict(row) if row is not None else None
        if plan_id is not None:
            row = await conn.fetchrow(POLICY_SQL, today, plan_id)
            plan_policy = dict(row) if row is not None else None
    return {
        "partner_status": partner["status"] if partner else None,
        "partner_has_client": bool(partner["has_client"]) if partner else False,
        "rule_valid_from": await conn.fetchval(RULE_SQL, today),
        "settings": settings,
        "policy": policy,
        "plan_policy": plan_policy,
    }


# ── Plan (pure: state in, steps out) ─────────────────────────────────────────


def fx_in_force(rows: list, today):
    """The VND row the API prices with today: the newest APPROVED row with as_of <= today."""
    return next((r for r in rows if r["approved"] and r["as_of"] <= today), None)


def require_seed(state: dict) -> None:
    missing = [sid for sid in (MAKER, CHECKER) if sid not in state["staff"]]
    if missing:
        raise Refused(f"AA-973 seed staff rows missing ({','.join(missing)}): apply aa973_b2b_seed first")
    if state["plan"] is None:
        raise Refused("no sellable AA-973 seed plan with components: apply aa973_b2b_seed first")
    if state["contract"] is None:
        raise Refused("no published AA-973 seed contract in force today: run aa973_b2b_seed again")


def plan_fx(rows: list, today, new_id=new_uuid) -> tuple:
    """(steps, row): the writes that make a VND rate in force today, and the row that will be in force."""
    ours = [r for r in rows if r["source"] == FX_SOURCE]
    if ours:
        row = ours[0]
        if row["approved"]:
            return [], row
        # Our row without its approval (never left by this script: one transaction); approve it.
        step = Step("approve", "policy_approvals", row["id"], APPROVE_FX_SQL, (row["id"], CHECKER, FX_APPROVAL_NOTE),
                    entity="fx_rate", by="checker")
        return [step], {**row, "approved": True, "approved_by": CHECKER}
    current = fx_in_force(rows, today)
    if current is not None:
        return [], current  # an approved VND rate from another source is in force: use it, write nothing
    if any(r["as_of"] == today for r in rows):
        return [], None  # (VND, today) is taken by a pending row of someone else: never approve it for them
    fid = new_id()
    row = {"id": fid, "rate_per_usd": FX_RATE, "buffer_pct": FX_BUFFER, "as_of": today, "source": FX_SOURCE,
           "created_by": MAKER, "approved": True, "approved_by": CHECKER}
    return [
        Step("insert", "fx_rates", fid, INSERT_FX_SQL, (fid, FX_CURRENCY, FX_RATE, FX_BUFFER, today, FX_SOURCE, MAKER),
             new=True, currency=FX_CURRENCY, rate_per_usd=FX_RATE, buffer_pct=FX_BUFFER, as_of=today, by="maker"),
        Step("approve", "policy_approvals", fid, APPROVE_FX_SQL, (fid, CHECKER, FX_APPROVAL_NOTE), new=True,
             entity="fx_rate", by="checker"),
    ], row


def fresh_departure(d: dict, today) -> bool:
    return (d["seeded"] and d["capacity"] == DEPARTURE_CAPACITY and d["status"] != "cancelled"
            and d["start_date"] >= today + timedelta(days=MIN_LEAD_DAYS))


def plan_departures(state: dict, today, new_id=new_uuid) -> tuple:
    """(steps, departures, missing): top up the plan's 4-seat seed departures to DEPARTURES_WANTED."""
    pid, valid_to = state["plan"]["id"], state["contract"]["valid_to"]
    have = [{"id": d["id"], "start_date": d["start_date"]} for d in state["departures"] if fresh_departure(d, today)]
    used = {d["start_date"] for d in state["departures"]}  # unique (trip_plan_id, start_date), any status
    steps, missing = [], DEPARTURES_WANTED - len(have)
    for offset in DEPARTURE_OFFSETS:
        if missing <= 0:
            break
        day = today + timedelta(days=offset)
        if day in used or (valid_to is not None and day > valid_to):
            continue
        did = new_id()
        steps.append(Step("insert", "departures", did, INSERT_DEPARTURE_SQL,
                          (did, pid, day, DEPARTURE_CAPACITY, MAKER), new=True, start_date=day,
                          capacity=DEPARTURE_CAPACITY))
        have.append({"id": did, "start_date": day})
        missing -= 1
    if steps:
        steps.append(Step("touch", "trip_plans", pid, TOUCH_PLAN_SQL, (pid,), why="products change signal"))
    return steps, sorted(have, key=lambda d: d["start_date"]), max(missing, 0)


def plan_all(state: dict, today, new_id=new_uuid) -> tuple:
    """(steps, facts) for the whole run. Raises Refused when the AA-973 seed is not in place."""
    require_seed(state)
    fx_steps, fx_row = plan_fx(state["fx"], today, new_id)
    dep_steps, deps, missing = plan_departures(state, today, new_id)
    steps = fx_steps + dep_steps
    facts = {"trip_plan_id": state["plan"]["id"], "source_id": state["plan"]["source_id"], "fx": fx_row,
             "departures": deps, "short_departures": missing, "new_ids": {s.ident for s in steps if s.new}}
    return steps, facts


def step_counts(steps: list) -> dict:
    counts: dict = {}
    for s in steps:
        key = f"{s.verb}:{s.table}"
        counts[key] = counts.get(key, 0) + 1
    return counts


# ── Run ──────────────────────────────────────────────────────────────────────


def report_readiness(ready: dict, today, has_bk021: bool) -> list:
    """Prints the readiness lines; returns the reasons the live check would fail."""
    reasons = []
    out("readiness", what="schema", version=REQUIRED_VERSION, applied=has_bk021)
    if not has_bk021:
        reasons.append(REQUIRED_VERSION)
    out("readiness", what="partner", tenant_id=PARTNER_TENANT_ID, status=ready["partner_status"],
        has_client=ready["partner_has_client"])
    if ready["partner_status"] != "active" or not ready["partner_has_client"]:
        reasons.append("partner")
    out("readiness", what="b2b_rule", approved_in_force=ready["rule_valid_from"] is not None,
        valid_from=ready["rule_valid_from"], on=today)
    if ready["rule_valid_from"] is None:
        reasons.append("b2b_rule")
    for key in SETTINGS:
        out("readiness", what="setting", key=key, value=ready["settings"].get(key))
        if key not in ready["settings"]:
            reasons.append(key)
    if has_bk021:
        policy, plan_policy = ready["policy"], ready["plan_policy"]
        out("readiness", what="cancellation_policy", scope="default", in_force=policy is not None,
            id=policy["id"] if policy else None, valid_from=policy["valid_from"] if policy else None,
            tiers=tiers_text(policy["tiers"]) if policy else None)
        if plan_policy is not None:
            out("readiness", what="cancellation_policy", scope="plan", in_force=True, id=plan_policy["id"],
                valid_from=plan_policy["valid_from"], tiers=tiers_text(plan_policy["tiers"]))
        if policy is None and plan_policy is None:
            reasons.append("cancellation_policy")
    return reasons


async def _as_owner(conn) -> None:
    await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")


async def _write(conn, steps: list, facts: dict) -> None:
    """Runs the steps in order, then one audit row (only when something was written)."""
    for step in steps:
        await conn.execute(step.sql, *step.args)
    if steps:
        await conn.execute(AUDIT_SQL, ACTOR, AUDIT_ACTION, facts["trip_plan_id"],
                           json.dumps({"steps": step_counts(steps)}, sort_keys=True),
                           f"{TAG} AA-974 verify seed",
                           f"{TAG} AA-974 verify seed: {len(steps)} writes (VND rate, departures)")


async def run(conn, apply: bool) -> int:
    out(SCRIPT_NAME, mode="APPLY" if apply else "DRY_RUN")
    today = await conn.fetchval(TODAY_SQL)
    has_bk021 = bool(await conn.fetchval(VERSION_SQL, REQUIRED_VERSION))
    async with conn.transaction():
        await _as_owner(conn)
        out("pass", role=await conn.fetchval("SELECT current_user"), what="read booking")
        state = await load_state(conn, today)
        ready = await load_readiness(conn, today, state["plan"]["id"] if state["plan"] else None, has_bk021)
    reasons = report_readiness(ready, today, has_bk021)
    try:
        steps, facts = plan_all(state, today)
        if apply:
            async with conn.transaction():
                await _as_owner(conn)
                for key in LOCK_KEYS:
                    await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", key)
                state = await load_state(conn, today)  # again, under the locks: the steps run on what is there now
                steps, facts = plan_all(state, today)
                await _write(conn, steps, facts)
    except Refused as e:
        out("refuse", what="aa973_seed", why=str(e))
        return 1

    for step in steps:
        print(step.line(applied=apply), flush=True)
    out("summary", applied=apply, steps=len(steps), counts=json.dumps(step_counts(steps), sort_keys=True))

    def shown(value):  # an id this DRY RUN only planned is not the id the apply will write
        return "<new>" if not apply and value in facts["new_ids"] else value

    out("verify", source_system="cis", source_id=facts["source_id"], trip_plan_id=facts["trip_plan_id"],
        component_id="tp:" + facts["trip_plan_id"])
    fx = facts["fx"]
    if fx is None:
        reasons.append("fx")
        out("warn", what="fx", currency=FX_CURRENCY, as_of=today,
            why="a pending VND row of someone else holds today's slot: approve it on /booking/pricing/fx-rates")
    else:
        out("verify", fx_currency=FX_CURRENCY, fx_id=shown(fx["id"]), rate_per_usd=fx["rate_per_usd"],
            buffer_pct=fx["buffer_pct"], as_of=fx["as_of"], source=fx["source"], synthetic=fx["source"] == FX_SOURCE)
    tiers = (ready["plan_policy"] or ready["policy"] or {}).get("tiers")
    for d in facts["departures"]:
        days = (d["start_date"] - today).days
        out("verify", departure_id=shown(d["id"]), start_date=d["start_date"], capacity=DEPARTURE_CAPACITY,
            days_ahead=days, fee_pct_today=fee_pct_for(tiers, days))
    if facts["short_departures"]:
        reasons.append("departures")
        out("warn", what="departures", missing=facts["short_departures"],
            why="no free 7-day offset inside the seed contract: run aa973_b2b_seed (renews it), then this again")
    out("verdict", ready=not reasons, reasons=",".join(reasons) or None)
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="VND rate + departures for the AA-974 live check (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write (default: DRY RUN)")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply)
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
