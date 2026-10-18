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
        "consumer": {"grants": [{"grantee": g, "object": o, "privileges": list(pr), "missing": []}
                                for g, pr, o in p.CONSUMER_GRANTS]},
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
