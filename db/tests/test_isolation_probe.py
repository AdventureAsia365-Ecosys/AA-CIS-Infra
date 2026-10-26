"""Unit tests for db/isolation_probe.py (X1 plan S2): pure helpers, cell statuses keyed to live state,
the emitted records, and the two workflows that start it. No database, no AWS (the DB part was run
against a throwaway PostgreSQL, see docs/implementation-notes/AA-852-s2-isolation-probe.md).

Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import copy
import io
import json
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "db"))

import isolation_probe as p  # noqa: E402

API_ARN = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/rds-AbC123"
CIS_APP_ARN = "arn:aws:secretsmanager:us-west-1:005097885195:secret:aa-cis/dev/rds-cis-app-XyZ789"
WORKFLOW = (ROOT / ".github" / "workflows" / "db-isolation-probe.yml").read_text(encoding="utf-8")
MIGRATE_WORKFLOW = (ROOT / ".github" / "workflows" / "db-migrate.yml").read_text(encoding="utf-8")


TTP = "acp_deliver.tenant_tour_pages"
ATOMS = "acp_contract.tour_atoms"
QP = "acp_shared.quarter_plan"
QPV = "acp_shared.quarter_plan_version"
AGR = "acp_shared.angle_gate_request"
AGO = "acp_shared.angle_gate_option"
T1 = "11111111-1111-4111-8111-111111111111"
T2 = "22222222-2222-4222-8222-222222222222"
GUC = "NULLIF(current_setting('app.tenant_id'::text, true), ''::text)"
TTP_OWN = f"(tenant_id = {GUC})"


def role(name, **kw):
    info = {"exists": True, "rolname": name, "login": True, "super": False, "bypassrls": False,
            "createrole": False, "createdb": False, "replication": False, "connlimit": 15, "comment": None,
            "chain": [], "owned": []}
    info.update(kw)
    return info


def owner_role(name, exists=True):
    return {"exists": exists, "rolname": name, "login": False, "super": False, "bypassrls": False,
            "createrole": False, "createdb": False, "replication": False} if exists else {"exists": False}


def defacl(schema, for_role, grantee_privs):
    """DEFAULT_ACL_SQL rows: {objtype: [privileges granted to the runtime role]}."""
    return [{"schema": schema, "objtype": t, "for_role": for_role, "privileges": sorted(pr)}
            for t, pr in grantee_privs.items()]


BK_DEFACL = {"r": ["DELETE", "INSERT", "SELECT", "UPDATE"], "S": ["SELECT", "USAGE"], "f": ["EXECUTE"]}
TP_DEFACL = {"r": ["DELETE", "INSERT", "SELECT", "UPDATE"], "S": ["SELECT", "USAGE"]}


def denied(target):
    return {"readable": False, "sqlstate": "42501", "error": f"42501 InsufficientPrivilegeError: {target}"}


def today_facts():
    """The live state of 17/10 (CIS 242, bk-013, tp-012, no X1 role yet), as the probe would collect it."""
    master_owned = [{"kind": "relation", "name": "shared.job"}]
    return {
        "catalog": {"login": "aa_cis_admin", "registered": [], "server_version": "15.17",
                    "anchor_owner": {"shared": "aa_cis_admin", "booking": "aa_cis_admin",
                                     "tripplanner": "aa_cis_admin"}},
        "roles": {
            "aa_app_user": role("aa_app_user"), "booking": role("booking"),
            "tripplanner": role("tripplanner", connlimit=30),
            "aa_cis_admin": role("aa_cis_admin", connlimit=-1, chain=["pg_read_all_data", "rds_superuser"],
                                 owned=master_owned, createrole=True, createdb=True),
            "cis_app": {"exists": False}, "bk_owner": owner_role("bk_owner", False),
            "tp_owner": owner_role("tp_owner", False), "cis_owner": owner_role("cis_owner", False)},
        "ownership": {
            "cis": {"offenders": [{"kind": "relation", "name": "shared.job", "owner": "aa_cis_admin"}]},
            "booking": {"offenders": [{"kind": "schema", "name": "booking", "owner": "aa_cis_admin"}]},
            "tripplanner": {"offenders": [{"kind": "schema", "name": "tripplanner", "owner": "aa_cis_admin"}]}},
        "owner_grants": {"bk_owner": {"error": "role bk_owner does not exist"},
                         "tp_owner": {"error": "role tp_owner does not exist"}},
        "registry_writes": {"cis_app": {"error": "role cis_app does not exist"}},
        "runtime_grants": {"cis": {"cis_app": {"error": "role cis_app does not exist"}},
                           "booking": {"booking": {"missing": []}},
                           "tripplanner": {"tripplanner": {"missing": []}}},
        "default_acl": {"cis": {"cis_app": {"error": "role cis_app does not exist"}},
                        "booking": {"booking": {"rows": defacl("booking", "aa_cis_admin", BK_DEFACL)}},
                        "tripplanner": {"tripplanner": {"rows": defacl("tripplanner", "aa_cis_admin", TP_DEFACL)}}},
        # Grants keyed on a later migration (AA-858 bk-017 / tp-015) are not applied yet: their views are absent.
        "consumer": {"grants": [{"grantee": g, "object": o, "privileges": list(pr), "missing": ["absent"] if k else [],
                                 "from": k} for g, pr, o, k in p.CONSUMER_GRANTS]},
        "rls_enable_only": {"tables": [{"fq": "gold_aa_internal.tenant_tour_versions", "has_policy": False}]},
        "tenant_matrix": {"modes": ["unset", "empty", "forged", "tenant:master", "tenant:t1"], "tables": {
            "gold_aa_internal.published_tours": {
                "unset": {"visible": 1, "cross": 0}, "forged": {"visible": 1, "cross": 0},
                "tenant:t1": {"visible": 3, "cross": 0}},
            "shared.pipeline_runs": {"unset": {"error": "42501 InsufficientPrivilegeError: x"}}}},
        "ttv": {"reference": [48, 48], "runtime": 48},
        "sessions": {"master": {"sessions": [{"app": "cis-api", "n": 1}, {"app": "cis-worker", "n": 2}]},
                     "db_migrator": {"error": "role db_migrator does not exist"}},
        "logins": {
            "aa_app_user": {"secret": "aa-cis/dev/rds-app-user", "secret_user": "aa_app_user",
                            "current_user": "aa_app_user",
                            "cross": {"booking.customers": denied("booking"), "tripplanner.sessions": denied("tp")}},
            "booking": {"secret": "booking/dev/database-url", "secret_user": "booking", "current_user": "booking",
                        "cross": {"tripplanner.sessions": denied("tp"), "shared.tenants": denied("shared")}},
            "tripplanner": {"secret": "tripplanner/dev/database-url", "secret_user": "tripplanner",
                            "current_user": "tripplanner", "cross": {"booking.customers": denied("booking")}},
            "cis_app": {"secret": "aa-cis/dev/rds-cis-app",
                        "error": "secret aa-cis/dev/rds-cis-app: ClientError ResourceNotFoundException"},
            "cis_runtime": {"secret": "aa-cis/dev/rds", "secret_user": "aa_cis_admin", "current_user": "aa_cis_admin",
                            "cross": {"booking.customers": {"readable": True, "sqlstate": None},
                                      "tripplanner.sessions": {"readable": True, "sqlstate": None}}}},
        "cis_runtime": {"value_from": API_ARN, "secret": "aa-cis/dev/rds", "user": "aa_cis_admin"},
    }


def statuses(facts):
    keys = p.state_keys(facts)
    return {c.id: c.status(keys) for c in p.build_cells(facts, keys)}, keys


class HelpersTest(unittest.TestCase):
    def test_secret_name_and_id(self):
        self.assertEqual(p.secret_name(API_ARN), "aa-cis/dev/rds")
        self.assertEqual(p.secret_name(CIS_APP_ARN), "aa-cis/dev/rds-cis-app")
        self.assertEqual(p.secret_name(CIS_APP_ARN + ":url::"), "aa-cis/dev/rds-cis-app")
        self.assertEqual(p.secret_name("booking/dev/database-url"), "booking/dev/database-url")
        self.assertEqual(p.secret_name(""), "")
        self.assertEqual(p.secret_id(CIS_APP_ARN + ":url::"), CIS_APP_ARN)
        self.assertEqual(p.secret_id("aa-cis/dev/rds-app-user"), "aa-cis/dev/rds-app-user")

    def test_normalize_dsn(self):
        self.assertEqual(p.normalize_dsn(" postgresql://u:p@h:5432/d \n"), "postgresql://u:p@h:5432/d")
        self.assertEqual(p.normalize_dsn("postgresql+asyncpg://u:p@h/d"), "postgresql://u:p@h/d")
        self.assertEqual(p.normalize_dsn("postgres://u:p@h/d"), "postgres://u:p@h/d")
        self.assertEqual(p.normalize_dsn('{"url": "postgresql+asyncpg://u:p@h/d"}'), "postgresql://u:p@h/d")
        self.assertEqual(p.normalize_dsn('{"host": "h", "username": "cis_app", "password": "/", "dbname": "d"}'),
                         "postgresql://cis_app:%2F@h:5432/d")
        for bad in (None, "", "REPLACE_ME", "{not json", '{"x": 1}', "mysql://u@h/d"):
            self.assertIsNone(p.normalize_dsn(bad), bad)

    def test_dsn_user(self):
        self.assertEqual(p.dsn_user("postgresql://cis_app:x@h/d"), "cis_app")
        self.assertEqual(p.dsn_user("postgresql://a%40b:x@h/d"), "a@b")
        self.assertIsNone(p.dsn_user(None))
        self.assertIsNone(p.dsn_user("postgresql://h/d"))

    def test_safe_err_never_carries_a_dsn(self):
        dsn = "postgresql://cis_app:dummy@host/db"
        self.assertEqual(p.safe_err(ValueError(f"invalid DSN {dsn}")), "ValueError")

        class PgErr(Exception):
            sqlstate = "42501"
        self.assertEqual(p.safe_err(PgErr("permission denied for schema booking\nDETAIL: x")),
                         "42501 PgErr: permission denied for schema booking")

        class ClientError(Exception):
            response = {"Error": {"Code": "ResourceNotFoundException", "Message": dsn}}
        self.assertEqual(p.safe_err(ClientError(dsn)), "ClientError ResourceNotFoundException")

    def test_chain_violations(self):
        self.assertEqual(p.chain_violations([]), [])
        self.assertEqual(p.chain_violations(["pg_monitor", "rds_superuser", "catalog_owner", "pg_read_all_data",
                                             "aa_cis_admin", "bk_owner"]),
                         ["aa_cis_admin", "bk_owner", "catalog_owner", "pg_read_all_data", "rds_superuser"])

    def test_allowed_tenant_constants(self):
        pol = [{"fq": "gold_aa_internal.published_tours",
                "qual": "(tenant_id = '00000000-0000-0000-0000-000000000001'::uuid)"},
               {"fq": "gold_aa_internal.published_tours",
                "qual": "(tenant_id = (NULLIF(current_setting('app.tenant_id'::text, true), ''::text))::uuid)"},
               {"fq": "acp_shared.facts", "qual": "(scope = 'platform'::text)"}]
        self.assertEqual(p.allowed_tenant_constants(pol),
                         {"gold_aa_internal.published_tours": [p.MASTER_TENANT]})

    def test_allowed_constants_text_cast_and_platform_scope(self):
        # AA-859 wave 4, as pg_policies deparses CIS 265 / 266 (db-schema-reference.md after 268): the text tenant_id of
        # tenant_tour_pages compares with a '::text' literal; tour_atoms' platform atoms with owner_scope.
        pol = [{"fq": TTP, "qual": f"(tenant_id = '{p.MASTER_TENANT}'::text)"},
               {"fq": TTP, "qual": TTP_OWN},
               {"fq": ATOMS, "qual": "(owner_scope = 'platform'::text)"},
               {"fq": ATOMS, "qual": "(owner_scope = NULLIF(current_setting('app.tenant_id'::text, true), ''::text))"},
               {"fq": "acp_shared.x", "qual": f"((tenant_id)::text = '{p.MASTER_TENANT.upper()}'::text)"}]
        self.assertEqual(p.allowed_tenant_constants(pol), {TTP: [p.MASTER_TENANT], ATOMS: ["platform"],
                                                           "acp_shared.x": [p.MASTER_TENANT]})

    def test_allowed_constants_never_share_another_tenants_id(self):
        # A policy that hands one tenant's rows to every tenant is not a shared catalog, whatever the cast.
        pol = [{"fq": TTP, "qual": f"(tenant_id = '{T2}'::text)"},
               {"fq": "gold_aa_internal.published_tours", "qual": f"(tenant_id = '{T2}'::uuid)"},
               {"fq": ATOMS, "qual": f"(owner_scope = '{T2}'::text)"}]
        self.assertEqual(p.allowed_tenant_constants(pol), {})

    def test_rls_tables_report_the_tenant_scope_column(self):
        self.assertEqual(p.TENANT_SCOPE_COLUMNS, ("tenant_id", "owner_scope"))     # tenant_id wins when both exist
        self.assertIn("AS tenant_col", p.RLS_TABLES_SQL)
        self.assertIn("array_position($2::text[]", p.RLS_TABLES_SQL)

    def test_runtime_grants_leave_partitions_out(self):
        # AA-940 review: crm-007 revokes crm_app's rights on every crm.audit_event partition (reached through the
        # parent only) and makes a new partition every month; counting them would keep runtime_grants.crm red.
        relation = re.search(r"SELECT 'relation'.*?UNION ALL", p.RUNTIME_MISSING_SQL, re.S).group(0)
        self.assertIn("c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relispartition", relation)
        # The parent itself (relkind 'p', not a partition) is still checked.
        self.assertNotIn("relkind <> 'p'", p.RUNTIME_MISSING_SQL)

    def test_matrix_count_sql(self):
        ttp = p.matrix_count_sql({"fq": TTP, "q": '"acp_deliver"."tenant_tour_pages"', "tenant_col": "tenant_id"})
        self.assertIn("tenant_id::text IS DISTINCT FROM $1", ttp)
        self.assertIn("lower(tenant_id::text) = ANY($2::text[])", ttp)
        atoms = p.matrix_count_sql({"fq": ATOMS, "q": '"acp_contract"."tour_atoms"', "tenant_col": "owner_scope"})
        self.assertIn("owner_scope IS NOT NULL AND owner_scope::text IS DISTINCT FROM $1", atoms)
        self.assertIn('FROM "acp_contract"."tour_atoms"', atoms)
        qpv = p.matrix_count_sql({"fq": QPV, "q": '"acp_shared"."quarter_plan_version"', "tenant_col": None})
        self.assertIn("NOT EXISTS (SELECT 1 FROM acp_shared.quarter_plan p WHERE p.plan_id = c.plan_id", qpv)
        self.assertIn("p.tenant_id::text = $1", qpv)
        self.assertTrue(qpv.endswith('FROM "acp_shared"."quarter_plan_version" c'))
        ago = p.matrix_count_sql({"fq": AGO, "q": '"acp_shared"."angle_gate_option"', "tenant_col": None})
        self.assertIn("NOT EXISTS (SELECT 1 FROM acp_shared.angle_gate_request p "
                      "WHERE p.request_id = c.request_id", ago)
        # No tenant column and no parent: the caller counts every visible row as foreign without a real tenant.
        self.assertIsNone(p.matrix_count_sql({"fq": "acp_shared.some_new_table", "q": "x", "tenant_col": None}))

    def test_every_rls_table_without_a_tenant_column_is_parent_scoped(self):
        # db-schema-reference.md (dump after 268): the only RLS tables of the CIS schemas with neither tenant_id nor
        # owner_scope are these two, each with a pool policy through its parent.
        self.assertEqual(set(p.PARENT_SCOPED), {AGO, QPV})
        for fq, (key, parent, pkey) in p.PARENT_SCOPED.items():
            self.assertEqual(fq.split(".")[0], parent.split(".")[0])
            self.assertEqual((key, pkey), {AGO: ("request_id",) * 2, QPV: ("plan_id",) * 2}[fq])

    def test_tenant_labels_hide_ids(self):
        ids = ["22222222-2222-2222-2222-222222222222", p.MASTER_TENANT, "33333333-3333-3333-3333-333333333333"]
        self.assertEqual(list(p.tenant_labels(ids).values()), ["t1", "master", "t2"])

    def test_ownership_offenders_view_owner_only_on_views(self):
        rows = [{"kind": "view", "name": "catalog.v_tour", "owner": "catalog_owner"},
                {"kind": "relation", "name": "shared.x", "owner": "catalog_owner"},
                {"kind": "function", "name": "geo.f()", "owner": "aa_cis_admin"}]
        self.assertEqual([r["name"] for r in p.ownership_offenders(rows, p.OWNERS["cis"])], ["shared.x", "geo.f()"])
        self.assertEqual(len(p.ownership_offenders(rows[:1], p.OWNERS["booking"])), 1)

    def test_parse_config(self):
        cfg = {"cis_runtime_secret": API_ARN}
        self.assertEqual(p.parse_config(["-c", "https://presigned", json.dumps(cfg)]), cfg)   # python3 -c … url cfg
        self.assertEqual(p.parse_config(["db/isolation_probe.py", json.dumps(cfg)]), cfg)
        self.assertEqual(p.parse_config(["db/isolation_probe.py"]), {})


class CellStatusTest(unittest.TestCase):
    def test_expected_and_pending(self):
        keys = {"rl-001": True, "245": False}
        self.assertEqual(p.Cell("a", "g", "t", (), ok=True).status(keys), "pass")
        self.assertEqual(p.Cell("a", "g", "t", (), ok=False).status(keys), "FAIL")
        self.assertEqual(p.Cell("a", "g", "t", ("rl-001",), ok=True, error="x").status(keys), "FAIL")
        self.assertEqual(p.Cell("a", "g", "t", ("245",), ok=False).status(keys), "pending")
        self.assertEqual(p.Cell("a", "g", "t", ("245",), ok=True).status(keys), "ready")
        self.assertEqual(p.Cell("a", "g", "t", ("rl-001", "245"), ok=False).status(keys), "pending")
        self.assertEqual(p.Cell("a", "g", "t", ("unknown-key",), ok=False).status(keys), "pending")

    def test_pending_without_key_fails_once_it_passes(self):
        self.assertEqual(p.Cell("a", "g", "t", pending_without_key=True, ok=False).status({}), "pending")
        self.assertEqual(p.Cell("a", "g", "t", pending_without_key=True, ok=True).status({}), "FAIL")

    def test_warn_flag_only_while_pending(self):
        c = p.Cell("a", "g", "t", ("catalog_login_not_master",), ok=False, warn_while_pending=True)
        self.assertTrue(c.as_json({})["warn"])
        self.assertNotIn("warn", c.as_json({"catalog_login_not_master": True}))


class BuildCellsTest(unittest.TestCase):
    def test_today_state_is_green_with_pending_cells(self):
        st, keys = statuses(today_facts())
        self.assertNotIn("FAIL", st.values(), {k: v for k, v in st.items() if v == "FAIL"})
        self.assertFalse(any(keys[k] for k in p.VERSION_KEYS))
        for cid in ("cross.booking.tripplanner.sessions", "cross.booking.shared.tenants",
                    "cross.tripplanner.booking.customers", "cross.aa_app_user.booking.customers",
                    "role.booking.membership", "role.tripplanner.connection_limit", "login.aa_app_user",
                    "tenant.aa_app_user_isolation", "tenant.cis_runtime_sees_all_ttv"):
            self.assertEqual(st[cid], "pass", cid)
        for cid in ("cross.cis_runtime.booking.customers", "role.cis_runtime.membership", "ownership.booking",
                    "ownership.cis", "registry.bk_owner", "role.cis_app.attributes", "login.cis_app",
                    "rls.enable_only_has_cis_app_policy", "sessions.master_break_glass_only",
                    "sessions.db_migrator_below_limit", "owner_role.cis_owner"):
            self.assertEqual(st[cid], "pending", cid)
        self.assertEqual(st["role.cis_runtime.attributes"], "pending")  # the master has CREATEROLE, CREATEDB
        for cid in ("runtime_grants.booking", "default_acl.booking", "runtime_grants.tripplanner",
                    "default_acl.tripplanner"):
            self.assertEqual(st[cid], "ready", cid)                        # hold today, expected from the transfer
        for cid in ("runtime_grants.cis", "default_acl.cis"):
            self.assertEqual(st[cid], "pending", cid)                      # cis_app: from 244
        self.assertEqual(st["consumer.contract_grants"], "pass")

    def test_every_cross_app_pair_has_a_cell(self):
        st, _ = statuses(today_facts())
        for r, target, _w in p.CROSS_APP:
            self.assertIn(f"cross.{r}.{target}", st)

    def test_keys_flip_cells_to_expected(self):
        f = today_facts()
        f["catalog"]["registered"] = ["rl-001", "bk-014"]
        f["catalog"]["anchor_owner"]["booking"] = "bk_owner"
        st, _ = statuses(f)
        self.assertEqual(st["ownership.booking"], "FAIL")        # transferred, but an object is still the master's
        self.assertEqual(st["role.cis_app.attributes"], "FAIL")  # rl-001 registered, cis_app missing
        f["ownership"]["booking"] = {"offenders": []}
        f["default_acl"]["booking"]["booking"]["rows"] = defacl("booking", "bk_owner", BK_DEFACL)
        f["roles"]["cis_app"] = role("cis_app", connlimit=90)
        f["roles"]["bk_owner"] = owner_role("bk_owner")
        f["roles"]["tp_owner"] = owner_role("tp_owner")
        f["registry_writes"]["cis_app"] = {"insert": False, "update": False, "delete": False, "truncate": False}
        st, _ = statuses(f)
        self.assertEqual({k: v for k, v in st.items() if v == "FAIL"}, {})
        self.assertEqual(st["ownership.booking"], "pass")
        self.assertEqual(st["registry.cis_app"], "pass")
        self.assertEqual(st["registry.bk_owner"], "pending")     # 243 not yet

    def test_transfer_key_needs_the_live_anchor_owner(self):
        # Registry rows are never deleted: after a planned rollback (roles/ undo file) bk-014 stays
        # registered while schema booking is the master's again — pending, not a nightly FAIL.
        f = today_facts()
        f["catalog"]["registered"] = ["rl-001", "243", "bk-014"]
        st, keys = statuses(f)
        self.assertFalse(keys["booking_transferred"])
        self.assertEqual(st["ownership.booking"], "pending")
        self.assertEqual(st["runtime_grants.booking"], "ready")
        f["catalog"]["anchor_owner"]["booking"] = "bk_owner"             # transfer in force
        st, keys = statuses(f)
        self.assertTrue(keys["booking_transferred"])
        self.assertEqual(st["ownership.booking"], "FAIL")
        f["catalog"]["registered"] = ["rl-001", "243"]                   # anchor moved but no key: not expected
        st, keys = statuses(f)
        self.assertFalse(keys["booking_transferred"])
        self.assertEqual(st["ownership.booking"], "pending")

    def test_createrole_runtime_role_fails(self):
        for attr in ("createrole", "createdb", "replication", "super", "bypassrls"):
            with self.subTest(attr=attr):
                f = today_facts()
                f["roles"]["tripplanner"][attr] = True
                st, _ = statuses(f)
                self.assertEqual(st["role.tripplanner.attributes"], "FAIL")
        f = today_facts()
        f["catalog"]["registered"] = ["rl-001"]
        f["roles"]["bk_owner"] = owner_role("bk_owner")
        f["roles"]["bk_owner"]["createrole"] = True
        st, _ = statuses(f)
        self.assertEqual(st["owner_role.bk_owner"], "FAIL")

    def test_runtime_grants_expected_after_the_transfer(self):
        f = today_facts()
        f["catalog"]["registered"] = ["rl-001", "243", "bk-014"]
        f["catalog"]["anchor_owner"]["booking"] = "bk_owner"
        f["ownership"]["booking"] = {"offenders": []}
        f["default_acl"]["booking"]["booking"]["rows"] = defacl("booking", "bk_owner", BK_DEFACL)
        st, _ = statuses(f)
        self.assertEqual((st["runtime_grants.booking"], st["default_acl.booking"]), ("pass", "pass"))
        f["runtime_grants"]["booking"]["booking"] = {"missing": [{"kind": "relation", "name": "booking.new_t",
                                                                 "missing": "SELECT"}]}
        st, _ = statuses(f)
        self.assertEqual(st["runtime_grants.booking"], "FAIL")

    def test_default_acl_findings(self):
        bk = p.OWNERS["booking"]
        rp = bk.runtime_privileges[0]
        today = defacl("booking", "aa_cis_admin", BK_DEFACL)
        self.assertEqual(p.default_acl_findings(today, rp, bk, "aa_cis_admin"), [])
        # bk-014 forgot the FOR ROLE bk_owner rows: the master's rows no longer follow the creator.
        found = p.default_acl_findings(defacl("booking", "aa_cis_admin", BK_DEFACL), rp, bk, "bk_owner")
        self.assertIn("no default privileges FOR ROLE bk_owner IN SCHEMA booking ON TABLES", found)
        self.assertIn("FOR ROLE aa_cis_admin IN SCHEMA booking ON FUNCTIONS left after the transfer", found)
        rows = defacl("booking", "bk_owner", {**BK_DEFACL, "f": []}) + defacl("booking", "aa_cis_admin", {"r": []})
        self.assertEqual(p.default_acl_findings(rows, rp, bk, "bk_owner"),
                         ["FOR ROLE aa_cis_admin IN SCHEMA booking ON TABLES left after the transfer",
                          "FOR ROLE bk_owner IN SCHEMA booking ON FUNCTIONS: booking lacks EXECUTE"])
        cis = p.OWNERS["cis"]
        found = p.default_acl_findings([], cis.runtime_privileges[0], cis, "aa_cis_admin")
        self.assertEqual(len(found), 11 * 3)                            # 11 schemas (no catalog) x 3 object types

    def test_cis_app_grants_keyed_on_244(self):
        f = today_facts()
        f["catalog"]["registered"] = ["rl-001", "244"]
        f["roles"]["cis_app"] = role("cis_app", connlimit=90)
        f["runtime_grants"]["cis"]["cis_app"] = {"missing": [{"kind": "schema", "name": "acp_silver_s4",
                                                              "missing": "USAGE"}]}
        f["default_acl"]["cis"]["cis_app"] = {"rows": []}
        st, _ = statuses(f)
        self.assertEqual((st["runtime_grants.cis"], st["default_acl.cis"]), ("FAIL", "FAIL"))

    def test_consumer_grant_lost_fails(self):
        f = today_facts()
        f["consumer"]["grants"][1]["missing"] = ["SELECT"]                # booking on v_inquiry_outbox
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants"], "FAIL")

    def test_keyed_consumer_grants_wait_for_their_migration(self):
        # AA-858: cis_app reads booking.v_ops_* (bk-017) and tripplanner.v_ops_traffic_daily (tp-015). Merged into
        # the registry before the DB Migrate apply, the views are absent: pending, never FAIL, and the always-expected
        # cell is unaffected.
        # bk-023: AA-835 supply views; bk-025 / tp-020: AA-992 data coverage views.
        self.assertEqual(p.CONSUMER_GRANT_KEYS, ("bk-017", "bk-023", "bk-025", "tp-015", "tp-020"))
        for k in p.CONSUMER_GRANT_KEYS:
            self.assertIn(k, p.VERSION_KEYS)
            self.assertIn(k, p.KEY_TEXT)
        st, keys = statuses(today_facts())
        self.assertFalse(any(keys[k] for k in p.CONSUMER_GRANT_KEYS))
        for k in p.CONSUMER_GRANT_KEYS:
            self.assertEqual(st[f"consumer.contract_grants.{k}"], "pending")
        self.assertEqual(st["consumer.contract_grants"], "pass")

    def test_keyed_consumer_grants_expected_once_registered(self):
        f = today_facts()
        f["catalog"]["registered"] = ["bk-017"]
        for c in f["consumer"]["grants"]:
            if c["from"] == "bk-017":
                c["missing"] = []
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.bk-017"], "pass")
        self.assertEqual(st["consumer.contract_grants.bk-023"], "pending")
        self.assertEqual(st["consumer.contract_grants.tp-015"], "pending")
        next(c for c in f["consumer"]["grants"]
             if c["object"] == "booking.v_ops_case_status")["missing"] = ["SELECT"]
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.bk-017"], "FAIL")
        f = today_facts()
        f["catalog"]["registered"] = ["tp-015"]                          # registered but the view is absent
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.tp-015"], "FAIL")

    def test_keyed_consumer_grant_ready_before_its_key(self):
        f = today_facts()
        for c in f["consumer"]["grants"]:
            if c["from"] == "tp-015":
                c["missing"] = []
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.tp-015"], "ready")

    def test_data_coverage_grants_are_their_own_cells(self):
        # AA-992: the five data coverage views wait for tp-020 / bk-025; registering bk-025 with both views granted
        # passes its cell and leaves tp-020 pending; a missing SELECT on the keys view fails only bk-025.
        objs = {c[2] for c in p.CONSUMER_GRANTS if c[3] in ("bk-025", "tp-020")}
        self.assertEqual(objs, {"booking.v_ops_data_totals", "booking.v_ops_trip_plan_keys",
                                "tripplanner.v_ops_data_totals", "tripplanner.v_ops_pin_components",
                                "tripplanner.v_ops_component_id_map"})
        f = today_facts()
        f["catalog"]["registered"] = ["bk-025"]
        for c in f["consumer"]["grants"]:
            if c["from"] == "bk-025":
                c["missing"] = []
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.bk-025"], "pass")
        self.assertEqual(st["consumer.contract_grants.tp-020"], "pending")
        next(c for c in f["consumer"]["grants"]
             if c["object"] == "booking.v_ops_trip_plan_keys")["missing"] = ["SELECT"]
        st, _ = statuses(f)
        self.assertEqual(st["consumer.contract_grants.bk-025"], "FAIL")
        self.assertEqual(st["consumer.contract_grants.bk-017"], "pending")

    def test_cis_app_login_waits_for_set_password(self):
        f = today_facts()
        f["roles"]["cis_app"] = role("cis_app", connlimit=90)
        f["logins"]["cis_app"] = {"secret": "aa-cis/dev/rds-cis-app", "secret_user": "cis_app",
                                  "error": "login failed: 28P01 InvalidPasswordError: password authentication failed"}
        keys = p.state_keys(f)
        cells = {c.id: c for c in p.build_cells(f, keys)}
        self.assertEqual(cells["login.cis_app"].status(keys), "pending")   # S17: DSN written, set-password not yet
        self.assertTrue(cells["login.cis_app"].as_json(keys)["warn"])
        f["roles"]["cis_app"]["comment"] = f"{p.PASSWORD_MARKER} 2026-10-20T08:00:00Z by DB Migrate set-password"
        st, keys = statuses(f)
        self.assertTrue(keys["cis_app_password_set"])
        self.assertEqual(st["login.cis_app"], "FAIL")                      # marked, still refused: a real failure
        f["logins"]["cis_app"] = {"secret": "aa-cis/dev/rds-cis-app", "secret_user": "cis_app",
                                  "current_user": "cis_app",
                                  "cross": {"booking.customers": denied("b"), "tripplanner.sessions": denied("t")}}
        st, _ = statuses(f)
        self.assertEqual((st["login.cis_app"], st["cross.cis_app.booking.customers"]), ("pass", "pass"))

    def test_cis_runtime_switch(self):
        f = today_facts()
        f["cis_runtime"] = {"value_from": CIS_APP_ARN, "secret": "aa-cis/dev/rds-cis-app", "user": "cis_app"}
        f["roles"]["cis_app"] = role("cis_app", connlimit=90)
        f["logins"]["cis_runtime"] = {"secret": "aa-cis/dev/rds-cis-app", "current_user": "cis_app",
                                      "cross": {"booking.customers": denied("b"), "tripplanner.sessions": denied("t")}}
        f["ttv"] = {"reference": [48, 49], "runtime": 0}             # ENABLE-only table, no policy TO cis_app
        st, keys = statuses(f)
        self.assertTrue(keys["cis_runtime_on_cis_app"])
        self.assertEqual(st["cross.cis_runtime.booking.customers"], "pass")
        self.assertEqual(st["role.cis_runtime.membership"], "pass")
        self.assertEqual(st["tenant.cis_runtime_sees_all_ttv"], "FAIL")
        f["ttv"]["runtime"] = 49                                     # a row arrived between the counts
        st, _ = statuses(f)
        self.assertEqual(st["tenant.cis_runtime_sees_all_ttv"], "pass")

    def test_cross_tenant_rows_fail(self):
        f = today_facts()
        f["tenant_matrix"]["tables"]["gold_aa_internal.tenant_tour_versions"] = {
            "forged": {"visible": 3, "cross": 3}}
        st, _ = statuses(f)
        self.assertEqual(st["tenant.aa_app_user_isolation"], "FAIL")
        f = today_facts()
        f["tenant_matrix"]["tables"]["shared.x"] = {"unset": {"error": "57014 QueryCanceledError: timeout"}}
        st, _ = statuses(f)
        self.assertEqual(st["tenant.aa_app_user_isolation"], "FAIL")   # only 42501 (no access) is not an error

    def test_readable_cross_app_target_fails(self):
        f = today_facts()
        f["logins"]["booking"]["cross"]["shared.tenants"] = {"readable": True, "sqlstate": None}
        st, _ = statuses(f)
        self.assertEqual(st["cross.booking.shared.tenants"], "FAIL")

    def test_runtime_role_with_forbidden_membership_fails(self):
        f = today_facts()
        f["roles"]["tripplanner"]["chain"] = ["catalog_owner"]
        st, _ = statuses(f)
        self.assertEqual(st["role.tripplanner.membership"], "FAIL")

    def test_master_sessions_fail_after_s22(self):
        f = today_facts()
        f["catalog"]["login"] = "db_migrator"
        st, keys = statuses(f)
        self.assertTrue(keys["catalog_login_not_master"])
        self.assertEqual(st["sessions.master_break_glass_only"], "FAIL")
        f["sessions"]["master"] = {"sessions": []}
        st, _ = statuses(f)
        self.assertEqual(st["sessions.master_break_glass_only"], "pass")

    def test_rls_force_parity_keyed_on_244_and_the_cis_app_password(self):
        f = today_facts()
        st, _ = statuses(f)
        self.assertEqual(st["rls.force_parity.cis_app"], "pending")          # no 244, no cis_app login yet
        f["catalog"]["registered"] = ["rl-001", "244"]
        f["roles"]["cis_app"] = role("cis_app", connlimit=90,
                                     comment=f"{p.PASSWORD_MARKER} 2026-10-20T08:00:00Z by DB Migrate set-password")
        f["logins"]["cis_app"] = {"secret": "aa-cis/dev/rds-cis-app", "secret_user": "cis_app",
                                  "current_user": "cis_app",
                                  "cross": {"booking.customers": denied("b"), "tripplanner.sessions": denied("t")}}
        f["force_parity"] = {"reference": {t: [10, 11] for t in p.RLS_PARITY_TABLES},
                             "cis_app": {t: {"plain": 10, "forged": 11} for t in p.RLS_PARITY_TABLES}}
        st, keys = statuses(f)
        self.assertTrue(keys["244"] and keys["cis_app_secret_ready"] and keys["cis_app_password_set"])
        self.assertEqual(st["rls.force_parity.cis_app"], "pass")             # a concurrent insert between refs
        # The X1 plan's original premise: FORCE RLS filters cis_app without a GUC (no parity policy).
        f["force_parity"]["cis_app"]["silver_aa_internal.raw_tours"] = {"plain": 0, "forged": 0}
        st, keys = statuses(f)
        self.assertEqual(st["rls.force_parity.cis_app"], "FAIL")
        cells = {c.id: c for c in p.build_cells(f, keys)}
        self.assertIn("silver_aa_internal.raw_tours", cells["rls.force_parity.cis_app"].detail["mismatch"][0])
        f["force_parity"]["cis_app"]["silver_aa_internal.raw_tours"] = {"error": "42501 InsufficientPrivilegeError"}
        st, _ = statuses(f)
        self.assertEqual(st["rls.force_parity.cis_app"], "FAIL")
        f["force_parity"] = {"error": "reference count: 57014 QueryCanceledError"}
        st, _ = statuses(f)
        self.assertEqual(st["rls.force_parity.cis_app"], "FAIL")

    def test_parity_tables_are_the_force_tables_and_ttv(self):
        self.assertIn(p.TTV, p.RLS_PARITY_TABLES)
        self.assertEqual(len(p.RLS_PARITY_TABLES), 9)

    def test_enable_only_allowlist(self):
        f = today_facts()
        f["catalog"]["registered"] = ["244"]
        st, _ = statuses(f)
        self.assertEqual(st["rls.enable_only_has_cis_app_policy"], "FAIL")
        with mock.patch.object(p, "RLS_ENABLE_ONLY_ALLOWLIST", frozenset({"gold_aa_internal.tenant_tour_versions"})):
            st, _ = statuses(f)
        self.assertEqual(st["rls.enable_only_has_cis_app_policy"], "pass")

    def test_summary_exit(self):
        f = today_facts()
        keys = p.state_keys(f)
        self.assertEqual(p.summarize(p.build_cells(f, keys), keys)["exit"], 0)
        f["logins"]["booking"]["cross"]["shared.tenants"] = {"readable": True, "sqlstate": None}
        self.assertEqual(p.summarize(p.build_cells(f, keys), keys)["exit"], 1)


def crm_live_facts():
    """today_facts() after the AA-932 train: rl-003, rl-004, CIS 269, crm-001 applied and crm_app's password set;
    plus crm-006 (AA-937) with no reader grant on the F1 vault."""
    f = today_facts()
    f["catalog"]["registered"] = ["rl-003", "rl-004", "269", "crm-001", "crm-006"]
    f["crm_readers"] = {"checked": sorted(p.CRM_F1_TABLES), "f1": [], "base": []}
    f["catalog"]["anchor_owner"]["crm"] = "crm_owner"
    marker = f"{p.PASSWORD_MARKER} 2026-10-23T08:00:00Z by DB Migrate set-password"
    f["roles"]["crm_app"] = role("crm_app", connlimit=6, inherit=False, comment=marker,
                                 chain=list(p.CRM_NOLOGIN_ROLES))
    f["roles"]["crm_owner"] = owner_role("crm_owner")
    for r in p.CRM_NOLOGIN_ROLES:
        f["roles"][r] = {**owner_role(r), "owned": [], "chain": [], "members": ["crm_app"]}
    f["owner_grants"]["crm_owner"] = {"usage_shared": True, "select_registry": True, "insert_registry": True}
    f["ownership"]["crm"] = {"offenders": []}
    f["runtime_grants"]["crm"] = {"crm_app": {"missing": []}}
    crm_defacl = {"r": ["DELETE", "INSERT", "SELECT", "UPDATE"], "S": ["SELECT", "USAGE"]}
    f["default_acl"]["crm"] = {"crm_app": {"rows": defacl("crm", "crm_owner", crm_defacl)}}
    f["logins"]["crm_app"] = {"secret": "crm/dev/database-url", "secret_user": "crm_app", "current_user": "crm_app",
                              "cross": {t: denied(t) for t in ("booking.customers", "tripplanner.sessions",
                                                               "shared.tenants")}}
    for r in ("booking", "tripplanner", "aa_app_user", "cis_runtime"):
        f["logins"][r].setdefault("cross", {})["crm.job"] = denied("crm")
    return f


class CrmOwnerCellsTest(unittest.TestCase):
    """AA-932: the partner CRM owner's cells (rl-003 / rl-004 / CIS 269 / crm-001, crm_app set-password)."""

    def test_before_the_train_every_crm_cell_waits(self):
        st, keys = statuses(today_facts())
        self.assertFalse(keys["crm_transferred"])
        for cid in ("role.crm_app.attributes", "role.crm_app.noinherit", "owner_role.crm_owner",
                    "nologin.crm_ai_reader", "registry.crm_owner", "cross.booking.crm.job",
                    "cross.crm_app.booking.customers", "default_acl.crm"):
            self.assertIn(st[cid], ("pending", "ready"), cid)

    def test_after_the_train_every_crm_cell_passes(self):
        st, keys = statuses(crm_live_facts())
        # cis_app / CIS runtime -> crm.job also wait for their own X1 keys, which today_facts() leaves false.
        crm = {k: v for k, v in st.items() if "crm" in k and not k.startswith(("cross.cis_app.", "cross.cis_runtime."))}
        self.assertTrue(keys["crm_transferred"] and keys["crm_app_password_set"])
        self.assertEqual({k: v for k, v in crm.items() if v != "pass"}, {})
        for cid in ("role.crm_app.noinherit", "nologin.crm_eraser", "registry.crm_owner", "login.crm_app",
                    "cross.crm_app.shared.tenants", "cross.aa_app_user.crm.job", "runtime_grants.crm",
                    "default_acl.crm", "ownership.crm"):
            self.assertEqual(st[cid], "pass", cid)

    def test_readers_reaching_trip_traveler_or_a_base_table_fail(self):
        # AA-937 (design v3 §4.3 Fix A1): one grant on crm.trip_traveler, or a base table for the AI reader, fails.
        f = crm_live_facts()
        f["crm_readers"]["f1"] = [{"role": "crm_support_reader", "rel": "crm.trip_traveler"}]
        f["crm_readers"]["base"] = [{"role": "crm_ai_reader", "rel": "crm.traveler_profile"}]
        st, _ = statuses(f)
        self.assertEqual(st["vault.crm_support_reader"], "FAIL")
        self.assertEqual(st["views_only.crm_ai_reader"], "FAIL")
        self.assertEqual(st["vault.crm_ai_reader"], "pass")
        self.assertEqual(st["views_only.crm_insights"], "pass")

    def test_vault_cells_wait_for_crm006_and_trip_traveler(self):
        st, _ = statuses(today_facts())                    # nothing collected, crm-006 not registered
        self.assertEqual(st["vault.crm_eraser"], "pending")
        f = crm_live_facts()
        f["crm_readers"]["checked"] = ["crm.member", "crm.traveler"]   # crm-005 not applied: no trip_traveler yet
        st, _ = statuses(f)
        self.assertEqual(st["vault.crm_ai_reader"], "FAIL")
        f["catalog"]["registered"].remove("crm-006")
        st, _ = statuses(f)
        self.assertEqual(st["vault.crm_ai_reader"], "pending")
        f["crm_readers"] = {"error": "42501 InsufficientPrivilegeError: x"}
        st, _ = statuses(f)
        self.assertEqual(st["views_only.crm_insights"], "pending")

    def test_crm_app_inheriting_its_readers_fails(self):
        f = crm_live_facts()
        f["roles"]["crm_app"]["inherit"] = True
        st, _ = statuses(f)
        self.assertEqual(st["role.crm_app.noinherit"], "FAIL")

    def test_reader_granted_to_another_role_fails(self):
        f = crm_live_facts()
        f["roles"]["crm_support_reader"]["members"] = ["cis_app", "crm_app"]
        st, _ = statuses(f)
        self.assertEqual(st["nologin.crm_support_reader"], "FAIL")
        f = crm_live_facts()
        f["roles"]["crm_ai_reader"]["members"] = ["aa_cis_admin", "crm_app"]     # PostgreSQL 16+ ADMIN row
        st, _ = statuses(f)
        self.assertEqual(st["nologin.crm_ai_reader"], "pass")

    def test_aa_app_reading_crm_fails(self):
        f = crm_live_facts()
        f["logins"]["booking"]["cross"]["crm.job"] = {"readable": True, "sqlstate": None}
        st, _ = statuses(f)
        self.assertEqual(st["cross.booking.crm.job"], "FAIL")

    def test_crm_app_login_waits_for_its_own_set_password(self):
        f = crm_live_facts()
        f["roles"]["crm_app"]["comment"] = None
        f["logins"]["crm_app"] = {"secret": "crm/dev/database-url", "secret_user": "crm_app",
                                  "error": "login failed: 28P01 InvalidPasswordError: password authentication failed"}
        keys = p.state_keys(f)
        cells = {c.id: c for c in p.build_cells(f, keys)}
        self.assertEqual(cells["login.crm_app"].status(keys), "pending")
        self.assertTrue(cells["login.crm_app"].as_json(keys)["warn"])
        self.assertEqual(cells["cross.crm_app.booking.customers"].status(keys), "pending")

    def test_crm_app_needs_no_schema_wide_execute(self):
        rp = p.OWNERS["crm"].runtime_privileges[0]
        self.assertEqual(dict(rp.objects)["function"], ())
        self.assertNotIn("functions", dict(rp.default_acl))


class _Savepoint:
    """conn.transaction() of _savepoint: set_config(…, true) is undone when the savepoint rolls back."""

    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        self.saved = self.conn.guc

    async def __aexit__(self, *exc):
        self.conn.guc = self.saved
        return False


class PoolConn:
    """aa_app_user's session over fixture rows. `policies` = {table: (row, GUC tenant or None, conn) -> visible}, the
    row filter its RLS policies apply; fetchrow evaluates the matrix count as matrix_count_sql words it (the parent of a
    PARENT_SCOPED row is looked up among the rows the session can see)."""

    def __init__(self, tables, rows, policies):
        self.cols = {t["fq"]: t["tenant_col"] for t in tables}
        self.rows, self.policies, self.guc, self.sql = rows, policies, None, []

    def transaction(self):
        return _Savepoint(self)

    async def execute(self, sql, guc):
        self.guc = guc

    def visible(self, fq):
        return [r for r in self.rows[fq] if self.policies[fq](r, self.guc or None, self)]

    async def fetchrow(self, sql, me, allowed):
        self.sql.append((sql, me, list(allowed)))
        fq = next(fq for fq in self.rows if '"{}"."{}"'.format(*fq.split(".")) in sql.split(" FROM ")[-1])
        vis = self.visible(fq)
        if fq in p.PARENT_SCOPED:
            key, parent, pkey = p.PARENT_SCOPED[fq]
            parents = self.visible(parent)

            def ok(r):
                return any(pr[pkey] == r[key] and (pr["tenant_id"] == me or pr["tenant_id"].lower() in allowed)
                           for pr in parents)
        else:
            col = self.cols[fq]

            def ok(r):
                return r[col] is None or r[col] == me or r[col].lower() in allowed
        return {"visible": len(vis), "cross": sum(not ok(r) for r in vis)}

    async def fetchval(self, sql):
        """The plain count tenant_matrix runs for a table without a tenant scope."""
        return len(self.visible(next(fq for fq in self.rows if sql.endswith('"{}"."{}"'.format(*fq.split("."))))))


WAVE4_TABLES = [{"fq": fq, "q": '"{}"."{}"'.format(*fq.split(".")), "forced": False, "tenant_col": col}
                for fq, col in ((ATOMS, "owner_scope"), (TTP, "tenant_id"), (QP, "tenant_id"), (QPV, None))]
WAVE4_ROWS = {
    TTP: [{"tenant_id": p.MASTER_TENANT}, {"tenant_id": T1}, {"tenant_id": T2}],
    ATOMS: [{"owner_scope": "platform"}, {"owner_scope": "platform"}, {"owner_scope": T1}, {"owner_scope": T2}],
    QP: [{"plan_id": "p1", "tenant_id": T1}, {"plan_id": "p2", "tenant_id": T2}],
    QPV: [{"plan_id": "p1"}, {"plan_id": "p2"}, {"plan_id": "p2"}],
}
# CIS 265 / 266 as live (db-schema-reference.md after 268): the row filters and the pool policies' USING text.
WAVE4_POLICIES = {
    TTP: lambda r, g, c: r["tenant_id"] in (g, p.MASTER_TENANT),
    ATOMS: lambda r, g, c: r["owner_scope"] in ("platform", g),
    QP: lambda r, g, c: r["tenant_id"] == g,
    QPV: lambda r, g, c: any(qp["plan_id"] == r["plan_id"] for qp in c.visible(QP)),
}
WAVE4_QUALS = [
    {"fq": TTP, "qual": f"(tenant_id = '{p.MASTER_TENANT}'::text)"},
    {"fq": TTP, "qual": TTP_OWN},
    {"fq": ATOMS, "qual": "(owner_scope = 'platform'::text)"},
    {"fq": ATOMS, "qual": f"(owner_scope = {GUC})"},
    {"fq": QP, "qual": f"(tenant_id = ({GUC})::uuid)"},
    {"fq": QPV, "qual": f"(EXISTS ( SELECT 1 FROM acp_shared.quarter_plan qp WHERE ((qp.plan_id = "
                        f"quarter_plan_version.plan_id) AND (qp.tenant_id = ({GUC})::uuid))))"},
]


class TenantMatrixWave4Test(unittest.TestCase):
    """AA-859 wave 4: tour_atoms by owner_scope, quarter_plan_version through its plan, tenant_tour_pages' text tenant_id
    with a '::text' master constant. Pure (PoolConn); the SQL itself ran against a throwaway PostgreSQL with the 265 /
    266 policies (implementation notes AA-859)."""

    def run_matrix(self, policies=None, quals=None, rows=None):
        f = today_facts()
        f["tenant_matrix"] = {}
        f["_rls_tables"] = WAVE4_TABLES
        f["_allowed_constants"] = p.allowed_tenant_constants(WAVE4_QUALS if quals is None else quals)
        conn = PoolConn(WAVE4_TABLES, copy.deepcopy(rows or WAVE4_ROWS), {**WAVE4_POLICIES, **(policies or {})})
        asyncio.run(p.tenant_matrix(conn, f, [p.MASTER_TENANT, T1, T2]))
        st, keys = statuses(f)
        cell = {c.id: c for c in p.build_cells(f, keys)}["tenant.aa_app_user_isolation"]
        return st["tenant.aa_app_user_isolation"], f["tenant_matrix"]["tables"], cell

    def test_live_policies_pass(self):
        st, m, _ = self.run_matrix()
        self.assertEqual(st, "pass")
        self.assertEqual(set(m), {ATOMS, TTP, QP, QPV})
        self.assertEqual(m[ATOMS]["unset"], {"visible": 2, "cross": 0})           # platform atoms only
        self.assertEqual(m[ATOMS]["forged"], {"visible": 2, "cross": 0})
        self.assertEqual(m[ATOMS]["tenant:t1"], {"visible": 3, "cross": 0})       # + its own atom
        self.assertEqual(m[TTP]["tenant:t1"], {"visible": 2, "cross": 0})         # own + the master's page
        self.assertEqual(m[TTP]["forged"], {"visible": 1, "cross": 0})
        self.assertEqual(m[QPV]["tenant:t2"], {"visible": 2, "cross": 0})         # judged by tenant (not None)
        self.assertEqual(m[QPV]["unset"], {"visible": 0, "cross": 0})

    def test_text_cast_master_constant_was_a_false_positive(self):
        # The pre-fix regex (tenant_id = '<uuid>'::uuid only) misses 265's '::text' literal: the master's public trip
        # page, visible to every tenant by design, counted as a cross-tenant read.
        old = re.compile(r"tenant_id\s*=\s*'([0-9a-fA-F-]{36})'::uuid")
        with mock.patch.object(p, "SCOPE_CONST_RE", old):
            st, m, cell = self.run_matrix()
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[TTP]["forged"], {"visible": 1, "cross": 1})
        self.assertTrue(any(s.startswith(TTP) for s in cell.detail["cross_tenant"]))
        st, m, _ = self.run_matrix()                                               # the fix
        self.assertEqual((st, m[TTP]["forged"]), ("pass", {"visible": 1, "cross": 0}))

    def test_policy_sharing_another_tenants_rows_is_caught(self):
        # A '::text' constant that is not the master (here t2's id) shares nothing: t2's rows read by t1 stay cross.
        quals = WAVE4_QUALS + [{"fq": TTP, "qual": f"(tenant_id = '{T2}'::text)"}]
        st, m, _ = self.run_matrix(policies={TTP: lambda r, g, c: r["tenant_id"] in (g, p.MASTER_TENANT, T2)},
                                   quals=quals)
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[TTP]["tenant:t1"], {"visible": 3, "cross": 1})

    def test_tenant_atom_leak_is_caught(self):
        st, m, _ = self.run_matrix(policies={ATOMS: lambda r, g, c: True})       # tenant_isolation USING (true)
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[ATOMS]["tenant:t1"], {"visible": 4, "cross": 1})       # t2's atom
        self.assertEqual(m[ATOMS]["unset"], {"visible": 4, "cross": 2})

    def test_platform_atoms_only_where_the_policy_says(self):
        # Without atoms_platform_read, 'platform' is not a shared constant: platform atoms reached through another
        # policy count as foreign.
        quals = [q for q in WAVE4_QUALS if "'platform'" not in q["qual"]]
        st, m, _ = self.run_matrix(quals=quals)
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[ATOMS]["unset"], {"visible": 2, "cross": 2})

    def test_quarter_plan_version_leak_is_caught(self):
        st, m, _ = self.run_matrix(policies={QPV: lambda r, g, c: True})         # USING (true) on the versions
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[QPV]["tenant:t1"], {"visible": 3, "cross": 2})         # t2's plan is invisible to t1
        self.assertEqual(m[QPV]["forged"], {"visible": 3, "cross": 3})

    def test_quarter_plan_leak_through_the_parent_is_caught(self):
        st, m, _ = self.run_matrix(policies={QP: lambda r, g, c: True})          # the plans leak, versions follow
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[QP]["tenant:t1"], {"visible": 2, "cross": 1})
        self.assertEqual(m[QPV]["tenant:t1"], {"visible": 3, "cross": 2})         # p2's tenant is t2, not t1

    def test_shared_constants_reach_the_query(self):
        f = today_facts()
        f["tenant_matrix"] = {}
        f["_rls_tables"] = WAVE4_TABLES
        f["_allowed_constants"] = p.allowed_tenant_constants(WAVE4_QUALS)
        conn = PoolConn(WAVE4_TABLES, copy.deepcopy(WAVE4_ROWS), WAVE4_POLICIES)
        asyncio.run(p.tenant_matrix(conn, f, [T1]))
        by_table = {}
        for sql, me, allowed in conn.sql:
            by_table.setdefault(sql.split(" FROM ")[-1].split()[0], set()).add(tuple(allowed))
        self.assertEqual(by_table['"acp_deliver"."tenant_tour_pages"'], {(p.MASTER_TENANT,)})
        self.assertEqual(by_table['"acp_contract"."tour_atoms"'], {("platform",)})
        self.assertEqual(by_table['"acp_shared"."quarter_plan_version"'], {()})


AG_TABLES = [{"fq": fq, "q": '"{}"."{}"'.format(*fq.split(".")), "forced": False, "tenant_col": col}
             for fq, col in ((AGR, "tenant_id"), (AGO, None))]
AG_ROWS = {
    AGR: [{"request_id": "r1", "tenant_id": T1}, {"request_id": "r2", "tenant_id": T2}],
    AGO: [{"request_id": "r1"}, {"request_id": "r1"}, {"request_id": "r2"}, {"request_id": "r2"}, {"request_id": "r2"}],
}
# CIS 241 as live (db-schema-reference.md after 268): tenant_isolation on the request, and on the option through it.
AG_POLICIES = {
    AGR: lambda r, g, c: r["tenant_id"] == g,
    AGO: lambda r, g, c: any(rq["request_id"] == r["request_id"] for rq in c.visible(AGR)),
}
AG_QUALS = [
    {"fq": AGR, "qual": f"(tenant_id = ({GUC})::uuid)"},
    {"fq": AGO, "qual": f"(EXISTS ( SELECT 1 FROM acp_shared.angle_gate_request r WHERE ((r.request_id = "
                        f"angle_gate_option.request_id) AND (r.tenant_id = ({GUC})::uuid))))"},
]
# A pool policy that admits any real tenant (wrong table in the tenant check): nothing under unset / '' / forged, so
# only the per-tenant modes can catch it.
ANY_REAL_TENANT = (p.MASTER_TENANT, T1, T2)


class TenantMatrixAngleGateTest(unittest.TestCase):
    """AA-859 (S247 follow-up): acp_shared.angle_gate_option is judged through its angle_gate_request under each real
    tenant. Before, it had no tenant column and no PARENT_SCOPED entry: its per-tenant cross was None (never judged)."""

    def run_matrix(self, policies=None):
        f = today_facts()
        f["tenant_matrix"] = {}
        f["_rls_tables"] = AG_TABLES
        f["_allowed_constants"] = p.allowed_tenant_constants(AG_QUALS)
        conn = PoolConn(AG_TABLES, copy.deepcopy(AG_ROWS), {**AG_POLICIES, **(policies or {})})
        asyncio.run(p.tenant_matrix(conn, f, [p.MASTER_TENANT, T1, T2]))
        st, keys = statuses(f)
        cell = {c.id: c for c in p.build_cells(f, keys)}["tenant.aa_app_user_isolation"]
        return st["tenant.aa_app_user_isolation"], f["tenant_matrix"]["tables"], cell

    def test_live_policies_pass_and_are_judged_per_tenant(self):
        st, m, cell = self.run_matrix()
        self.assertEqual(st, "pass")
        self.assertEqual(m[AGO]["tenant:t1"], {"visible": 2, "cross": 0})         # judged (not None)
        self.assertEqual(m[AGO]["tenant:t2"], {"visible": 3, "cross": 0})
        self.assertEqual(m[AGO]["tenant:master"], {"visible": 0, "cross": 0})
        self.assertEqual(m[AGO]["unset"], {"visible": 0, "cross": 0})
        self.assertEqual(cell.detail["errors"], [])

    def test_option_leak_is_caught(self):
        st, m, _ = self.run_matrix(policies={AGO: lambda r, g, c: True})         # tenant_isolation USING (true)
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[AGO]["tenant:t1"], {"visible": 5, "cross": 3})         # r2 belongs to t2
        self.assertEqual(m[AGO]["forged"], {"visible": 5, "cross": 5})

    def test_leak_only_under_real_tenants_is_caught(self):
        leak = {AGO: lambda r, g, c: g in ANY_REAL_TENANT}
        st, m, cell = self.run_matrix(policies=leak)
        self.assertEqual(st, "FAIL")
        self.assertEqual(m[AGO]["forged"], {"visible": 0, "cross": 0})            # invisible without a real tenant
        self.assertEqual(m[AGO]["tenant:t1"], {"visible": 5, "cross": 3})
        self.assertEqual(m[AGO]["tenant:master"], {"visible": 5, "cross": 5})
        self.assertTrue(any(s.startswith(f"{AGO} [tenant:t1]") for s in cell.detail["cross_tenant"]))

    def test_unregistered_table_is_an_error_not_a_silent_pass(self):
        # The pre-fix PARENT_SCOPED (quarter_plan_version only): the same per-tenant leak used to pass, its cross None.
        old = {QPV: p.PARENT_SCOPED[QPV]}
        with mock.patch.object(p, "PARENT_SCOPED", old):
            st, m, cell = self.run_matrix(policies={AGO: lambda r, g, c: g in ANY_REAL_TENANT})
            self.assertEqual(m[AGO]["tenant:t1"], {"visible": 5, "cross": None})
            self.assertEqual(st, "FAIL")
            self.assertIn(p.UNJUDGED, cell.error)
            # The live policies too: rows visible under a real tenant that nothing judges fail the cell.
            st, m, cell = self.run_matrix()
            self.assertEqual(st, "FAIL")
            self.assertIn(f"{AGO} [tenant:t1] {p.UNJUDGED} (2 visible rows)", cell.detail["errors"])


class MainTest(unittest.TestCase):
    def run_main(self, collect):
        out = io.StringIO()
        with mock.patch.object(p, "collect", collect), redirect_stdout(out):
            code = asyncio.run(p.main(["-c", "url", json.dumps({"cis_runtime_secret": API_ARN})]))
        recs = [line.split(" ", 2) for line in out.getvalue().splitlines()]
        self.assertTrue(all(r[0] == "PROBE" for r in recs))
        return code, [(r[1], json.loads(r[2])) for r in recs], out.getvalue()

    def test_records(self):
        async def fake(cfg, facts):
            facts.update(copy.deepcopy(today_facts()))
            return 0
        code, recs, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        kinds = [k for k, _ in recs]
        self.assertEqual(kinds[0], "header")
        self.assertEqual(kinds[-1], "summary")
        self.assertIn("matrix", kinds)
        header = recs[0][1]
        self.assertEqual(header["catalog_login"], "aa_cis_admin")
        self.assertIn(p.NOTES[0], header["notes"])
        cells = [b for k, b in recs if k == "cell"]
        self.assertTrue(all(set(c) >= {"id", "status", "expected", "when", "detail"} for c in cells))
        for k, b in recs:      # each record stays far below the 16 KB log line split
            self.assertLess(len(json.dumps(b)), 8000, (k, b.get("id")))

    def test_fatal_exit_2_without_secrets(self):
        async def boom(cfg, facts):
            raise ValueError("invalid DSN postgresql://aa_cis_admin:dummy@host/db")
        code, recs, raw = self.run_main(boom)
        self.assertEqual(code, 2)
        self.assertEqual([k for k, _ in recs], ["header", "fatal", "summary"])
        self.assertNotIn("dummy", raw)
        self.assertNotIn("postgresql://", raw)


class WorkflowTest(unittest.TestCase):
    def test_schedule_and_concurrency(self):
        self.assertIn('cron: "13 4 * * *"', WORKFLOW)                 # 30 min after the dump (03:43)
        self.assertRegex(WORKFLOW, r"concurrency:\n  group: db-isolation-probe\n  cancel-in-progress: false")
        self.assertIn("if: github.ref == 'refs/heads/main'", WORKFLOW)

    def test_config_is_an_argument_not_new_env(self):
        overrides = WORKFLOW[WORKFLOW.index("OVERRIDES=$("):WORKFLOW.index("TASK_ARN=$(aws ecs run-task")]
        self.assertNotIn("environment:", overrides)                   # no new env var reaches the task
        self.assertIn("sys.argv[1]", overrides)
        self.assertIn("db/isolation_probe.py", WORKFLOW)

    def test_db_migrate_dispatches_the_probe_after_apply(self):
        # X1 S12: also after set-password (the cis_app login cells follow its marker) and run-script.
        step = MIGRATE_WORKFLOW[MIGRATE_WORKFLOW.index("name: Re-run the isolation probe"):]
        self.assertIn("if: success() && inputs.mode != 'check'", step.split("run:")[0])
        self.assertIn("continue-on-error: true", step.split("run:")[0])
        self.assertIn("db-isolation-probe.yml", step)
        self.assertTrue(re.search(r"actions: write", MIGRATE_WORKFLOW))


if __name__ == "__main__":
    unittest.main()
