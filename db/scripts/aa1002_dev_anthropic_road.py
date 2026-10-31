"""AA-1002 (S261), Dev only: prepare the Dev LLM road on the Anthropic API WITHOUT the key.

Why. acc3 Bedrock is refused at account level (every provider) and acc2 Bedrock refuses Claude, so most Dev stages
have no working LLM path. The CIS gateway already has the Anthropic API way in (connection `anthropic-direct`, kind
anthropic, data scope vendor_direct, secret NAME aa-llm/dev/anthropic-direct; migration 306 seeded one deployment per
Anthropic Converse catalog model at priority 100, behind acc3 at 10). Migration 311 gave every stage except the
judge / validate stages with an OpenAI API last resort `allowed_scopes = {aws_only}`, so even with the key in place no
writer would reach the API. Tech lead decision (S261): "build the road now, add the key later". Dev holds synthetic
data only (data standards C7.1a), so tenant T-stages are opened too; they are printed in their own group.

What it does, in one transaction as `cis_owner` (owner of the four tables; the master is a member, roles/002):
  (b) for every Anthropic catalog model a CIS stage route names (primary, fallbacks; never the shadow) that has a Claude API
      id but no `anthropic-direct` deployment: inserts one exactly as migration 306 does (wire id = acc3 profile
      without region prefix / version suffix, priority 100 behind acc3, enabled, origin 'seed'). Reports every
      Anthropic model in a route that still has no usable API deployment (legacy keys `haiku` / `sonnet`, which the
      gateway never sends to an Anthropic connection; a disabled deployment; a disabled catalog row) — left as is.
  (a) sets `allowed_scopes = {aws_only, vendor_direct}` on every CIS stage whose route then reaches an Anthropic
      model through `anthropic-direct` (derived from the live routes, deployments and catalog; no stage list in this
      file). TripPlanner stages (`tp_*`, its own client reads neither scopes nor deployments until slice S8) are
      reported, never changed. Also names any OTHER vendor_direct deployment the widening allows on that stage; a stage
      that would reach one on an ENABLED connection (e.g. openai-direct) is held, not widened (`SCRIPT held`): that
      would be paid traffic outside AWS before the Anthropic key exists, so the tech lead decides it.
  (c) the S10 budget is MONTHLY per connection (`monthly_budget_usd`; there is no daily per-connection budget, and no
      LLM path enforces `shared.spend_budget` 'anthropic' daily caps): when it is NULL (unlimited) it is set to
      MONTHLY_BUDGET_USD (5 USD/day x 30). A non-NULL value (an admin's) is kept; 0 is reported (0 = no spend at all).
      No policy row = the S10 defaults (alert at 80 %, hard stop at 100 %).
  (d) never enables the connection, never touches its secret, data scope, kind or any Bedrock / OpenAI row.

Dev check (refuses unless all hold). The DB Migrate task has no environment variable, so the check reads the data's
own environment marker, the `<env>` segment of the gateway's secret names `aa-llm/<env>/<name>` (CHECK on the
connection and cost-policy tables, `connections.SECRET_NAME_RE`): `anthropic-direct` names exactly
`aa-llm/dev/anthropic-direct`, and every `aa-llm/` secret / usage-secret name in the registry is under `aa-llm/dev/`.
A prod database names `aa-llm/prod/...`. Also refuses without migration 311 (`allowed_scopes`).

MODE "dry_run" (this file as merged): all of the above, prints the final state from inside the transaction, then
ROLLS BACK. MODE "apply" (one-line follow-up PR): the same, committed, then a READ-ONLY verification printout.
Idempotent: a second apply changes nothing. The api / worker see the change within 5 minutes (registry and stage
caches). Rollback: a follow-up script setting the printed stages back to `{aws_only}` and the budget back to NULL
(the `SCRIPT widen` / `SCRIPT budget` lines are the undo list); inserted deployments are harmless while the connection
is off.

Prints stage keys, model keys, counts and settings only (no secret value: none is read). Local test:
`python3 aa1002_dev_anthropic_road.py <DSN> [--apply]`.
"""

import asyncio
import re
from decimal import Decimal

MODE = "apply"

SCRIPT_NAME = "aa1002_dev_anthropic_road"
ACTOR = f"script:{SCRIPT_NAME}"
WRITE_ROLE = "cis_owner"
CONNECTION = "anthropic-direct"
PRIMARY_CONNECTION = "acc3"
DEV_SECRET = "aa-llm/dev/anthropic-direct"
DEV_SECRET_PREFIX = "aa-llm/dev/"
SECRET_PREFIX = "aa-llm/"
MONTHLY_BUDGET_USD = Decimal("150.00")  # ~5 USD/day on Dev
SEED_PRIORITY = 100
BOTH_SCOPES = ["aws_only", "vendor_direct"]
VENDOR_DIRECT = "vendor_direct"
# AA-CIS-App shared/llm_client/catalog.py LEGACY_KEYS: never sent to an Anthropic connection (vendor_route._callable).
LEGACY_KEYS = frozenset({"haiku", "sonnet", "gpt-4.1"})
# vendor_route._CALLABLE["anthropic"]: the catalog api styles an Anthropic connection can serve.
API_STYLES = frozenset({"converse", "anthropic_messages"})
TRIPPLANNER_PREFIX = "tp_"
TENANT_STAGE_RE = re.compile(r"^t[0-9]+_")
# Migration 306's wire id derivation, in Python (same two regexes, same validity check).
_REGION_PREFIX_RE = re.compile(r"^(global|us|eu|apac|jp|au)\.anthropic\.")
_VERSION_SUFFIX_RE = re.compile(r"-v[0-9]+:[0-9]+$")
_WIRE_RE = re.compile(r"^claude-[a-z0-9-]+$")


def out(tag: str, /, **values) -> None:
    parts = " ".join(f"{k}={v}" for k, v in values.items())
    print(f"SCRIPT {tag} {parts}".rstrip(), flush=True)


def _csv(items) -> str:
    items = list(items)
    return ",".join(str(i) for i in items) if items else "-"


# ── read ──────────────────────────────────────────────────────────────────────────────────────────────────────────

async def read_state(conn) -> dict:
    """Everything the plan needs, as plain dicts (no secret value: only names)."""
    has_scopes = await conn.fetchval(
        "SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'shared.llm_role_config'::regclass"
        " AND attname = 'allowed_scopes' AND NOT attisdropped)"
    )
    has_policy = await conn.fetchval("SELECT to_regclass('shared.llm_connection_cost_policy') IS NOT NULL")
    connections = {
        r["connection_key"]: dict(r)
        for r in await conn.fetch(
            "SELECT connection_key, kind, auth_mode, enabled, data_scope, secret_name, monthly_budget_usd"
            " FROM shared.llm_provider_connection ORDER BY connection_key"
        )
    }
    policies = {}
    if has_policy:
        policies = {
            r["connection_key"]: dict(r)
            for r in await conn.fetch(
                "SELECT connection_key, alert_pct, hard_stop, usage_secret_name"
                " FROM shared.llm_connection_cost_policy ORDER BY connection_key"
            )
        }
    catalog = {
        r["model_key"]: dict(r)
        for r in await conn.fetch(
            "SELECT model_key, vendor, provider, api_style, enabled, bedrock_profile_ids ->> 'acc3' AS acc3_profile"
            " FROM shared.llm_model_catalog ORDER BY model_key"
        )
    }
    deployments = [
        dict(r)
        for r in await conn.fetch(
            "SELECT model_key, connection_key, wire_id, priority, enabled, origin"
            " FROM shared.llm_model_deployment ORDER BY model_key, priority, connection_key"
        )
    ]
    scopes_sql = "allowed_scopes" if has_scopes else "NULL::text[] AS allowed_scopes"
    stages = [
        dict(r)
        for r in await conn.fetch(
            f"SELECT stage, role, is_active, model_id, fallback_model_ids, shadow_model_id, {scopes_sql}"
            " FROM shared.llm_role_config ORDER BY stage"
        )
    ]
    return {"has_scopes": bool(has_scopes), "connections": connections, "policies": policies, "catalog": catalog,
            "deployments": deployments, "stages": stages}


# ── plan (pure: state in, decisions out) ──────────────────────────────────────────────────────────────────────────

def wire_id_for(acc3_profile) -> str | None:
    """The Claude API model id migration 306 derives from an acc3 profile, or None when it is not one."""
    if not acc3_profile:
        return None
    wire = _VERSION_SUFFIX_RE.sub("", _REGION_PREFIX_RE.sub("", acc3_profile))
    return wire if _WIRE_RE.fullmatch(wire) else None


def dev_problems(state: dict) -> list[str]:
    """Why this database does not look like Dev (empty = Dev)."""
    problems = []
    if not state["has_scopes"]:
        problems.append("shared.llm_role_config.allowed_scopes missing (CIS migration 311 not applied)")
    c = state["connections"].get(CONNECTION)
    if c is None:
        problems.append(f"connection {CONNECTION} missing (CIS migration 304)")
    else:
        if c["kind"] != "anthropic" or c["data_scope"] != VENDOR_DIRECT:
            problems.append(f"connection {CONNECTION} is kind={c['kind']} data_scope={c['data_scope']}")
        if c["secret_name"] != DEV_SECRET:
            problems.append(f"connection {CONNECTION} secret_name is not {DEV_SECRET}")
    names = [(k, "secret_name", v["secret_name"]) for k, v in state["connections"].items()]
    names += [(k, "usage_secret_name", v.get("usage_secret_name")) for k, v in state["policies"].items()]
    for key, column, name in names:
        if name and name.startswith(SECRET_PREFIX) and not name.startswith(DEV_SECRET_PREFIX):
            problems.append(f"{key}.{column} is outside {DEV_SECRET_PREFIX} (not a Dev database)")
    return problems


def route_keys(stage: dict) -> list[str]:
    """Primary + fallbacks only. The shadow model is left out (review S261): widening a stage for its shadow alone would
    make its A/B shadow calls paid API calls while the primary route still has no road."""
    keys = [stage["model_id"], *(stage["fallback_model_ids"] or [])]
    seen: list[str] = []
    for k in keys:
        if k and k not in seen:
            seen.append(k)
    return seen


def stage_group(stage_key: str) -> str:
    if stage_key.startswith(TRIPPLANNER_PREFIX):
        return "tripplanner"
    return "tenant" if TENANT_STAGE_RE.match(stage_key) else "admin"


def _deployment(state: dict, model_key: str, connection_key: str):
    for d in state["deployments"]:
        if d["model_key"] == model_key and d["connection_key"] == connection_key:
            return d
    return None


def model_road(state: dict, model_key: str):
    """For an Anthropic catalog model: ("ok", None) when anthropic-direct can serve it, ("insert", wire_id) when a 306
    style row would make it so, ("gap", reason) otherwise. None for a model that is not Anthropic (or unknown)."""
    m = state["catalog"].get(model_key)
    if m is None or m["vendor"] != "anthropic":
        return None
    if model_key in LEGACY_KEYS:
        return ("gap", "legacy key: the gateway never sends it to an Anthropic connection")
    if m["api_style"] not in API_STYLES:
        return ("gap", f"api_style {m['api_style']} has no Anthropic adapter")
    if not m["enabled"]:
        return ("gap", "catalog row disabled")
    d = _deployment(state, model_key, CONNECTION)
    if d is None:
        wire = wire_id_for(m["acc3_profile"])
        if wire is None or m["provider"] != "bedrock":
            return ("gap", "no anthropic-direct deployment and no Claude API id derivable from the acc3 profile")
        return ("insert", wire)
    if not d["enabled"]:
        return ("gap", "anthropic-direct deployment disabled (an admin choice, left as is)")
    return ("ok", None)


def plan(state: dict) -> dict:
    inserts: dict[str, str] = {}
    gaps: dict[str, str] = {}
    stages = []
    for s in state["stages"]:
        keys = route_keys(s)
        api_keys, gap_keys = [], []
        for k in keys:
            road = model_road(state, k)
            if road is None:
                continue
            verdict, detail = road
            if verdict == "gap":
                gap_keys.append(k)
                gaps[k] = detail
            else:
                api_keys.append(k)
                if verdict == "insert" and stage_group(s["stage"]) != "tripplanner":
                    inserts[k] = detail
        scopes = list(s["allowed_scopes"]) if s["allowed_scopes"] is not None else None
        group = stage_group(s["stage"])
        has_vendor = scopes is not None and VENDOR_DIRECT in scopes
        widen = bool(api_keys) and group != "tripplanner" and not has_vendor
        also, live_other = [], []
        if api_keys and group != "tripplanner":
            for k in keys:
                for d in state["deployments"]:
                    c = state["connections"].get(d["connection_key"])
                    if (d["model_key"] == k and d["connection_key"] != CONNECTION and c is not None
                            and c["data_scope"] == VENDOR_DIRECT and d["enabled"]):
                        also.append(f"{k}@{d['connection_key']}")
                        if c["enabled"]:
                            live_other.append(f"{k}@{d['connection_key']}")
        # Hold (review S261): widening would let the stage call another vendor API that is already switched on (e.g.
        # openai-direct), i.e. paid traffic outside AWS before the Anthropic key exists. The tech lead decides those.
        held = widen and bool(live_other)
        widen = widen and not held
        stages.append({"stage": s["stage"], "role": s["role"], "active": s["is_active"], "group": group,
                       "scopes": scopes, "route": keys, "api_keys": api_keys, "gap_keys": gap_keys,
                       "widen": widen, "held": held, "held_by": live_other, "also_opens": also})
    conn = state["connections"].get(CONNECTION) or {}
    budget = conn.get("monthly_budget_usd")
    return {"inserts": inserts, "gaps": gaps, "stages": stages, "set_budget": budget is None,
            "budget": budget}


def pending(p: dict) -> int:
    return len(p["inserts"]) + sum(1 for s in p["stages"] if s["widen"]) + (1 if p["set_budget"] else 0)


def _primary_priority(state: dict, model_key: str):
    d = _deployment(state, model_key, PRIMARY_CONNECTION)
    return d["priority"] if d is not None and d["enabled"] else None


# ── print ─────────────────────────────────────────────────────────────────────────────────────────────────────────

def report(state: dict, p: dict, title: str) -> None:
    out("state", view=title)
    c = state["connections"].get(CONNECTION) or {}
    pol = state["policies"].get(CONNECTION)
    out("connection", key=CONNECTION, kind=c.get("kind"), enabled=c.get("enabled"), data_scope=c.get("data_scope"),
        secret_name=c.get("secret_name"), monthly_budget_usd=c.get("monthly_budget_usd"),
        alert_pct=pol["alert_pct"] if pol else "80(default)", hard_stop=pol["hard_stop"] if pol else "true(default)")
    for d in state["deployments"]:
        if d["connection_key"] == CONNECTION:
            out("deployment", model=d["model_key"], wire_id=d["wire_id"], priority=d["priority"],
                enabled=d["enabled"], acc3_priority=_primary_priority(state, d["model_key"]), origin=d["origin"])
    for group in ("admin", "tenant", "tripplanner"):
        rows = [s for s in p["stages"] if s["group"] == group and (s["api_keys"] or s["gap_keys"])]
        out("group", name=group, stages_naming_anthropic=len(rows),
            with_api_road=sum(1 for s in rows if s["api_keys"]))
        for s in rows:
            out("stage", group=group, stage=s["stage"], role=s["role"], active=s["active"],
                scopes=_csv(s["scopes"] or ["NULL"]), api=_csv(s["api_keys"]), no_api=_csv(s["gap_keys"]),
                also_vendor=_csv(s["also_opens"]))
            if s["held"]:
                out("held", stage=s["stage"], why="widening would also reach a live vendor API",
                    live=_csv(s["held_by"]))
    for k, why in sorted(p["gaps"].items()):
        out("gap", model=k, why=why)


# ── run ───────────────────────────────────────────────────────────────────────────────────────────────────────────

async def _apply_plan(conn, state: dict, p: dict) -> None:
    for model_key, wire in sorted(p["inserts"].items()):
        primary = _primary_priority(state, model_key)
        priority = SEED_PRIORITY if primary is None or primary < SEED_PRIORITY else primary + 1
        await conn.execute(
            "INSERT INTO shared.llm_model_deployment (model_key, connection_key, wire_id, priority, enabled, origin,"
            " notes, updated_by) VALUES ($1, $2, $3, $4, true, 'seed', $5, $6)"
            " ON CONFLICT (model_key, connection_key) DO NOTHING",
            model_key, CONNECTION, wire, priority,
            "Anthropic Messages API, behind acc3 (AA-1002 S261 Dev road, migration 306 rule).", ACTOR,
        )  # fmt: skip
        out("insert", model=model_key, connection=CONNECTION, wire_id=wire, priority=priority)
    for s in p["stages"]:
        if s["widen"]:
            await conn.execute(
                "UPDATE shared.llm_role_config SET allowed_scopes = $2::text[], updated_at = now(), updated_by = $3"
                " WHERE stage = $1",
                s["stage"], BOTH_SCOPES, ACTOR,
            )  # fmt: skip
            out("widen", group=s["group"], stage=s["stage"], before=_csv(s["scopes"] or ["NULL"]),
                after=_csv(BOTH_SCOPES), api=_csv(s["api_keys"]), also_vendor=_csv(s["also_opens"]))
    if p["set_budget"]:
        await conn.execute(
            "UPDATE shared.llm_provider_connection SET monthly_budget_usd = $2, updated_at = now(), updated_by = $3"
            " WHERE connection_key = $1 AND monthly_budget_usd IS NULL",
            CONNECTION, MONTHLY_BUDGET_USD, ACTOR,
        )  # fmt: skip
        out("budget", connection=CONNECTION, before="NULL", after=MONTHLY_BUDGET_USD, period="month")
    elif p["budget"] is not None and Decimal(p["budget"]) == 0:
        out("budget_note", connection=CONNECTION, monthly_budget_usd=0, why="0 = no spend at all; left as is")
    else:
        out("budget_kept", connection=CONNECTION, monthly_budget_usd=p["budget"])


def _guards(before: dict, after: dict, p_after: dict) -> list[str]:
    errors = []
    b, a = before["connections"][CONNECTION], after["connections"][CONNECTION]
    for col in ("enabled", "kind", "data_scope", "secret_name"):
        if b[col] != a[col]:
            errors.append(f"{CONNECTION}.{col} changed")
    for key, row in before["connections"].items():
        if key != CONNECTION and row != after["connections"].get(key):
            errors.append(f"connection {key} changed")
    if pending(p_after):
        errors.append(f"{pending(p_after)} change(s) still pending after the writes")
    for s in p_after["stages"]:
        if (s["api_keys"] and s["group"] != "tripplanner" and not s["held"]
                and VENDOR_DIRECT not in (s["scopes"] or [])):
            errors.append(f"stage {s['stage']} has an API road but no vendor_direct scope")
    return errors


async def run(conn, mode: str) -> int:
    out(SCRIPT_NAME, mode=mode.upper())
    tx = conn.transaction()
    await tx.start()
    committed = False
    try:
        await conn.execute(f"SET LOCAL ROLE {WRITE_ROLE}")
        await conn.execute("SET LOCAL lock_timeout = '5s'")
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", SCRIPT_NAME)
        state = await read_state(conn)
        problems = dev_problems(state)
        if problems:
            for why in problems:
                out("refuse", why=why)
            return 1
        p = plan(state)
        enabled = state["connections"][CONNECTION]["enabled"]
        out("plan", inserts=len(p["inserts"]), widen=sum(1 for s in p["stages"] if s["widen"]),
            held=sum(1 for s in p["stages"] if s["held"]),
            set_budget=p["set_budget"], gaps=len(p["gaps"]), connection_enabled=enabled)
        if enabled:
            out("note", why="anthropic-direct is already enabled: widened stages use the API within 5 minutes")
        await _apply_plan(conn, state, p)
        after = await read_state(conn)
        p_after = plan(after)
        errors = _guards(state, after, p_after)
        if errors:
            for why in errors:
                out("guard_failed", why=why)
            return 1
        if mode == "apply":
            await tx.commit()
            committed = True
            out("committed", changes=pending(p))
        else:
            report(after, p_after, "after (dry run, rolled back)")
            out("rolled_back", reason="dry_run", would_change=pending(p))
    finally:
        if not committed:
            await tx.rollback()
    if mode == "apply":
        async with conn.transaction(readonly=True):
            final = await read_state(conn)
            report(final, plan(final), "after apply (read-only)")
    out("next", step="runbook llm-anthropic-api-key.md: key with a spend limit, secret, PATCH enable, probe")
    return 0


async def main(conn):
    return await run(conn, MODE)


if __name__ == "__main__":  # local test only; DB Migrate imports main(conn)
    import argparse

    import asyncpg

    parser = argparse.ArgumentParser(description="AA-1002: prepare the Dev Anthropic API road (DRY RUN by default)")
    parser.add_argument("dsn")
    parser.add_argument("--apply", action="store_true", help="commit")
    args = parser.parse_args()

    async def _cli() -> int:
        conn = await asyncpg.connect(args.dsn)
        try:
            return await run(conn, "apply" if args.apply else "dry_run")
        finally:
            await conn.close()

    raise SystemExit(asyncio.run(_cli()))
