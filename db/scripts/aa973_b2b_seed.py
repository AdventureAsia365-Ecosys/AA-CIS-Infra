"""AA-973 (S248), Dev only: synthetic supply so the booking.b2b.v1 flow can be checked live end to end.

The B2B API (AA-Booking `/booking/b2b/v1`: products -> quote -> hold -> confirm into a B2B trip case) needs on Dev a
sellable trip plan whose tour is in `catalog.v_tour`, with bookable components (a room type and a service, bk-019)
priced by a PUBLISHED supplier contract with rates in force (bk-008 / bk-010), and fixed departures with seats
(bk-020). Dev has none of that, so nothing past `GET /products` can be checked. This script writes the smallest such
set, every row clearly synthetic (name prefix `SYNTHETIC S248`, written by two inactive seed staff rows):

- two `booking.staff_users` rows, the contract maker and checker (`active = false`: they can never sign in; a
  published contract needs two different people, bk-008 maker-checker, and the real staff must not appear as the
  authors of synthetic terms);
- one supplier, one hotel with one room type, one `activity` service (all `active`);
- one supplier contract in USD, valid today .. today + 90 days, with one rate per item (room night, per person),
  written as a draft by the maker and published by the checker (rates can only be written under a draft, bk-010);
- the commercial row of ONE catalog tour (`booking.trip_plans`, sellable, default channel b2b): the first
  `catalog.v_tour` row by `source_id` that has no trip plan yet, so no real commercial row is ever touched; a later
  run reuses the plan it created;
- the plan's components (day 1: the room type and the service), the same rows `PUT .../components` writes, and the
  plan's `updated_at` touched as the API does;
- two departures with 2 seats each (14 and 21 days ahead, or the next free 7-day offsets), `auto_confirm`, the rows the
  staff `POST .../departures` writes: the B2B departures route is read-only for the partner and the staff route needs
  a Cognito staff token, so the seed writes them;
- one `booking.audit_logs` row per run that changed something (`actor_ref = script:aa973_b2b_seed`).

It also reports, without writing, whether the rest of the flow is in place: the synthetic partner of tenant
`00000000-0000-4000-8000-00000000c972` (AA-972), an approved `b2b` pricing rule in force today, and the settings
`b2b_quote_valid_hours` / `b2b_hold_hours`. USD contract + USD quote need no FX row.

Idempotent: a run finds its rows by the seed staff ids and the fixed names and writes only what is missing, so a
second run prints `SCRIPT summary steps=0` and writes nothing (no audit row either).

ACTION = "cleanup" retires exactly what the seed wrote, children first: the components of the seed plans; seed
departures (DELETE when no quote or hold line points at them, else `cancelled`); the seed plan (DELETE when no
departure is left on it, else `sellable = false`); the seed contracts (published -> `expired` by the checker, the
only change bk-008 allows; a draft is deleted with its rates); the supplier, hotel, room type and service
(`inactive`). Contracts, rates and suppliers are never deleted by design (bk-008 / bk-010 lock a published contract
and its rates; quotes, holds and a confirmed B2B trip case may reference them), and the two staff rows stay (inactive)
because the kept contract and rates reference them. A seed run after a cleanup re-activates the supply, publishes a
fresh contract and picks new departure dates.

Modes (DB Migrate mode=run-script runs it as the RDS master; db/scripts/README.md). run-script takes no arguments, so
the mode is in the file:
- READ_ONLY = True (this file as merged): DRY RUN. The runner opens a read-only session; the script prints the plan
  (`SCRIPT plan ...` per row it would write) and writes nothing.
- Apply: a one-line follow-up PR sets READ_ONLY = False; dispatch again. One transaction, as `bk_owner` (the owner
  of schema booking; the master is a member, rl-001), under an advisory lock.
- Cleanup: a one-line follow-up PR sets ACTION = "cleanup" (with READ_ONLY = False to apply it).
- Local test: `python3 db/scripts/aa973_b2b_seed.py <DSN> [--apply] [--cleanup]` (DRY RUN without --apply).

Reads `catalog.v_tour` as the first role of CATALOG_ROLES the master may switch to (the views grant SELECT to
`booking` and `tripplanner`, not to `bk_owner`); everything in schema booking is read and written as `bk_owner`.
Prints ids, statuses, dates, counts and the catalog tour's source_id / title only: no net amount, margin, client id
or personal data (the Actions log of this public repo is readable).
"""

import json
import uuid
from datetime import timedelta

READ_ONLY = False
ACTION = "seed"  # "seed" or "cleanup"

SCRIPT_NAME = "aa973_b2b_seed"
ACTOR = f"script:{SCRIPT_NAME}"
AUDIT_ACTION = "seed.b2b_synthetic"
LOCK_KEY = SCRIPT_NAME
TAG = "SYNTHETIC S248"
NOTE = f"{TAG}: Dev-only synthetic data for the booking.b2b.v1 live check (AA-972 / AA-973). Not a real supplier."

MAKER = "seed-s248-aa973-maker"
CHECKER = "seed-s248-aa973-checker"
STAFF = ((MAKER, f"{TAG} seed (contract maker)"), (CHECKER, f"{TAG} seed (contract checker)"))
STAFF_ROLE = "contracting"

PARTNER_TENANT_ID = "00000000-0000-4000-8000-00000000c972"
SETTINGS = ("b2b_quote_valid_hours", "b2b_hold_hours")

SUPPLIER_NAME = f"{TAG} Supplier"
SUPPLIER_CATEGORIES = ["hotel", "activity"]
HOTEL_NAME = f"{TAG} Hotel"
ROOM_TYPE_NAME = f"{TAG} Double"
ROOM_MAX_OCCUPANCY = 3
SERVICE_TYPE = "activity"
SERVICE_TITLE = f"{TAG} Activity"
SERVICE_UNIT = "person"
CONTRACT_TITLE = f"{TAG} B2B verification contract"
CONTRACT_REFERENCE = "AA-973-S248"
CURRENCY = "USD"
ROOM_NET = "80.00"     # per room night, any occupancy (synthetic)
SERVICE_NET = "25.00"  # per person (synthetic)
CONTRACT_DAYS = 90     # a new contract covers today .. today + 90
MIN_COVER_DAYS = 60    # an existing one is reused only while it covers today .. today + 60
DEPARTURE_OFFSETS = (14, 21, 28, 35, 42, 49, 56)  # days ahead; all inside MIN_COVER_DAYS
DEPARTURES_WANTED = 2
DEPARTURE_CAPACITY = 2
COMPONENT_DAY = 1
PLAN_NOTES = f"{TAG} seed (AA-973): Dev-only plan for the booking.b2b.v1 live check."

CATALOG_ROLES = ("booking", "tripplanner")
WRITE_ROLE = "bk_owner"

# ── Reads (schema booking as bk_owner; catalog as a CATALOG_ROLES role) ──────

TODAY_SQL = "SELECT (now() AT TIME ZONE 'UTC')::date"
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
PLANS_SQL = """
SELECT id::text AS id, source_id, sellable FROM booking.trip_plans
 WHERE source_system = 'cis' AND created_by = $1 ORDER BY created_at, id
"""
TAKEN_SQL = "SELECT source_id FROM booking.trip_plans WHERE source_system = 'cis'"
COMPONENTS_SQL = """
SELECT trip_plan_id::text AS trip_plan_id, day_no, hotel_room_type_id::text AS room_type_id,
       service_id::text AS service_id
  FROM booking.trip_plan_components WHERE trip_plan_id = ANY($1::uuid[])
"""
DEPARTURES_SQL = """
SELECT d.id::text AS id, d.trip_plan_id::text AS trip_plan_id, d.start_date, d.capacity, d.status,
       d.created_by = $2 AS seeded,
       (EXISTS (SELECT 1 FROM booking.b2b_hold_lines l WHERE l.departure_id = d.id)
        OR EXISTS (SELECT 1 FROM booking.b2b_quote_lines q WHERE q.departure_id = d.id)) AS referenced
  FROM booking.departures d
 WHERE d.trip_plan_id = ANY($1::uuid[])
 ORDER BY d.start_date, d.id
"""
PARTNER_SQL = """
SELECT status, m2m_client_id IS NOT NULL AND m2m_client_id <> '' AS has_client
  FROM booking.b2b_partners WHERE tenant_id = $1::uuid
"""
# The quote's rule read (AA-Booking app/pricing/repository.py RULE_SQL): the newest APPROVED b2b row in force.
RULE_SQL = """
SELECT r.valid_from FROM booking.pricing_rules r
  JOIN booking.policy_approvals a ON a.pricing_rule_id = r.id
 WHERE r.channel = 'b2b' AND r.valid_from <= $1
 ORDER BY r.valid_from DESC LIMIT 1
"""
SETTINGS_SQL = "SELECT key, value::text AS value FROM booking.settings WHERE key = ANY($1::text[])"
CATALOG_HAS_SQL = """
SELECT source_id, left(coalesce(title, ''), 80) AS title, country, duration_days FROM catalog.v_tour
 WHERE source_system = 'cis' AND source_id = ANY($1::text[])
"""
CATALOG_PICK_SQL = """
SELECT source_id, left(coalesce(title, ''), 80) AS title, country, duration_days FROM catalog.v_tour
 WHERE source_system = 'cis' AND source_id <> ALL($1::text[])
 ORDER BY source_id LIMIT 1
"""

# ── Writes (as bk_owner, one transaction) ────────────────────────────────────

INSERT_STAFF_SQL = """
INSERT INTO booking.staff_users (cis_user_id, name, role, active) VALUES ($1, $2, $3, false)
"""
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
VALUES ($1::uuid, $2::uuid, $3, $4, ARRAY['double']::text[], $5, 'active', $6, $6)
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
INSERT_RATE_SQL = """
INSERT INTO booking.supplier_rates (id, supplier_contract_id, hotel_room_type_id, service_id, valid_from, valid_to,
                                    unit, net_amount, currency, notes, created_by)
VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::date, $6::date, $7, $8::numeric, $9, $10, $11)
"""
# bk-008: publishing is a move on its own (no term changes) by someone else than the maker.
PUBLISH_CONTRACT_SQL = """
UPDATE booking.supplier_contracts SET status = 'published', published_by = $2, published_at = now()
 WHERE id = $1::uuid AND status = 'draft'
"""
# bk-008: the only change a published contract allows.
EXPIRE_CONTRACT_SQL = """
UPDATE booking.supplier_contracts SET status = 'expired', expired_by = $2, expired_at = now()
 WHERE id = $1::uuid AND status = 'published'
"""
DELETE_DRAFT_RATES_SQL = "DELETE FROM booking.supplier_rates WHERE supplier_contract_id = $1::uuid"
DELETE_DRAFT_CONTRACT_SQL = "DELETE FROM booking.supplier_contracts WHERE id = $1::uuid AND status = 'draft'"
INSERT_PLAN_SQL = """
INSERT INTO booking.trip_plans (id, source_system, source_id, sellable, default_channel, commercial_notes, created_by,
                                updated_by)
VALUES ($1::uuid, 'cis', $2, true, 'b2b', $3, $4, $4)
"""
SET_SELLABLE_SQL = "UPDATE booking.trip_plans SET sellable = $2, updated_by = $3 WHERE id = $1::uuid"
TOUCH_PLAN_SQL = "UPDATE booking.trip_plans SET updated_at = now() WHERE id = $1::uuid"
DELETE_PLAN_SQL = "DELETE FROM booking.trip_plans WHERE id = $1::uuid"
DELETE_COMPONENTS_SQL = "DELETE FROM booking.trip_plan_components WHERE trip_plan_id = $1::uuid"
INSERT_COMPONENT_SQL = """
INSERT INTO booking.trip_plan_components (trip_plan_id, day_no, hotel_room_type_id, service_id, created_by)
VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5)
"""
INSERT_DEPARTURE_SQL = """
INSERT INTO booking.departures (id, trip_plan_id, start_date, capacity, status, auto_confirm, created_by, updated_by)
VALUES ($1::uuid, $2::uuid, $3::date, $4, 'scheduled', true, $5, $5)
"""
CANCEL_DEPARTURE_SQL = """
UPDATE booking.departures SET status = 'cancelled', updated_by = $2 WHERE id = $1::uuid AND status <> 'cancelled'
"""
DELETE_DEPARTURE_SQL = "DELETE FROM booking.departures WHERE id = $1::uuid"
AUDIT_SQL = """
INSERT INTO booking.audit_logs (actor_type, actor_ref, action, entity_type, entity_id, after, entity_label, summary)
VALUES ('system', $1, $2, 'trip_plan', $3::uuid, $4::jsonb, $5, $6)
"""


class Refused(Exception):
    """The seed cannot be planned (no catalog tour to put it on): nothing is written."""


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


async def load_state(conn) -> dict:
    """Everything the seed and the cleanup decide on, read in schema booking (call as bk_owner)."""
    state = {
        "staff": {r["cis_user_id"]: dict(r) for r in await conn.fetch(STAFF_SQL, [m for m, _ in STAFF])},
        "supplier": None, "hotel": None, "room_type": None, "service": None, "contracts": [],
        "plans": [dict(r) for r in await conn.fetch(PLANS_SQL, MAKER)],
        "components": {}, "departures": {},
        "taken": [r["source_id"] for r in await conn.fetch(TAKEN_SQL)],
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
        service = await conn.fetchrow(SERVICE_SQL, sup, SERVICE_TYPE, SERVICE_TITLE)
        state["service"] = dict(service) if service is not None else None
        state["contracts"] = [dict(r) for r in await conn.fetch(CONTRACTS_SQL, sup, CONTRACT_TITLE)]
    plan_ids = [p["id"] for p in state["plans"]]
    for pid in plan_ids:
        state["components"][pid], state["departures"][pid] = [], []
    if plan_ids:
        for r in await conn.fetch(COMPONENTS_SQL, plan_ids):
            state["components"][r["trip_plan_id"]].append(dict(r))
        for r in await conn.fetch(DEPARTURES_SQL, plan_ids, MAKER):
            state["departures"][r["trip_plan_id"]].append(dict(r))
    return state


async def load_readiness(conn, today) -> dict:
    partner = await conn.fetchrow(PARTNER_SQL, PARTNER_TENANT_ID)
    settings = {r["key"]: r["value"] for r in await conn.fetch(SETTINGS_SQL, list(SETTINGS))}
    return {
        "partner_status": partner["status"] if partner else None,
        "partner_has_client": bool(partner["has_client"]) if partner else False,
        "rule_valid_from": await conn.fetchval(RULE_SQL, today),
        "settings": settings,
    }


async def read_catalog(conn, state: dict, roles=CATALOG_ROLES) -> dict:
    """Which seed plans' tours are in catalog.v_tour, and the tour a new plan would go on. Tries each role in turn
    (its own transaction, SET LOCAL ROLE); `role` None = no role could read the catalog."""
    refused = []
    for role in roles:
        try:
            async with conn.transaction():
                await conn.execute(f"SET LOCAL ROLE {role}")
                have = {r["source_id"]: dict(r) for r in
                        await conn.fetch(CATALOG_HAS_SQL, [p["source_id"] for p in state["plans"]])}
                pick = await conn.fetchrow(CATALOG_PICK_SQL, state["taken"])
            return {"role": role, "have": have, "pick": dict(pick) if pick is not None else None, "refused": refused}
        except Exception as e:  # noqa: BLE001 — a refused role switch or read: try the next role
            refused.append(f"{role}:{type(e).__name__}")
    return {"role": None, "have": {}, "pick": None, "refused": refused}


# ── Plans (pure: state in, steps out) ────────────────────────────────────────


def usable_contract(k: dict, today) -> bool:
    return (k["status"] == "published" and k["valid_from"] <= today and k["valid_to"] is not None
            and k["valid_to"] >= today + timedelta(days=MIN_COVER_DAYS) and k["rates"] == 2)


def seed_plan_row(state: dict, catalog: dict):
    """The seed plan to keep using: the first one whose tour is still in the catalog."""
    return next((p for p in state["plans"] if p["source_id"] in catalog["have"]), None)


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
    room = ensure("hotel_room_types", state["room_type"], INSERT_ROOM_TYPE_SQL,
                  lambda i: (i, hotel, ROOM_TYPE_NAME, ROOM_MAX_OCCUPANCY, NOTE, MAKER), name=ROOM_TYPE_NAME)
    service = ensure("services", state["service"], INSERT_SERVICE_SQL,
                     lambda i: (i, sup, SERVICE_TYPE, SERVICE_TITLE, SERVICE_UNIT, NOTE, MAKER),
                     name=SERVICE_TITLE)

    usable = [k for k in state["contracts"] if usable_contract(k, today)]
    keep = usable[-1] if usable else None
    for k in state["contracts"]:
        if k is keep:
            continue
        if k["status"] == "draft":  # never left by this script (one transaction); cleared all the same
            steps.append(Step("delete", "supplier_rates", k["id"], DELETE_DRAFT_RATES_SQL, (k["id"],),
                              of="draft contract"))
            steps.append(Step("delete", "supplier_contracts", k["id"], DELETE_DRAFT_CONTRACT_SQL, (k["id"],)))
        elif k["status"] == "published":
            steps.append(Step("expire", "supplier_contracts", k["id"], EXPIRE_CONTRACT_SQL, (k["id"], CHECKER),
                              why="does not cover the next days or lacks rates"))
    if keep is not None:
        contract = {"id": keep["id"], "valid_from": keep["valid_from"], "valid_to": keep["valid_to"]}
    else:
        cid, start, end = new_id(), today, today + timedelta(days=CONTRACT_DAYS)
        contract = {"id": cid, "valid_from": start, "valid_to": end}
        steps.append(Step("insert", "supplier_contracts", cid, INSERT_CONTRACT_SQL,
                          (cid, sup, CONTRACT_TITLE, CONTRACT_REFERENCE, start, end, CURRENCY, NOTE, MAKER),
                          new=True, status="draft", valid_from=start, valid_to=end, currency=CURRENCY))
        for target, (room_id, service_id, unit, net) in (
            ("room_type", (room, None, "room_night", ROOM_NET)),
            ("service", (None, service, SERVICE_UNIT, SERVICE_NET)),
        ):
            rid = new_id()
            steps.append(Step("insert", "supplier_rates", rid, INSERT_RATE_SQL,
                              (rid, cid, room_id, service_id, start, end, unit, net, CURRENCY, NOTE, MAKER),
                              new=True, target=target, unit=unit))
        steps.append(Step("publish", "supplier_contracts", cid, PUBLISH_CONTRACT_SQL, (cid, CHECKER), new=True,
                          by="checker"))

    plan = seed_plan_row(state, catalog)
    if plan is None:
        pick = catalog["pick"]
        if pick is None:
            raise Refused("no catalog.v_tour row without a trip plan to put the seed on")
        plan = {"id": new_id(), "source_id": pick["source_id"], "sellable": True}
        steps.append(Step("insert", "trip_plans", plan["id"], INSERT_PLAN_SQL,
                          (plan["id"], plan["source_id"], PLAN_NOTES, MAKER), new=True,
                          source_id=plan["source_id"], sellable=True))
        current, departures, new_plan = [], [], True
    else:
        if not plan["sellable"]:
            steps.append(Step("update", "trip_plans", plan["id"], SET_SELLABLE_SQL, (plan["id"], True, MAKER),
                              sellable=True))
        current = state["components"].get(plan["id"], [])
        departures = state["departures"].get(plan["id"], [])
        new_plan = False
    pid, touch = plan["id"], False

    wanted = {(COMPONENT_DAY, room, None), (COMPONENT_DAY, None, service)}
    have = {(c["day_no"], c["room_type_id"], c["service_id"]) for c in current}
    if have != wanted:
        if current:
            steps.append(Step("delete", "trip_plan_components", pid, DELETE_COMPONENTS_SQL, (pid,),
                              new=new_plan, rows=len(current)))
        for day, room_id, service_id in sorted(wanted, key=lambda w: (w[0], w[1] or "", w[2] or "")):
            steps.append(Step("insert", "trip_plan_components", pid, INSERT_COMPONENT_SQL,
                              (pid, day, room_id, service_id, MAKER), new=new_plan, day_no=day,
                              target="room_type" if room_id else "service"))
        touch = True

    future = [d for d in departures if d["status"] != "cancelled" and d["start_date"] > today]
    used = {d["start_date"] for d in departures}
    dep_ids = [d["id"] for d in future]
    missing = DEPARTURES_WANTED - len(future)
    for offset in DEPARTURE_OFFSETS:
        if missing <= 0:
            break
        day = today + timedelta(days=offset)
        if day in used or day > contract["valid_to"]:
            continue
        did = new_id()
        steps.append(Step("insert", "departures", did, INSERT_DEPARTURE_SQL,
                          (did, pid, day, DEPARTURE_CAPACITY, MAKER), new=True, start_date=day,
                          capacity=DEPARTURE_CAPACITY))
        dep_ids.append(did)
        missing -= 1
        touch = True
    if touch and not new_plan:
        steps.append(Step("touch", "trip_plans", pid, TOUCH_PLAN_SQL, (pid,), why="products change signal"))

    facts = {"trip_plan_id": pid, "source_id": plan["source_id"], "room_type_id": room, "service_id": service,
             "contract_id": contract["id"], "contract_valid_to": contract["valid_to"], "departure_ids": dep_ids,
             "new_plan": new_plan, "short_departures": max(missing, 0),
             "new_ids": {s.ident for s in steps if s.new}}
    return steps, facts


def plan_cleanup(state: dict) -> list:
    """The writes that retire every seed row, children first (components, departures, plans, contracts, supply)."""
    steps = []
    for plan in state["plans"]:
        pid = plan["id"]
        rows = state["components"].get(pid, [])
        if rows:
            steps.append(Step("delete", "trip_plan_components", pid, DELETE_COMPONENTS_SQL, (pid,), rows=len(rows)))
        kept = False
        for d in state["departures"].get(pid, []):
            if not d["seeded"]:
                kept = True  # someone else's departure on the seed plan: left alone, so the plan stays too
            elif d["referenced"]:
                kept = True
                if d["status"] != "cancelled":
                    steps.append(Step("cancel", "departures", d["id"], CANCEL_DEPARTURE_SQL, (d["id"], MAKER),
                                      why="quote or hold lines point at it"))
            else:
                steps.append(Step("delete", "departures", d["id"], DELETE_DEPARTURE_SQL, (d["id"],)))
        if kept:
            if plan["sellable"]:
                steps.append(Step("update", "trip_plans", pid, SET_SELLABLE_SQL, (pid, False, MAKER),
                                  sellable=False, why="departures are kept"))
        else:
            steps.append(Step("delete", "trip_plans", pid, DELETE_PLAN_SQL, (pid,), source_id=plan["source_id"]))
    for k in state["contracts"]:
        if k["status"] == "published":
            steps.append(Step("expire", "supplier_contracts", k["id"], EXPIRE_CONTRACT_SQL, (k["id"], CHECKER)))
        elif k["status"] == "draft":
            steps.append(Step("delete", "supplier_rates", k["id"], DELETE_DRAFT_RATES_SQL, (k["id"],),
                              of="draft contract"))
            steps.append(Step("delete", "supplier_contracts", k["id"], DELETE_DRAFT_CONTRACT_SQL, (k["id"],)))
    for table, key in (("hotel_room_types", "room_type"), ("hotels", "hotel"), ("services", "service"),
                       ("suppliers", "supplier")):
        row = state[key]
        if row is not None and row["status"] == "active":
            steps.append(Step("retire", table, row["id"], SET_STATUS_SQL[table], (row["id"], "inactive", MAKER)))
    return steps


def step_counts(steps: list) -> dict:
    counts: dict = {}
    for s in steps:
        key = f"{s.verb}:{s.table}"
        counts[key] = counts.get(key, 0) + 1
    return counts


# ── Run ──────────────────────────────────────────────────────────────────────


def report_readiness(ready: dict, today) -> list:
    """Prints the readiness lines; returns the reasons the live check would fail."""
    reasons = []
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
    out("readiness", what="fx", needed="none", why="USD contract and USD quote")
    return reasons


async def _as_owner(conn) -> None:
    await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")


async def _write(conn, steps: list, facts, state: dict, action: str) -> None:
    """Runs the steps in order, then one audit row (only when something was written)."""
    for step in steps:
        await conn.execute(step.sql, *step.args)
    if steps:
        pid = facts["trip_plan_id"] if facts else (state["plans"][0]["id"] if state["plans"] else None)
        await conn.execute(AUDIT_SQL, ACTOR, AUDIT_ACTION, pid,
                           json.dumps({"action": action, "steps": step_counts(steps)}, sort_keys=True),
                           f"{TAG} {action}", f"{TAG} {action}: {len(steps)} writes (AA-973 live check)")


async def run(conn, apply: bool, action: str = "seed") -> int:
    if action not in ("seed", "cleanup"):
        out("refuse", what="action", action=action)
        return 1
    out(SCRIPT_NAME, mode="APPLY" if apply else "DRY_RUN", action=action)
    today = await conn.fetchval(TODAY_SQL)
    async with conn.transaction():
        await _as_owner(conn)
        out("pass", role=await conn.fetchval("SELECT current_user"), what="read booking")
        state = await load_state(conn)
        ready = await load_readiness(conn, today)
    catalog = {"role": None, "have": {}, "pick": None, "refused": []}
    if action == "seed":
        catalog = await read_catalog(conn, state)
        out("catalog", role=catalog["role"], refused=",".join(catalog["refused"]) or None,
            seed_plans=len(state["plans"]), seed_plans_in_catalog=len(catalog["have"]))
        if catalog["role"] is None:
            out("refuse", what="catalog_read", tried=",".join(CATALOG_ROLES))
            return 1
    reasons = report_readiness(ready, today)

    def plan(st) -> tuple:
        if action == "cleanup":
            return plan_cleanup(st), None
        return plan_seed(st, catalog, today)

    try:
        steps, facts = plan(state)
        if apply:
            async with conn.transaction():
                await _as_owner(conn)
                await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", LOCK_KEY)
                state = await load_state(conn)  # again, under the lock: the steps run on what is there now
                steps, facts = plan(state)
                await _write(conn, steps, facts, state, action)
    except Refused as e:
        out("refuse", what="no_catalog_tour", why=str(e))
        return 1

    for step in steps:
        print(step.line(applied=apply), flush=True)
    out("summary", action=action, applied=apply, steps=len(steps),
        counts=json.dumps(step_counts(steps), sort_keys=True))
    if facts is not None:
        def shown(value):  # an id this DRY RUN only planned is not the id the apply will write
            return "<new>" if not apply and value in facts["new_ids"] else value

        catalog_row = catalog["have"].get(facts["source_id"]) or catalog["pick"] or {}
        out("verify", source_system="cis", source_id=facts["source_id"], title=catalog_row.get("title"),
            country=catalog_row.get("country"), trip_plan_id=shown(facts["trip_plan_id"]))
        out("verify", component_id="tp:" + shown(facts["trip_plan_id"]), room_type_id=shown(facts["room_type_id"]),
            service_id=shown(facts["service_id"]))
        out("verify", contract_id=shown(facts["contract_id"]), currency=CURRENCY, valid_to=facts["contract_valid_to"])
        for did in facts["departure_ids"]:
            out("verify", departure_id=shown(did), capacity=DEPARTURE_CAPACITY)
        if facts["short_departures"]:
            reasons.append("departures")
            out("warn", what="departures", missing=facts["short_departures"],
                why="no free 7-day offset inside the contract: run cleanup, then seed again")
    if action == "seed":
        out("verdict", ready=not reasons, reasons=",".join(reasons) or None)
    return 0


async def main(conn):
    return await run(conn, apply=not READ_ONLY, action=ACTION)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse
    import asyncio

    import asyncpg

    parser = argparse.ArgumentParser(description="Synthetic B2B supply for the AA-973 live check (DRY RUN by default)")
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
