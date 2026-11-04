"""AA-1029 (S267), Dev only: load one invented supplier rate sheet and one b2b margin rule so the tour price chain can
be checked live end to end (AA-Booking bk-039: cost sheet -> booking.v_from_prices -> TripPlanner tour page).

The Booking staff sessions the agent has on Dev are read-only (the E2E user: 403 `e2e_read_only` on every write), so
the rate-sheet load is SQL as `bk_owner`, writing exactly the rows the Booking rate-sheet import
(`POST /booking/suppliers/{ref}/rate-sheets`, `app/supply/rate_sheet.py`) writes for the invented fixture sheet of the
Booking integration test `test_aa1029_price_chain.py`. The workbook parser itself is checked end to end by that test in
the Booking CI. Every row is clearly synthetic (prefix `SYNTHETIC S267`, written by two inactive seed staff rows):

- two `booking.staff_users` rows, the maker and the checker (`active = false`: they can never sign in; a published
  contract and an approved pricing rule both need two different people, bk-007 / bk-008 maker-checker);
- one invented supplier, one hotel with one twin room type (max occupancy 2), one `guide` service (per group) and one
  `transfer` service (per person), all `active`;
- the invented rate sheet: one USD contract valid today .. today + 200 days, written as a draft by the maker and
  published by the checker, with the six rates of the fixture sheet (room: Low until day 90, double 100 / single 80 per
  room night; High after, 140 / 110; guide 60 per group; transfer 20 per person; contract validity);
- the components of ONE catalog tour (the E2E tour): day 1 the guide and the room, day 2 the transfer and the room.
  The tour is the seed's own plan when a run already made one (its components point at the seed room type), else the
  first `catalog.v_tour` key by `source_id` with at least 2 days whose Booking plan (made by `bk_trip_plan_sync`) has no
  component and no price row yet, so no real commercial row is touched; a plan is inserted (not sellable) only when the
  bridge has not made one yet;
- the margin rule: when the approved `b2b` rule in force today has no RRP markup (bk-039 `rrp_markup_pct`), a new
  `b2b` rule dated today with the same ratios (or 15 % / 10 % / 0 / 3 % when none is in force) and
  `rrp_markup_pct = 0.25` (root ADR 0019 b15), created by the maker and approved by the checker. A rule already in
  force with an RRP markup is used as it is;
- one `booking.audit_logs` row per run that changed something (`actor_ref = script:aa1029_price_chain_seed`).

Nothing else is written: the Booking worker's `bk_price_recompute` watermark sees the new rates, approval and
components and fills the plan's price matrix (b2b rows with the RRP) on its next tick, with no hand step. The run
prints the expected from price (`SCRIPT expect …`, the same arithmetic as the integration test: net 150 per person for
2 travellers, b2b price 185, RRP 235) and what `booking.v_from_prices` serves now (`SCRIPT verify …`), so a later DRY
RUN dispatch shows the price once the worker ran.

Idempotent: a run finds its rows by the seed staff ids and the fixed names and writes only what is missing, so a second
run prints `SCRIPT summary steps=0` and writes nothing (no audit row either).

ACTION = "cleanup" removes the seed plan's components (the next recompute then drops its computed price rows), expires
the published seed contracts (the only change bk-008 allows; a draft is deleted with its rates) and retires the
supplier, hotel, room type and services (`inactive`). Pricing rules and approvals are append-only by design: the
seed rule stays until a later rule supersedes it. The plan and the two staff rows stay.

Modes (DB Migrate mode=run-script runs it as the RDS master; db/scripts/README.md). run-script takes no arguments, so
the mode is in the file:
- READ_ONLY = True (this file as merged): DRY RUN. The runner opens a read-only session; the script prints the plan
  (`SCRIPT plan ...` per row it would write), the readiness and the verify lines, and writes nothing.
- Apply: a one-line follow-up PR sets READ_ONLY = False; dispatch again. One transaction, as `bk_owner` (the owner of
  schema booking; the master is a member), under an advisory lock.
- Cleanup: a one-line follow-up PR sets ACTION = "cleanup" (with READ_ONLY = False to apply it).
- Local test: `python3 db/scripts/aa1029_price_chain_seed.py <DSN> [--apply] [--cleanup]` (DRY RUN without --apply).

Reads `catalog.v_tour` as the first role of CATALOG_ROLES the master may switch to; everything in schema booking is
read and written as `bk_owner`. Prints ids, statuses, dates, counts, the catalog tour's source_id / title and the public
RRP (`booking.v_from_prices` is public by contract price.from.v1); the invented nets of the seed itself are printed in
the expect line only (synthetic numbers, no real supplier).
"""

import json
import uuid
from datetime import timedelta
from decimal import Decimal

READ_ONLY = False
ACTION = "seed"  # "seed" or "cleanup"

SCRIPT_NAME = "aa1029_price_chain_seed"
ACTOR = f"script:{SCRIPT_NAME}"
AUDIT_ACTION = "seed.price_chain_synthetic"
LOCK_KEY = SCRIPT_NAME
TAG = "SYNTHETIC S267"
NOTE = f"{TAG}: Dev-only invented rate sheet for the tour price chain live check (AA-1029). Not a real supplier."

MAKER = "seed-s267-aa1029-maker"
CHECKER = "seed-s267-aa1029-checker"
STAFF = ((MAKER, f"{TAG} seed (rate sheet maker)"), (CHECKER, f"{TAG} seed (rate sheet checker)"))
STAFF_ROLE = "contracting"

SUPPLIER_NAME = f"{TAG} Lumen Ridge Travel Co"
SUPPLIER_CATEGORIES = ["hotel", "guide", "transport"]
HOTEL_NAME = f"{TAG} Lumen Ridge Lodge"
ROOM_TYPE_NAME = f"{TAG} Garden Twin"
ROOM_MAX_OCCUPANCY = 2
GUIDE = ("guide", f"{TAG} Ridge guide", "group")       # (service_type, title, unit)
TRANSFER = ("transfer", f"{TAG} Valley jeep", "person")
SERVICES = (GUIDE, TRANSFER)
CONTRACT_TITLE = f"{TAG} invented rate sheet"
CONTRACT_REFERENCE = "AA-1029-S267"
CURRENCY = "USD"
CONTRACT_DAYS = 200    # the sheet covers today .. today + 200
LOW_DAYS = 90          # Low season today .. today + 90, High after
MIN_COVER_DAYS = 60    # an existing contract is reused only while it covers today .. today + 60
MIN_TOUR_DAYS = 2
PLAN_NOTES = f"{TAG} seed (AA-1029): Dev-only components for the tour price chain live check."

# The invented sheet: (target, season, first day offset, last day offset or None = contract end, meal plan,
# pax_min, pax_max, net). Offsets are from the run day; the room rows are per room night.
SHEET = (
    ("room", "Low", 0, LOW_DAYS, "BB", 2, 2, "100.00"),
    ("room", "Low", 0, LOW_DAYS, "BB", 1, 1, "80.00"),
    ("room", "High", LOW_DAYS + 1, None, "BB", 2, 2, "140.00"),
    ("room", "High", LOW_DAYS + 1, None, "BB", 1, 1, "110.00"),
    ("guide", None, 0, None, None, None, None, "60.00"),
    ("transfer", None, 0, None, None, None, None, "20.00"),
)
# Day 1: the guide and a night; day 2: the jeep and a night.
COMPONENTS = ((1, "guide"), (1, "room"), (2, "transfer"), (2, "room"))

DEFAULT_RATIOS = {"target_margin": Decimal("0.15"), "floor_margin": Decimal("0.10"),
                  "peak_uplift_pts": Decimal("0"), "card_fee_pct": Decimal("0.03")}
RRP_MARKUP = Decimal("0.25")
RULE_NOTE = f"{TAG}: b2b rule with the suggested retail price markup (AA-1029 live check, root ADR 0019 b15)."

CATALOG_ROLES = ("booking", "tripplanner")
WRITE_ROLE = "bk_owner"

# ── Reads ────────────────────────────────────────────────────────────────────

TODAY_SQL = "SELECT (now() AT TIME ZONE 'UTC')::date"
BK039_SQL = "SELECT EXISTS (SELECT 1 FROM shared.schema_versions WHERE version = 'bk-039')"
STAFF_SQL = "SELECT cis_user_id, active FROM booking.staff_users WHERE cis_user_id = ANY($1::text[])"
SUPPLIER_SQL = """
SELECT id::text AS id, status FROM booking.suppliers
 WHERE created_by = $1 AND company_name = $2 ORDER BY created_at LIMIT 1
"""
HOTEL_SQL = "SELECT id::text AS id, status FROM booking.hotels WHERE supplier_id = $1::uuid AND name = $2"
ROOM_TYPE_SQL = "SELECT id::text AS id, status FROM booking.hotel_room_types WHERE hotel_id = $1::uuid AND name = $2"
SERVICE_SQL = """
SELECT id::text AS id, status FROM booking.services
 WHERE supplier_id = $1::uuid AND service_type = $2 AND title = $3
"""
CONTRACTS_SQL = """
SELECT k.id::text AS id, k.status, k.valid_from, k.valid_to,
       (SELECT count(*) FROM booking.supplier_rates r WHERE r.supplier_contract_id = k.id)::int AS rates
  FROM booking.supplier_contracts k
 WHERE k.supplier_id = $1::uuid AND k.title = $2
 ORDER BY k.created_at, k.id
"""
SEED_PLAN_SQL = """
SELECT p.id::text AS id, p.source_id FROM booking.trip_plans p
 WHERE p.source_system = 'cis'
   AND EXISTS (SELECT 1 FROM booking.trip_plan_components c
                WHERE c.trip_plan_id = p.id AND c.hotel_room_type_id = $1::uuid)
 ORDER BY p.created_at, p.id
"""
COMPONENTS_SQL = """
SELECT day_no, hotel_room_type_id::text AS room_type_id, service_id::text AS service_id
  FROM booking.trip_plan_components WHERE trip_plan_id = $1::uuid
"""
# Keys whose plan already carries commercial data (components or price rows): never chosen for the seed.
BUSY_SQL = """
SELECT p.source_id FROM booking.trip_plans p
 WHERE p.source_system = 'cis'
   AND (EXISTS (SELECT 1 FROM booking.trip_plan_components c WHERE c.trip_plan_id = p.id)
        OR EXISTS (SELECT 1 FROM booking.trip_plan_prices r WHERE r.trip_plan_id = p.id))
"""
PLAN_BY_KEY_SQL = "SELECT id::text AS id FROM booking.trip_plans WHERE source_system = 'cis' AND source_id = $1"
# The quote's rule read (AA-Booking app/pricing/repository.py): the newest APPROVED b2b row in force.
RULE_SQL = """
SELECT r.id::text AS id, r.valid_from, r.target_margin, r.floor_margin, r.peak_uplift_pts, r.card_fee_pct,
       r.rrp_markup_pct
  FROM booking.pricing_rules r
  JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
 WHERE r.channel = 'b2b' AND r.valid_from <= $1
 ORDER BY r.valid_from DESC LIMIT 1
"""
RULE_SAME_DAY_SQL = "SELECT id::text FROM booking.pricing_rules WHERE channel = 'b2b' AND valid_from = $1"
CATALOG_HAS_SQL = """
SELECT source_id, left(coalesce(title, ''), 80) AS title, country, duration_days FROM catalog.v_tour
 WHERE source_system = 'cis' AND source_id = $1
"""
CATALOG_PICK_SQL = """
SELECT source_id, left(coalesce(title, ''), 80) AS title, country, duration_days FROM catalog.v_tour
 WHERE source_system = 'cis' AND coalesce(duration_days, 0) >= $2 AND source_id <> ALL($1::text[])
 ORDER BY source_id LIMIT 1
"""
FROM_PRICE_SQL = """
SELECT amount::text AS amount, currency, season, valid_to, priced_at FROM booking.v_from_prices
 WHERE source_system = 'cis' AND source_id = $1
"""
PRICE_ROWS_SQL = """
SELECT count(*) FILTER (WHERE channel = 'b2b')::int AS b2b, count(*) FILTER (WHERE computed)::int AS computed
  FROM booking.trip_plan_prices WHERE trip_plan_id = $1::uuid
"""

# ── Writes (as bk_owner, one transaction) ────────────────────────────────────

INSERT_STAFF_SQL = "INSERT INTO booking.staff_users (cis_user_id, name, role, active) VALUES ($1, $2, $3, false)"
DEACTIVATE_STAFF_SQL = "UPDATE booking.staff_users SET active = false WHERE cis_user_id = $1 AND active"
INSERT_SUPPLIER_SQL = """
INSERT INTO booking.suppliers (id, company_name, categories, internal_notes, status, created_by, updated_by)
VALUES ($1::uuid, $2, $3::text[], $4, 'active', $5, $5)
"""
INSERT_HOTEL_SQL = """
INSERT INTO booking.hotels (id, supplier_id, name, internal_notes, status, created_by, updated_by)
VALUES ($1::uuid, $2::uuid, $3, $4, 'active', $5, $5)
"""
INSERT_ROOM_TYPE_SQL = """
INSERT INTO booking.hotel_room_types (id, hotel_id, name, max_occupancy, bed_types, internal_notes, status,
                                      created_by, updated_by)
VALUES ($1::uuid, $2::uuid, $3, $4, ARRAY['twin']::text[], $5, 'active', $6, $6)
"""
INSERT_SERVICE_SQL = """
INSERT INTO booking.services (id, supplier_id, service_type, title, unit, internal_notes, status, created_by,
                              updated_by)
VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, 'active', $7, $7)
"""
SET_STATUS_SQL = {
    table: f"UPDATE booking.{table} SET status = $2, updated_by = $3 WHERE id = $1::uuid AND status <> $2"
    for table in ("suppliers", "hotels", "hotel_room_types", "services")
}
INSERT_CONTRACT_SQL = """
INSERT INTO booking.supplier_contracts (id, supplier_id, title, reference, valid_from, valid_to, currency, notes,
                                        status, created_by)
VALUES ($1::uuid, $2::uuid, $3, $4, $5::date, $6::date, $7, $8, 'draft', $9)
"""
# The columns the rate-sheet import writes (AA-Booking app/supply/rates.py create_rate).
INSERT_RATE_SQL = """
INSERT INTO booking.supplier_rates (id, supplier_contract_id, hotel_room_type_id, service_id, season, valid_from,
                                    valid_to, unit, meal_plan, pax_min, pax_max, net_amount, currency, notes,
                                    created_by, updated_by)
VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6::date, $7::date, $8, $9, $10, $11, $12::numeric, $13, $14,
        $15, $15)
"""
PUBLISH_CONTRACT_SQL = """
UPDATE booking.supplier_contracts SET status = 'published', published_by = $2, published_at = now()
 WHERE id = $1::uuid AND status = 'draft'
"""
EXPIRE_CONTRACT_SQL = """
UPDATE booking.supplier_contracts SET status = 'expired', expired_by = $2, expired_at = now()
 WHERE id = $1::uuid AND status = 'published'
"""
DELETE_DRAFT_RATES_SQL = "DELETE FROM booking.supplier_rates WHERE supplier_contract_id = $1::uuid"
DELETE_DRAFT_CONTRACT_SQL = "DELETE FROM booking.supplier_contracts WHERE id = $1::uuid AND status = 'draft'"
INSERT_PLAN_SQL = """
INSERT INTO booking.trip_plans (id, source_system, source_id, sellable, default_channel, commercial_notes, created_by,
                                updated_by)
VALUES ($1::uuid, 'cis', $2, false, 'b2b', $3, $4, $4)
"""
TOUCH_PLAN_SQL = "UPDATE booking.trip_plans SET updated_at = now() WHERE id = $1::uuid"
DELETE_COMPONENTS_SQL = "DELETE FROM booking.trip_plan_components WHERE trip_plan_id = $1::uuid"
INSERT_COMPONENT_SQL = """
INSERT INTO booking.trip_plan_components (trip_plan_id, day_no, hotel_room_type_id, service_id, created_by)
VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5)
"""
INSERT_RULE_SQL = """
INSERT INTO booking.pricing_rules (id, channel, target_margin, floor_margin, peak_uplift_pts, card_fee_pct, valid_from,
                                   note, created_by, rrp_markup_pct)
VALUES ($1::uuid, 'b2b', $2, $3, $4, $5, $6::date, $7, $8, $9)
"""
APPROVE_RULE_SQL = """
INSERT INTO booking.policy_approvals (entity_type, pricing_rule_id, approved_by, note)
VALUES ('pricing_rule', $1::uuid, $2, $3)
"""
AUDIT_SQL = """
INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, after, entity_label, summary)
VALUES ('system', $1, $2, 'trip_plan', $3::uuid, $4::jsonb, $5, $6)
"""


class Refused(Exception):
    """The seed cannot be planned: nothing is written."""


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


# ── State ────────────────────────────────────────────────────────────────────


async def load_state(conn, today) -> dict:
    """Everything the seed and the cleanup decide on, read in schema booking (call as bk_owner)."""
    state = {
        "staff": {r["cis_user_id"]: dict(r) for r in await conn.fetch(STAFF_SQL, [m for m, _ in STAFF])},
        "supplier": None, "hotel": None, "room_type": None, "services": {}, "contracts": [],
        "plan": None, "components": [],
        "busy": [r["source_id"] for r in await conn.fetch(BUSY_SQL)],
        "rule": None, "rule_same_day": None,
    }
    row = await conn.fetchrow(SUPPLIER_SQL, MAKER, SUPPLIER_NAME)
    if row is not None:
        state["supplier"] = dict(row)
        sup = row["id"]
        hotel = await conn.fetchrow(HOTEL_SQL, sup, HOTEL_NAME)
        if hotel is not None:
            state["hotel"] = dict(hotel)
            room = await conn.fetchrow(ROOM_TYPE_SQL, hotel["id"], ROOM_TYPE_NAME)
            state["room_type"] = dict(room) if room is not None else None
        for kind, title, _ in SERVICES:
            svc = await conn.fetchrow(SERVICE_SQL, sup, kind, title)
            if svc is not None:
                state["services"][kind] = dict(svc)
        state["contracts"] = [dict(r) for r in await conn.fetch(CONTRACTS_SQL, sup, CONTRACT_TITLE)]
    if state["room_type"] is not None:
        plans = await conn.fetch(SEED_PLAN_SQL, state["room_type"]["id"])
        if plans:
            state["plan"] = {"id": plans[0]["id"], "source_id": plans[0]["source_id"]}
            state["components"] = [dict(r) for r in await conn.fetch(COMPONENTS_SQL, plans[0]["id"])]
    rule = await conn.fetchrow(RULE_SQL, today)
    state["rule"] = dict(rule) if rule is not None else None
    state["rule_same_day"] = await conn.fetchval(RULE_SAME_DAY_SQL, today)
    return state


async def read_catalog(conn, state: dict, roles=CATALOG_ROLES) -> dict:
    """The seed plan's tour in catalog.v_tour, or the tour a new seed would go on. Tries each role in turn (its own
    transaction, SET LOCAL ROLE); `role` None = no role could read the catalog."""
    refused = []
    for role in roles:
        try:
            async with conn.transaction():
                await conn.execute(f"SET LOCAL ROLE {role}")
                have = None
                if state["plan"] is not None:
                    row = await conn.fetchrow(CATALOG_HAS_SQL, state["plan"]["source_id"])
                    have = dict(row) if row is not None else None
                pick = await conn.fetchrow(CATALOG_PICK_SQL, state["busy"], MIN_TOUR_DAYS)
            return {"role": role, "have": have, "pick": dict(pick) if pick is not None else None, "refused": refused}
        except Exception as e:  # noqa: BLE001 — a refused role switch or read: try the next role
            refused.append(f"{role}:{type(e).__name__}")
    return {"role": None, "have": None, "pick": None, "refused": refused}


# ── Plans (pure: state in, steps out) ────────────────────────────────────────


def usable_contract(k: dict, today) -> bool:
    return (k["status"] == "published" and k["valid_from"] <= today and k["valid_to"] is not None
            and k["valid_to"] >= today + timedelta(days=MIN_COVER_DAYS) and k["rates"] == len(SHEET))


def sheet_rates(cid: str, items: dict, today, new_id=new_uuid) -> list:
    """The invented sheet as supplier_rates inserts (the import's rows for this contract)."""
    end = today + timedelta(days=CONTRACT_DAYS)
    steps = []
    for target, season, first, last, meal, pax_min, pax_max, net in SHEET:
        rid = new_id()
        room_id = items["room"] if target == "room" else None
        service_id = None if target == "room" else items[target]
        unit = "room_night" if target == "room" else dict((k, u) for k, _, u in SERVICES)[target]
        start, stop = today + timedelta(days=first), (today + timedelta(days=last)) if last is not None else end
        steps.append(Step("insert", "supplier_rates", rid, INSERT_RATE_SQL,
                          (rid, cid, room_id, service_id, season, start, stop, unit, meal, pax_min, pax_max, net,
                           CURRENCY, NOTE, MAKER),
                          new=True, target=target, season=season, unit=unit, pax=f"{pax_min}-{pax_max}"
                          if pax_min else None, valid_from=start, valid_to=stop))
    return steps


def plan_seed(state: dict, catalog: dict, today, new_id=new_uuid) -> tuple:
    """(steps, facts): the writes that make the seed complete, and the ids the live check needs."""
    steps = []
    for sid, name in STAFF:
        row = state["staff"].get(sid)
        if row is None:
            steps.append(Step("insert", "staff_users", sid, INSERT_STAFF_SQL, (sid, name, STAFF_ROLE),
                              active=False))
        elif row["active"]:
            steps.append(Step("deactivate", "staff_users", sid, DEACTIVATE_STAFF_SQL, (sid,)))

    def ensure(table: str, row, insert_sql: str, args_for, **detail) -> str:
        if row is None:
            ident = new_id()
            steps.append(Step("insert", table, ident, insert_sql, args_for(ident), new=True, **detail))
            return ident
        if row["status"] != "active":
            steps.append(Step("reactivate", table, row["id"], SET_STATUS_SQL[table], (row["id"], "active", MAKER)))
        return row["id"]

    sup = ensure("suppliers", state["supplier"], INSERT_SUPPLIER_SQL,
                 lambda i: (i, SUPPLIER_NAME, SUPPLIER_CATEGORIES, NOTE, MAKER), name=SUPPLIER_NAME)
    hotel = ensure("hotels", state["hotel"], INSERT_HOTEL_SQL,
                   lambda i: (i, sup, HOTEL_NAME, NOTE, MAKER), name=HOTEL_NAME)
    items = {"room": ensure("hotel_room_types", state["room_type"], INSERT_ROOM_TYPE_SQL,
                            lambda i: (i, hotel, ROOM_TYPE_NAME, ROOM_MAX_OCCUPANCY, NOTE, MAKER),
                            name=ROOM_TYPE_NAME)}
    for kind, title, unit in SERVICES:
        items[kind] = ensure("services", state["services"].get(kind), INSERT_SERVICE_SQL,
                             lambda i, k=kind, t=title, u=unit: (i, sup, k, t, u, NOTE, MAKER), name=title)

    usable = [k for k in state["contracts"] if usable_contract(k, today)]
    keep = usable[-1] if usable else None
    for k in state["contracts"]:
        if k is keep:
            continue
        if k["status"] == "draft":
            steps.append(Step("delete", "supplier_rates", k["id"], DELETE_DRAFT_RATES_SQL, (k["id"],),
                              of="draft contract"))
            steps.append(Step("delete", "supplier_contracts", k["id"], DELETE_DRAFT_CONTRACT_SQL, (k["id"],)))
        elif k["status"] == "published":
            steps.append(Step("expire", "supplier_contracts", k["id"], EXPIRE_CONTRACT_SQL, (k["id"], CHECKER),
                              why="does not cover the next days or lacks rates"))
    if keep is not None:
        contract = {"id": keep["id"], "valid_to": keep["valid_to"]}
    else:
        cid, end = new_id(), today + timedelta(days=CONTRACT_DAYS)
        contract = {"id": cid, "valid_to": end}
        steps.append(Step("insert", "supplier_contracts", cid, INSERT_CONTRACT_SQL,
                          (cid, sup, CONTRACT_TITLE, CONTRACT_REFERENCE, today, end, CURRENCY, NOTE, MAKER),
                          new=True, status="draft", valid_from=today, valid_to=end, currency=CURRENCY))
        steps.extend(sheet_rates(cid, items, today, new_id))
        steps.append(Step("publish", "supplier_contracts", cid, PUBLISH_CONTRACT_SQL, (cid, CHECKER), new=True,
                          by="checker"))

    plan = state["plan"] if (state["plan"] is not None and catalog["have"] is not None) else None
    if plan is None:
        pick = catalog["pick"]
        if pick is None:
            raise Refused(f"no catalog.v_tour key of at least {MIN_TOUR_DAYS} days without components or prices")
        plan = {"id": catalog.get("pick_plan_id"), "source_id": pick["source_id"]}
        if plan["id"] is None:
            plan["id"] = new_id()
            steps.append(Step("insert", "trip_plans", plan["id"], INSERT_PLAN_SQL,
                              (plan["id"], plan["source_id"], PLAN_NOTES, MAKER), new=True,
                              source_id=plan["source_id"], sellable=False))
            new_plan = True
        else:
            new_plan = False
        current = []
    else:
        current, new_plan = state["components"], False
    pid = plan["id"]

    wanted = {(day, items["room"] if what == "room" else None, None if what == "room" else items[what])
              for day, what in COMPONENTS}
    have = {(c["day_no"], c["room_type_id"], c["service_id"]) for c in current}
    if have != wanted:
        if current:
            steps.append(Step("delete", "trip_plan_components", pid, DELETE_COMPONENTS_SQL, (pid,), rows=len(current)))
        for day, room_id, service_id in sorted(wanted, key=lambda w: (w[0], w[1] or "", w[2] or "")):
            steps.append(Step("insert", "trip_plan_components", pid, INSERT_COMPONENT_SQL,
                              (pid, day, room_id, service_id, MAKER), new=new_plan, day_no=day,
                              target="room_type" if room_id else "service"))
        if not new_plan:
            steps.append(Step("touch", "trip_plans", pid, TOUCH_PLAN_SQL, (pid,), why="recompute watermark"))

    rule = state["rule"]
    if rule is not None and rule["rrp_markup_pct"] is not None:
        rule_facts = {"id": rule["id"], "rrp_markup_pct": rule["rrp_markup_pct"], "new": False}
        ratios = {k: rule[k] for k in DEFAULT_RATIOS}
    else:
        if state["rule_same_day"] is not None:
            raise Refused("a b2b rule dated today exists without an approved RRP markup: set the RRP in the admin")
        ratios = {k: rule[k] for k in DEFAULT_RATIOS} if rule is not None else dict(DEFAULT_RATIOS)
        rule_id = new_id()
        steps.append(Step("insert", "pricing_rules", rule_id, INSERT_RULE_SQL,
                          (rule_id, ratios["target_margin"], ratios["floor_margin"], ratios["peak_uplift_pts"],
                           ratios["card_fee_pct"], today, RULE_NOTE, MAKER, RRP_MARKUP),
                          new=True, channel="b2b", valid_from=today, rrp_markup_pct=RRP_MARKUP,
                          ratios_from="rule in force" if rule is not None else "defaults"))
        steps.append(Step("approve", "policy_approvals", rule_id, APPROVE_RULE_SQL,
                          (rule_id, CHECKER, f"{TAG} approval (AA-1029)"), new=True, by="checker"))
        rule_facts = {"id": rule_id, "rrp_markup_pct": RRP_MARKUP, "new": True}

    facts = {"trip_plan_id": pid, "source_id": plan["source_id"], "contract_id": contract["id"],
             "contract_valid_to": contract["valid_to"], "rule": rule_facts, "ratios": ratios, "items": items,
             "new_plan": new_plan, "new_ids": {s.ident for s in steps if s.new}}
    return steps, facts


def plan_cleanup(state: dict) -> list:
    """The writes that retire every seed row: components, contracts, supply. Rules and approvals stay."""
    steps = []
    plan = state["plan"]
    if plan is not None and state["components"]:
        pid = plan["id"]
        steps.append(Step("delete", "trip_plan_components", pid, DELETE_COMPONENTS_SQL, (pid,),
                          rows=len(state["components"])))
        steps.append(Step("touch", "trip_plans", pid, TOUCH_PLAN_SQL, (pid,), why="recompute watermark"))
    for k in state["contracts"]:
        if k["status"] == "published":
            steps.append(Step("expire", "supplier_contracts", k["id"], EXPIRE_CONTRACT_SQL, (k["id"], CHECKER)))
        elif k["status"] == "draft":
            steps.append(Step("delete", "supplier_rates", k["id"], DELETE_DRAFT_RATES_SQL, (k["id"],),
                              of="draft contract"))
            steps.append(Step("delete", "supplier_contracts", k["id"], DELETE_DRAFT_CONTRACT_SQL, (k["id"],)))
    rows = [("hotel_room_types", state["room_type"]), ("hotels", state["hotel"])]
    rows += [("services", state["services"].get(kind)) for kind, _, _ in SERVICES]
    rows.append(("suppliers", state["supplier"]))
    for table, row in rows:
        if row is not None and row["status"] == "active":
            steps.append(Step("retire", table, row["id"], SET_STATUS_SQL[table], (row["id"], "inactive", MAKER)))
    return steps


def step_counts(steps: list) -> dict:
    counts: dict = {}
    for s in steps:
        key = f"{s.verb}:{s.table}"
        counts[key] = counts.get(key, 0) + 1
    return counts


def round_up(amount: Decimal, step: Decimal = Decimal("5")) -> Decimal:
    """Booking's selling-price rounding (app/pricing/engine.py): up to the next multiple of 5."""
    q = (amount / step).to_integral_value(rounding="ROUND_CEILING")
    return (q * step).quantize(Decimal("0.01"))


def expected_from_price(ratios: dict, rrp_markup: Decimal) -> dict:
    """The RRP for 2 travellers on a Low start (the integration test's arithmetic): 2 nights x double 100 + guide 60 +
    jeep 2 x 20 = 300 / 2 = 150 net per person; price = net / (1 - target - peak - card fee) rounded up to 5; RRP =
    price x (1 + markup) rounded up to 5. Peak uplift does not apply (the season label is Low)."""
    net = Decimal("150.00")
    divisor = Decimal(1) - ratios["target_margin"] - ratios["card_fee_pct"]
    price = round_up(net / divisor)
    return {"net": net, "b2b": price, "rrp": round_up(price * (Decimal(1) + rrp_markup))}


# ── Run ──────────────────────────────────────────────────────────────────────


async def _as_owner(conn) -> None:
    await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")


async def _write(conn, steps: list, pid, action: str) -> None:
    for step in steps:
        await conn.execute(step.sql, *step.args)
    if steps and pid is not None:
        await conn.execute(AUDIT_SQL, ACTOR, AUDIT_ACTION, pid,
                           json.dumps({"action": action, "steps": step_counts(steps)}, sort_keys=True),
                           f"{TAG} {action}", f"{TAG} {action}: {len(steps)} writes (AA-1029 live check)")


async def _plan_id_for_pick(conn, catalog: dict) -> None:
    if catalog["pick"] is not None:
        catalog["pick_plan_id"] = await conn.fetchval(PLAN_BY_KEY_SQL, catalog["pick"]["source_id"])


async def run(conn, apply: bool, action: str = "seed") -> int:
    if action not in ("seed", "cleanup"):
        out("refuse", what="action", action=action)
        return 1
    out(SCRIPT_NAME, mode="APPLY" if apply else "DRY_RUN", action=action)
    today = await conn.fetchval(TODAY_SQL)
    async with conn.transaction():
        await _as_owner(conn)
        out("pass", role=await conn.fetchval("SELECT current_user"), what="read booking")
        if not await conn.fetchval(BK039_SQL):
            out("refuse", what="bk-039", why="AA-Booking bk-039 (price chain storage) is not applied on this database")
            return 1
        state = await load_state(conn, today)
    catalog = {"role": None, "have": None, "pick": None, "refused": []}
    if action == "seed":
        catalog = await read_catalog(conn, state)
        out("catalog", role=catalog["role"], refused=",".join(catalog["refused"]) or None,
            seed_plan=state["plan"]["source_id"] if state["plan"] else None,
            seed_plan_in_catalog=catalog["have"] is not None)
        if catalog["role"] is None:
            out("refuse", what="catalog_read", tried=",".join(CATALOG_ROLES))
            return 1
        async with conn.transaction():
            await _as_owner(conn)
            await _plan_id_for_pick(conn, catalog)
    rule = state["rule"]
    out("readiness", what="b2b_rule", approved_in_force=rule is not None,
        valid_from=rule["valid_from"] if rule else None,
        rrp_markup=rule["rrp_markup_pct"] if rule else None, on=today)

    def plan(st, cat) -> tuple:
        if action == "cleanup":
            return plan_cleanup(st), None
        return plan_seed(st, cat, today)

    try:
        steps, facts = plan(state, catalog)
        if apply:
            async with conn.transaction():
                await _as_owner(conn)
                await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", LOCK_KEY)
                state = await load_state(conn, today)  # again, under the lock: the steps run on what is there now
                await _plan_id_for_pick(conn, catalog)
                steps, facts = plan(state, catalog)
                pid = facts["trip_plan_id"] if facts else (state["plan"]["id"] if state["plan"] else None)
                await _write(conn, steps, pid, action)
    except Refused as e:
        out("refuse", what="seed", why=str(e))
        return 1

    for step in steps:
        print(step.line(applied=apply), flush=True)
    out("summary", action=action, applied=apply, steps=len(steps),
        counts=json.dumps(step_counts(steps), sort_keys=True))
    if facts is None:
        return 0

    def shown(value):  # an id this DRY RUN only planned is not the id the apply will write
        return "<new>" if not apply and value in facts["new_ids"] else value

    tour = catalog["have"] or catalog["pick"] or {}
    out("verify", source_system="cis", source_id=facts["source_id"], title=tour.get("title"),
        country=tour.get("country"), trip_plan_id=shown(facts["trip_plan_id"]))
    out("verify", contract_id=shown(facts["contract_id"]), currency=CURRENCY, valid_to=facts["contract_valid_to"],
        rule_id=shown(facts["rule"]["id"]), rrp_markup=facts["rule"]["rrp_markup_pct"])
    expect = expected_from_price(facts["ratios"], Decimal(facts["rule"]["rrp_markup_pct"]))
    out("expect", what="from_price", source_id=facts["source_id"], currency=CURRENCY, pax=2, season="Low",
        net_per_person=expect["net"], b2b=expect["b2b"], rrp=expect["rrp"])
    async with conn.transaction():
        await _as_owner(conn)
        row = await conn.fetchrow(FROM_PRICE_SQL, facts["source_id"])
        rows = None
        if facts["trip_plan_id"] not in facts["new_ids"]:
            rows = await conn.fetchrow(PRICE_ROWS_SQL, facts["trip_plan_id"])
    out("verify", what="from_price_now", source_id=facts["source_id"],
        amount=row["amount"] if row else None, currency=row["currency"] if row else None,
        season=row["season"] if row else None, priced_at=row["priced_at"] if row else None,
        price_rows_b2b=rows["b2b"] if rows else 0, computed_rows=rows["computed"] if rows else 0,
        why=None if row else "the Booking worker's bk_price_recompute fills it on its next tick")
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY, action=ACTION)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Invented rate sheet + b2b RRP rule for the AA-1029 live check")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="write (default: DRY RUN)")
    parser.add_argument("--cleanup", action="store_true", help="retire what the seed wrote")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, apply=args.apply, action="cleanup" if args.cleanup else "seed")
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
