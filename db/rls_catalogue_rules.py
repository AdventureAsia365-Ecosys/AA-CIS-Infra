"""RLS catalogue guard (X2): pure rules over the shared RDS catalog, in the shape of a schema dump.

Canonical file: AA-CIS-App tests/integration/rls_catalogue_rules.py. AA-CIS-Infra keeps a byte-identical copy
at db/rls_catalogue_rules.py (checked by its Migration Copy Guard): the same rules and allowlists run in two places.
  * CIS CI: tests/integration/test_rls_catalogue_guard.py builds the dump from the replayed migrations DB
    (CATALOG_SQL + dump_from_rows) and fails on any violation that is not allowlisted.
  * Dev, nightly: AA-CIS-Infra db/gen_schema_reference.py runs check() on db/schema_dump.py's JSON (format 2)
    and writes the findings into AA-Ecosys docs/architecture/db-schema-reference.md.
Standard library only: the Infra copy runs on the GitHub runner next to the generator.

Input: a dict with the format-2 dump keys this module reads (schema_dump.build_dump writes all of them):
  schemas:   [{schema, grants: [{grantee, privileges}]}]
  relations: {schema: {name: {kind, rls, columns: [{name}], policies: [{policy, permissive, roles, cmd, qual,
              with_check}], constraints: [{constraint, type, ref_schema, ref_name}], grants: [{grantee,
              privileges}], column_grants: [{column, grantee, privileges}]}}}
Grantee PUBLIC is spelled 'PUBLIC' (aclexplode grantee 0); a policy TO PUBLIC has roles ['public'].

Rules (one finding per object; the key is what an allowlist entry names):
  a  a base table with a tenant_id column has RLS off, or no policy whose USING / WITH CHECK reads
     app.tenant_id. Never allowlistable when a tenant-pool role (TENANT_POOL_ROLES) holds a grant on it.
                                                                     key schema.table
  b  a policy applies TO PUBLIC.                                     key schema.table:policy
  c  a policy reads app.current_tenant (the old GUC name).           key schema.table:policy
  d  a policy reads current_setting('app.tenant_id' ...) outside NULLIF(..., '') (an empty GUC must not
     cast or compare as a tenant).                                   key schema.table:policy
  e  a foreign key whose table and referenced table belong to different owners (SCHEMA_OWNERS), or touches
     a schema that is in no owner's list.               key schema.table:constraint->ref_schema.ref_table
  p  a grant to PUBLIC on a schema, relation or column (functions are not in the dump: out of scope).
                                                                     key schema | schema.table | schema.table.column
  g  a grant on an owner's schema, relation or column to another owner's role (ROLE_OWNERS). Temporary list
     until the owners.yaml grant registry (rule f) takes over.    key <object>:<grantee>, object as in p
  t  a permissive policy whose USING or WITH CHECK is just `true` (it opens every row to its roles), other
     than the X1 runtime-parity policies <table>_cis_app_all TO cis_app and <table>_cis_owner_all TO
     cis_owner in a CIS schema (CIS 244 / 245).                     key schema.table:policy

Every allowlist entry is {key: one-line reason}; a key may use `*` (fnmatch, matches dots too). check_allowlist()
refuses an empty or multi-line reason and a rule letter that does not exist. A guarded run fails on violations
only; allowlisted findings and allowlist entries that matched nothing (stale) are reported, not fatal.
"""
from __future__ import annotations

import fnmatch
import re
from typing import Iterable, NamedTuple, Optional

RULES = {
    "a": "tenant_id table without RLS + an app.tenant_id policy",
    "b": "policy TO PUBLIC",
    "c": "policy reads app.current_tenant",
    "d": "current_setting('app.tenant_id') outside NULLIF",
    "e": "foreign key across owners",
    "p": "grant to PUBLIC",
    "g": "grant to another owner's role",
    "t": "unconditional (true) policy",
}

# Mirrors AA-CIS-Infra db/owners.yaml owners.<owner>.schemas (the Infra registry test keeps them equal).
# `public` holds the master's extensions and leftovers: it belongs to no app.
SCHEMA_OWNERS = {
    **{s: "cis" for s in ("acp_contract", "acp_deliver", "acp_gold_output", "acp_shared", "acp_silver_s2",
                          "acp_silver_s3", "acp_silver_s4", "catalog", "geo", "gold_aa_internal", "shared",
                          "silver_aa_internal")},
    "booking": "booking",
    "tripplanner": "tripplanner",
    "dryrun": "dryrun",
    "public": "platform",
}
# The app roles of each owner (owner role, runtime roles, view owner). Platform roles (the RDS master,
# db_migrator, pg_* / rds*) belong to no owner and are not checked by rule g.
ROLE_OWNERS = {
    "cis_owner": "cis", "cis_app": "cis", "aa_app_user": "cis", "catalog_owner": "cis",
    "bk_owner": "booking", "booking": "booking",
    "tp_owner": "tripplanner", "tripplanner": "tripplanner",
    "dr_owner": "dryrun", "dryrun_app": "dryrun",
}
CIS_PARITY_ROLES = {"cis_app": "_cis_app_all", "cis_owner": "_cis_owner_all"}   # rule t, CIS 244 / 245
BASE_TABLE_KINDS = ("table", "partitioned table")

_TENANT_GUC_RE = re.compile(r"current_setting\s*\(\s*'app\.tenant_id'", re.IGNORECASE)
_NULLIF_OPEN_RE = re.compile(r"NULLIF\s*\(\s*$", re.IGNORECASE)

# ── Allowlists (Dev). One line per entry: why the object may break the rule, and until when. A key may use `*`
# (fnmatch, matches dots too). Rule a: an entry never covers a table granted to a tenant-pool role (TENANT_POOL_ROLES):
# such a table must filter by RLS, whatever the reason says. ─────────────────────────────────────────────────────
TENANT_POOL_ROLES = ("aa_app_user",)
_CIS_ONLY = "platform table, cis_app only (no tenant-pool grant); tenant_id is filtered in code"
_GRANDFATHERED_TP = "grandfathered TripPlanner read (owners.yaml consumer_grants), removed by X4"
ALLOWLIST: dict[str, dict[str, str]] = {
    "a": {
        "shared.tenants": "the tenant registry itself (tenant_id is its key); cis_app only, no tenant-pool grant",
        "shared.tenant_api_usage": f"API metering written by the middleware; {_CIS_ONLY}",
        "shared.tenant_api_usage_monthly": f"API metering roll-up; {_CIS_ONLY}",
        "shared.llm_call_log": f"cost log of every app; tenant_id is attribution; {_CIS_ONLY}",
        "shared.llm_call_daily": f"cost log roll-up; tenant_id is attribution; {_CIS_ONLY}",
        "shared.dfs_call_log": f"DataForSEO cost log; tenant_id is attribution; {_CIS_ONLY}",
        "shared.decision_log": f"Jev decision audit; tenant_id is attribution; {_CIS_ONLY}",
        "shared.jev_tenant_allowlist": f"Jev rollout switch per tenant (admin-managed); {_CIS_ONLY}",
        "shared.notifications": f"staff notifications; {_CIS_ONLY}",
        "shared.acp_runs": f"legacy ACP v1 run table (pre-AA-751); {_CIS_ONLY}",
        "shared.tenant_brand_rules": f"tenant brand rules, admin + pipeline only; {_CIS_ONLY}",
        "shared.tenant_brand_rule_versions": f"history of tenant brand rules; {_CIS_ONLY}",
        "shared.tenant_brand_rules_deleted_aa404": f"AA-404 backup copy of deleted brand rules; {_CIS_ONLY}",
        "shared.tenant_export_config": f"tenant export settings, admin + pipeline only; {_CIS_ONLY}",
        "shared.tenant_rewrite_usage": f"rewrite quota counter; {_CIS_ONLY}",
        "shared.tenant_seo_config": f"tenant SEO settings, admin + pipeline only; {_CIS_ONLY}",
        "shared.unmapped_market_requests": f"admin triage list of market requests; {_CIS_ONLY}",
        "acp_contract.route_pick": f"tenant route picks written by the T-pipeline jobs; {_CIS_ONLY}",
        "acp_deliver.tenant_tour_pages": f"tenant page registry written by the publish job; {_CIS_ONLY}",
        "acp_shared.acp_output_rules": "RLS on with the X1 cis_app parity policy only (CIS 244); no tenant-pool grant",
        "acp_shared.acp_quota_ledger": f"tenant quota ledger; {_CIS_ONLY}",
        "acp_shared.audit_log": f"tenant action audit log; {_CIS_ONLY}",
        "acp_shared.debate_brand_fit_cache": f"pipeline cache keyed by tenant; {_CIS_ONLY}",
        "acp_shared.quarter_plan": f"tenant content plan, pipeline + admin only; {_CIS_ONLY}",
        "acp_shared.year_plan": f"tenant content plan, pipeline + admin only; {_CIS_ONLY}",
        "acp_shared.subject": f"tenant subjects, pipeline + admin only; {_CIS_ONLY}",
        "acp_shared.tenant_atom_state": f"per-tenant atom state, pipeline only; {_CIS_ONLY}",
        "acp_shared.tenant_config": f"tenant settings, admin + pipeline only; {_CIS_ONLY}",
        "silver_aa_internal.raw_sources": f"source registry, admin + pipeline only; {_CIS_ONLY}",
        "silver_aa_internal.review_queue": f"staff review queue; {_CIS_ONLY}",
        "silver_aa_internal.upload_staging": f"staff upload staging; {_CIS_ONLY}",
    },
    "b": {
        f"{t}:tenant_isolation": "legacy tenant_isolation TO PUBLIC (004/006, pre-X1); retire in a tenant-pool review"
        for t in ("gold_aa_internal.content_exports", "gold_aa_internal.published_tours",
                  "gold_aa_internal.webhook_deliveries", "shared.pipeline_runs",
                  "silver_aa_internal.generated_content", "silver_aa_internal.quality_scores",
                  "silver_aa_internal.raw_tours", "silver_aa_internal.seo_context")
    },
    "c": {},
    "d": {},
    "e": {
        "tripplanner.*->shared.destinations": "TripPlanner FKs to shared.destinations (ADR 0002), removed by X4",
    },
    "p": {
        "public": "PostgreSQL default USAGE on the public schema (extensions); no app object lives there",
    },
    "g": {
        # owners.yaml cis consumer_grants (contract = intended reads, schema-ownership rule 2)
        "catalog:booking": "contract: catalog schema USAGE for Booking (CIS 225, 228)",
        "catalog:tripplanner": "contract: catalog schema USAGE for TripPlanner (CIS 225, 228)",
        "catalog.*:booking": "contract: catalog.* views for Booking (CIS 225, 228)",
        "catalog.*:tripplanner": "contract: catalog.* views for TripPlanner (CIS 225, 228)",
        "shared.llm_call_log:tripplanner": "contract: standing INSERT exception for TripPlanner cost logging (CIS 173)",
        "shared:tripplanner": f"schema USAGE for the shared.* reads below; {_GRANDFATHERED_TP}",
        "shared.llm_role_config:tripplanner": f"CIS 173; {_GRANDFATHERED_TP}",
        "shared.llm_model_catalog:tripplanner": f"CIS 173; {_GRANDFATHERED_TP}",
        "shared.destinations:tripplanner": f"CIS 201; {_GRANDFATHERED_TP}",
        "shared.v_destination_photos:tripplanner": f"CIS 201; {_GRANDFATHERED_TP}",
        "shared.v_tour_photos:tripplanner": f"CIS 201; {_GRANDFATHERED_TP}",
        "silver_aa_internal:tripplanner": f"schema USAGE for the raw_tours columns; {_GRANDFATHERED_TP}",
        "silver_aa_internal.raw_tours.tour_id:tripplanner": f"CIS 179; {_GRANDFATHERED_TP}",
        "silver_aa_internal.raw_tours.country:tripplanner": f"CIS 179; {_GRANDFATHERED_TP}",
        "acp_contract:tripplanner": f"schema USAGE for the atom columns; {_GRANDFATHERED_TP}",
        "acp_contract.tour_atoms.*:tripplanner": f"column grants, CIS 180; {_GRANDFATHERED_TP}",
        "acp_contract.v_active_tour_atoms.*:tripplanner": f"column grants, CIS 216; {_GRANDFATHERED_TP}",
        "gold_aa_internal:tripplanner": f"schema USAGE for published_tours; {_GRANDFATHERED_TP}",
        "gold_aa_internal.published_tours:tripplanner": f"tenant RLS read; {_GRANDFATHERED_TP}",
        # owners.yaml cis owner_grants (CIS 243, MIG-2 self-registration)
        "shared:bk_owner": "contract: Booking owner role registers bk- keys (CIS 243)",
        "shared:tp_owner": "contract: TripPlanner owner role registers tp- keys (CIS 243)",
        "shared.schema_versions:bk_owner": "contract: bk- keys only, key guard (CIS 243)",
        "shared.schema_versions:tp_owner": "contract: tp- keys only, key guard (CIS 243)",
        # owners.yaml booking / tripplanner consumer_grants
        "booking:cis_app": "contract: schema USAGE for the CIS ops views (bk-017)",
        "booking.v_ops_funnel_daily:cis_app": "contract: CIS ops dashboard (bk-017)",
        "booking.v_ops_case_status:cis_app": "contract: CIS ops dashboard (bk-017)",
        "tripplanner:booking": "contract: schema USAGE for the inquiry outbox (tp-009)",
        "tripplanner.v_inquiry_outbox:booking": "contract: Booking inquiry intake (tp-009)",
        "tripplanner:cis_app": "contract: schema USAGE for the CIS ops view (tp-015)",
        "tripplanner.v_ops_traffic_daily:cis_app": "contract: CIS ops dashboard (tp-015)",
    },
    "t": {},
}


class Finding(NamedTuple):
    rule: str
    key: str
    detail: str
    hard: bool = False     # no allowlist entry covers it (rule a on a table the tenant pool can read)


def _policy_text(p: dict) -> str:
    return " ".join(x for x in (p.get("qual"), p.get("with_check")) if x)


def nullif_gaps(expr: Optional[str]) -> int:
    """How many current_setting('app.tenant_id' ...) calls in expr are not the first argument of NULLIF(."""
    if not expr:
        return 0
    return sum(1 for m in _TENANT_GUC_RE.finditer(expr) if not _NULLIF_OPEN_RE.search(expr[:m.start()]))


def _owner(schema: str) -> Optional[str]:
    return SCHEMA_OWNERS.get(schema)


def _grant_findings(obj: str, schema: str, grantee: str, privileges: str) -> list[Finding]:
    out = []
    if grantee == "PUBLIC":
        out.append(Finding("p", obj, f"PUBLIC: {privileges}"))
        return out
    grantee_owner = ROLE_OWNERS.get(grantee)
    obj_owner = _owner(schema)
    if grantee_owner and obj_owner and obj_owner != "platform" and grantee_owner != obj_owner:
        out.append(Finding("g", f"{obj}:{grantee}", f"{obj_owner} object to {grantee_owner} role: {privileges}"))
    return out


def findings(dump: dict) -> list[Finding]:
    """Every rule hit in the dump, allowlisted or not, sorted by (rule, key)."""
    out: list[Finding] = []
    for s in dump.get("schemas", []):
        for g in s.get("grants", []):
            out += _grant_findings(s["schema"], s["schema"], g["grantee"], g.get("privileges", ""))
    for schema, rels in sorted(dump.get("relations", {}).items()):
        for name, r in sorted(rels.items()):
            table = f"{schema}.{name}"
            policies = r.get("policies") or []
            cols = {c["name"] for c in r.get("columns") or []}
            if r.get("kind") in BASE_TABLE_KINDS and "tenant_id" in cols:
                tenant_policy = any("app.tenant_id" in _policy_text(p) for p in policies)
                if not (r.get("rls") and tenant_policy):
                    why = "RLS off" if not r.get("rls") else "no policy reads app.tenant_id"
                    pool = sorted({g["grantee"] for g in (r.get("grants") or []) + (r.get("column_grants") or [])}
                                  & set(TENANT_POOL_ROLES))
                    if pool:
                        why += f"; granted to tenant-pool role {', '.join(pool)} (cannot be allowlisted)"
                    out.append(Finding("a", table, why, bool(pool)))
            for p in policies:
                key = f"{table}:{p['policy']}"
                roles = list(p.get("roles") or ["public"])
                text = _policy_text(p)
                if "public" in roles:
                    out.append(Finding("b", key, f"TO {', '.join(roles)}"))
                if "app.current_tenant" in text:
                    out.append(Finding("c", key, "reads app.current_tenant"))
                gaps = nullif_gaps(p.get("qual")) + nullif_gaps(p.get("with_check"))
                if gaps:
                    out.append(Finding("d", key, f"{gaps} current_setting('app.tenant_id') outside NULLIF"))
                if p.get("permissive", "PERMISSIVE") == "PERMISSIVE" and \
                        "true" in ((p.get("qual") or "").strip(), (p.get("with_check") or "").strip()):
                    parity = (_owner(schema) == "cis" and len(roles) == 1 and roles[0] in CIS_PARITY_ROLES
                              and p["policy"] == name + CIS_PARITY_ROLES[roles[0]])
                    if not parity:
                        out.append(Finding("t", key, f"USING/WITH CHECK true TO {', '.join(roles)}"))
            for c in r.get("constraints") or []:
                if c.get("type") != "f":
                    continue
                ref = c.get("ref_schema")
                a, b = _owner(schema), _owner(ref)
                if a is None or b is None or a != b:
                    out.append(Finding("e", f"{table}:{c['constraint']}->{ref}.{c.get('ref_name')}",
                                       f"{a or 'no owner'} -> {b or 'no owner'}"))
            for g in r.get("grants") or []:
                out += _grant_findings(table, schema, g["grantee"], g.get("privileges", ""))
            for g in r.get("column_grants") or []:
                out += _grant_findings(f"{table}.{g['column']}", schema, g["grantee"], g.get("privileges", ""))
    return sorted(set(out))


def merge_allowlists(*lists: dict) -> dict[str, dict[str, str]]:
    """Union of allowlists (later entries win on a duplicate key)."""
    out: dict[str, dict[str, str]] = {r: {} for r in RULES}
    for al in lists:
        for rule, entries in al.items():
            out.setdefault(rule, {}).update(entries)
    return out


def check_allowlist(allowlist: dict) -> list[str]:
    """Problems with the allowlist itself: unknown rule letter, empty or multi-line reason."""
    problems = []
    for rule, entries in allowlist.items():
        if rule not in RULES:
            problems.append(f"unknown rule {rule!r}")
            continue
        for key, reason in entries.items():
            if not isinstance(reason, str) or not reason.strip() or "\n" in reason:
                problems.append(f"rule {rule} {key}: the reason must be one non-empty line")
    return problems


class Result(NamedTuple):
    violations: list        # findings not on the allowlist (a guarded run fails on these)
    allowlisted: list       # (finding, reason)
    stale: list             # (rule, key) allowlist entries that matched nothing


def _match(entries: dict, key: str) -> Optional[str]:
    """The allowlist key that covers `key`: an exact entry first, then a `*` pattern (sorted, first match)."""
    if key in entries:
        return key
    return next((k for k in sorted(entries) if "*" in k and fnmatch.fnmatchcase(key, k)), None)


def check(dump: dict, allowlist: Optional[dict] = None) -> Result:
    al = ALLOWLIST if allowlist is None else allowlist
    violations, allowlisted, used = [], [], set()
    for f in findings(dump):
        entries = al.get(f.rule, {})
        entry = None if f.hard else _match(entries, f.key)
        if entry and entries[entry]:
            allowlisted.append((f, entries[entry]))
            used.add((f.rule, entry))
        else:
            violations.append(f)
    stale = sorted((r, k) for r, entries in al.items() for k in entries if (r, k) not in used)
    return Result(violations, allowlisted, stale)


def format_findings(items: Iterable[Finding]) -> str:
    return "\n".join(f"  [{f.rule}] {f.key}: {f.detail} ({RULES[f.rule]})" for f in items)


# ── Catalog reads for a live database (the CIS CI replay). Same row shapes as AA-CIS-Infra db/schema_dump.py
# QUERIES (only the keys the rules read); every query takes $1 / %(schemas)s = the schema list. ───────────────
_NOT_EXTENSION = ("NOT EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.classid = 'pg_class'::regclass "
                  "AND dep.objid = c.oid AND dep.deptype = 'e')")
_GRANTEE = "CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END"
CATALOG_SQL = {
    "schemas": """
SELECT n.nspname AS schema FROM pg_namespace n
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast') AND n.nspname !~ '^pg_(temp|toast_temp)_'
ORDER BY 1""",
    "schema_grants": f"""
SELECT n.nspname AS schema, {_GRANTEE} AS grantee, string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
       AS privileges
FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
WHERE n.nspname = ANY(%(schemas)s) AND a.grantee <> n.nspowner GROUP BY 1, 2 ORDER BY 1, 2""",
    "relations": f"""
SELECT n.nspname AS schema, c.relname AS name, c.relkind::text AS kind, c.relrowsecurity AS rls
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY(%(schemas)s) AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND {_NOT_EXTENSION}
ORDER BY 1, 2""",
    "columns": """
SELECT n.nspname AS schema, c.relname AS name, a.attname AS column
FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY(%(schemas)s) AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0
  AND NOT a.attisdropped ORDER BY 1, 2, a.attnum""",
    "constraints": """
SELECT n.nspname AS schema, c.relname AS name, con.conname AS constraint, con.contype::text AS type,
       fn.nspname AS ref_schema, fc.relname AS ref_name
FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_class fc ON fc.oid = con.confrelid LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
WHERE n.nspname = ANY(%(schemas)s) AND con.contype = 'f' ORDER BY 1, 2, 3""",
    "policies": """
SELECT schemaname AS schema, tablename AS name, policyname AS policy, permissive, roles::text[] AS roles, cmd,
       qual, with_check
FROM pg_policies WHERE schemaname = ANY(%(schemas)s) ORDER BY 1, 2, 3""",
    "table_grants": f"""
SELECT n.nspname AS schema, c.relname AS name, {_GRANTEE} AS grantee,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a
WHERE n.nspname = ANY(%(schemas)s) AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.grantee <> c.relowner
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3""",
    "column_grants": f"""
SELECT n.nspname AS schema, c.relname AS name, att.attname AS column, {_GRANTEE} AS grantee,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privileges
FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(att.attacl) a
WHERE n.nspname = ANY(%(schemas)s) AND att.attnum > 0 AND NOT att.attisdropped
GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 4, 3""",
}
_KIND = {"r": "table", "p": "partitioned table", "v": "view", "m": "materialized view", "f": "foreign table"}


def dump_from_rows(rows: dict) -> dict:
    """The part of a format-2 dump the rules read, from CATALOG_SQL results (lists of dicts)."""
    def per(key):
        out: dict = {}
        for r in rows.get(key, []):
            out.setdefault((r["schema"], r["name"]), []).append(r)
        return out
    cols, cons, pols, grants, cgrants = (per(k) for k in ("columns", "constraints", "policies", "table_grants",
                                                          "column_grants"))
    sgrants: dict = {}
    for g in rows.get("schema_grants", []):
        sgrants.setdefault(g["schema"], []).append({"grantee": g["grantee"], "privileges": g["privileges"]})
    relations: dict = {s["schema"]: {} for s in rows.get("schemas", [])}
    for r in rows.get("relations", []):
        k = (r["schema"], r["name"])
        relations.setdefault(r["schema"], {})[r["name"]] = {
            "kind": _KIND.get(r["kind"], r["kind"]), "rls": bool(r["rls"]),
            "columns": [{"name": c["column"]} for c in cols.get(k, [])],
            "constraints": [{"constraint": c["constraint"], "type": c["type"], "ref_schema": c["ref_schema"],
                             "ref_name": c["ref_name"]} for c in cons.get(k, [])],
            "policies": [{x: p[x] for x in ("policy", "permissive", "roles", "cmd", "qual", "with_check")}
                         for p in pols.get(k, [])],
            "grants": [{"grantee": g["grantee"], "privileges": g["privileges"]} for g in grants.get(k, [])],
            "column_grants": [{"column": g["column"], "grantee": g["grantee"], "privileges": g["privileges"]}
                              for g in cgrants.get(k, [])],
        }
    return {"schemas": [{"schema": s["schema"], "grants": sgrants.get(s["schema"], [])}
                        for s in rows.get("schemas", [])],
            "relations": relations}
