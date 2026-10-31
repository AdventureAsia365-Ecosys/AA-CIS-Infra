"""AA-1002 (S261): db/scripts/aa1002_dev_anthropic_road.py against a real PostgreSQL (the SQL itself).

Skipped unless AA1002_TEST_PG_DSN names a throw-away server's superuser DSN (and asyncpg is importable): the CI job of
db/tests has neither, so this file runs locally only. It creates the database `aa1002_road_test` (dropped first), the
five tables the script reads with the column names, owner and CHECKs of docs/architecture/db-schema-reference.md
(Verified 2026-10-31, CIS 317), the roles `cis_owner` (NOLOGIN, owner) and `cis_app`, and a NON-superuser login that is a
member of cis_owner (the RDS master's relation to it, roles/002), seeds invented rows and runs the script as that login.

  AA1002_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55492/postgres python3 -m unittest db.tests.test_aa1002_dev_anthropic_road_pg
"""
import asyncio
import contextlib
import importlib.util
import io
import os
import unittest
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parent.parent.parent
DSN = os.environ.get("AA1002_TEST_PG_DSN", "")
try:
    import asyncpg
except ImportError:  # CI image of db/tests: standard library + pyyaml only
    asyncpg = None

_spec = importlib.util.spec_from_file_location("aa1002_dev_anthropic_road",
                                               ROOT / "db/scripts/aa1002_dev_anthropic_road.py")
script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(script)

DB = "aa1002_road_test"
LOGIN = "aa1002_master_login"

SCHEMA = """
CREATE SCHEMA shared AUTHORIZATION cis_owner;
SET ROLE cis_owner;
CREATE TABLE shared.llm_provider_connection (
    connection_key text PRIMARY KEY, kind text NOT NULL, auth_mode text NOT NULL, label text NOT NULL,
    account_id text, account_id_env text, region text, role_name text, external_id text,
    secret_name text CHECK (secret_name IS NULL OR secret_name ~ '^aa-llm/[a-z0-9-]+/[a-z0-9][a-z0-9-]*$'),
    credential_env text, base_url text,
    data_scope text NOT NULL CHECK (data_scope IN ('aws_only', 'vendor_direct')),
    timeout_s integer, max_retries integer, max_concurrency integer, rpm_limit integer,
    monthly_budget_usd numeric(10,2) CHECK (monthly_budget_usd IS NULL OR monthly_budget_usd >= 0),
    enabled boolean NOT NULL, notes text, created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by text NOT NULL);
CREATE TABLE shared.llm_connection_cost_policy (
    connection_key text PRIMARY KEY REFERENCES shared.llm_provider_connection ON DELETE CASCADE,
    alert_pct smallint NOT NULL, hard_stop boolean NOT NULL, usage_secret_name text, usage_scope_id text, notes text,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL);
CREATE TABLE shared.llm_model_catalog (
    model_key text PRIMARY KEY, label text NOT NULL, vendor text NOT NULL, provider text NOT NULL,
    api_style text NOT NULL, bedrock_profile_ids jsonb NOT NULL, wire_model text,
    callable_via text[] NOT NULL DEFAULT '{}', supports_temperature boolean NOT NULL DEFAULT true,
    enabled boolean NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(), updated_by text NOT NULL DEFAULT 'test',
    capabilities jsonb NOT NULL DEFAULT '{}');
CREATE TABLE shared.llm_model_deployment (
    model_key text NOT NULL REFERENCES shared.llm_model_catalog ON DELETE CASCADE,
    connection_key text NOT NULL REFERENCES shared.llm_provider_connection,
    wire_id text NOT NULL, priority smallint NOT NULL CHECK (priority >= 0 AND priority <= 1000),
    enabled boolean NOT NULL, batch_capable boolean NOT NULL DEFAULT false,
    request_defaults jsonb NOT NULL DEFAULT '{}',
    origin text NOT NULL CHECK (origin IN ('legacy_constant', 'bedrock_profile', 'openai_wire', 'seed', 'admin')),
    notes text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL, PRIMARY KEY (model_key, connection_key));
CREATE TABLE shared.llm_role_config (
    stage text PRIMARY KEY, role text NOT NULL, provider text NOT NULL, model_id text NOT NULL, account_route text,
    is_active boolean NOT NULL DEFAULT true, updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL DEFAULT 'test', fallback_model_ids text[] NOT NULL DEFAULT '{}', shadow_model_id text,
    shadow_sample_pct integer NOT NULL DEFAULT 0,
    allowed_scopes text[] DEFAULT ARRAY['aws_only']::text[] CHECK (allowed_scopes IS NULL OR (
        cardinality(allowed_scopes) >= 1 AND allowed_scopes <@ ARRAY['aws_only', 'vendor_direct']::text[])));
GRANT USAGE ON SCHEMA shared TO cis_app;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO cis_app;
RESET ROLE;
"""

SEED = """
INSERT INTO shared.llm_provider_connection (connection_key, kind, auth_mode, label, secret_name, data_scope, enabled,
    updated_by) VALUES
  ('acc3', 'bedrock', 'assume_role', 'Bedrock A', NULL, 'aws_only', true, 'seed'),
  ('openai-direct', 'openai', 'api_key', 'OpenAI API', NULL, 'vendor_direct', true, 'seed'),
  ('anthropic-direct', 'anthropic', 'api_key', 'Anthropic API', 'aa-llm/dev/anthropic-direct', 'vendor_direct', false,
   'seed');
INSERT INTO shared.llm_model_catalog (model_key, label, vendor, provider, api_style, bedrock_profile_ids, enabled) VALUES
  ('anth-alpha', 'A', 'anthropic', 'bedrock', 'converse', '{"acc3": "global.anthropic.claude-alpha-9"}', true),
  ('anth-beta', 'B', 'anthropic', 'bedrock', 'converse', '{"acc3": "us.anthropic.claude-beta-2-v1:0"}', true),
  ('haiku', 'H', 'anthropic', 'bedrock', 'anthropic_native', '{"acc3": "us.anthropic.claude-legacy-h-v1:0"}', true),
  ('oai-gamma-direct', 'G', 'openai', 'openai', 'openai_chat', '{}', true);
INSERT INTO shared.llm_model_deployment (model_key, connection_key, wire_id, priority, enabled, origin, updated_by) VALUES
  ('anth-alpha', 'acc3', 'global.anthropic.claude-alpha-9', 10, true, 'bedrock_profile', 'seed'),
  ('anth-alpha', 'anthropic-direct', 'claude-alpha-9', 100, true, 'seed', 'seed'),
  ('anth-beta', 'acc3', 'us.anthropic.claude-beta-2-v1:0', 10, true, 'bedrock_profile', 'seed'),
  ('haiku', 'acc3', 'us.anthropic.claude-legacy-h-v1:0', 10, true, 'legacy_constant', 'seed'),
  ('oai-gamma-direct', 'openai-direct', 'gamma', 10, true, 'openai_wire', 'seed');
INSERT INTO shared.llm_role_config (stage, role, provider, model_id, fallback_model_ids, shadow_model_id,
    allowed_scopes) VALUES
  ('w1_writer', 'writer', 'claude', 'anth-alpha', '{oai-gamma-direct}', NULL, '{aws_only}'),
  ('w2_writer_new', 'writer', 'claude', 'anth-beta', '{haiku}', NULL, '{aws_only}'),
  ('x1_legacy_only', 'writer', 'claude', 'haiku', '{}', NULL, '{aws_only}'),
  ('t3_tenant_writer', 'writer', 'claude', 'haiku', '{anth-alpha}', NULL, '{aws_only}'),
  ('tp_planner', 'writer', 'claude', 'anth-alpha', '{}', NULL, '{aws_only}');
"""


def _dsn(db: str, user: str = None) -> str:
    parts = urlsplit(DSN)
    netloc = parts.netloc
    if user:
        host = netloc.split("@", 1)[-1]
        netloc = f"{user}@{host}"
    return urlunsplit((parts.scheme, netloc, f"/{db}", parts.query, parts.fragment))


@unittest.skipUnless(DSN and asyncpg is not None, "AA1002_TEST_PG_DSN not set or asyncpg missing (local only)")
class RealPostgresTest(unittest.TestCase):
    def setUp(self):
        async def setup():
            admin = await asyncpg.connect(DSN)
            try:
                await admin.execute(f"DROP DATABASE IF EXISTS {DB}")
                for role in (LOGIN, "cis_app", "cis_owner"):
                    await admin.execute(f"DROP ROLE IF EXISTS {role}")
                await admin.execute("CREATE ROLE cis_owner NOLOGIN")
                await admin.execute("CREATE ROLE cis_app NOLOGIN")
                await admin.execute(f"CREATE ROLE {LOGIN} LOGIN NOSUPERUSER IN ROLE cis_owner")
                await admin.execute(f"CREATE DATABASE {DB}")
            finally:
                await admin.close()
            db = await asyncpg.connect(_dsn(DB))
            try:
                await db.execute(SCHEMA)
                await db.execute("SET ROLE cis_owner")
                await db.execute(SEED)
            finally:
                await db.close()

        asyncio.run(setup())

    def _run(self, mode):
        async def go():
            conn = await asyncpg.connect(_dsn(DB, LOGIN))
            try:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    code = await script.run(conn, mode)
                return code, buf.getvalue()
            finally:
                await conn.close()

        return asyncio.run(go())

    def _fetch(self, sql):
        async def go():
            conn = await asyncpg.connect(_dsn(DB))
            try:
                return [dict(r) for r in await conn.fetch(sql)]
            finally:
                await conn.close()

        return asyncio.run(go())

    def scopes(self):
        return {r["stage"]: list(r["allowed_scopes"])
                for r in self._fetch("SELECT stage, allowed_scopes FROM shared.llm_role_config")}

    def test_dry_run_changes_nothing(self):
        before = self.scopes()
        code, text = self._run("dry_run")
        self.assertEqual(code, 0, text)
        self.assertIn("SCRIPT rolled_back", text)
        self.assertIn("SCRIPT widen group=tenant stage=t3_tenant_writer", text)
        self.assertEqual(self.scopes(), before)
        self.assertEqual(self._fetch("SELECT count(*) AS n FROM shared.llm_model_deployment"
                                     " WHERE connection_key = 'anthropic-direct'")[0]["n"], 1)

    def test_apply_then_idempotent(self):
        code, text = self._run("apply")
        self.assertEqual(code, 0, text)
        both = ["aws_only", "vendor_direct"]
        self.assertEqual(self.scopes(), {"w1_writer": both, "w2_writer_new": both, "t3_tenant_writer": both,
                                         "x1_legacy_only": ["aws_only"], "tp_planner": ["aws_only"]})
        conn = self._fetch("SELECT enabled, secret_name, monthly_budget_usd::text AS budget, updated_by"
                           " FROM shared.llm_provider_connection WHERE connection_key = 'anthropic-direct'")[0]
        self.assertEqual(conn, {"enabled": False, "secret_name": "aa-llm/dev/anthropic-direct", "budget": "150.00",
                                "updated_by": script.ACTOR})
        row = self._fetch("SELECT wire_id, priority, enabled, origin FROM shared.llm_model_deployment"
                          " WHERE model_key = 'anth-beta' AND connection_key = 'anthropic-direct'")
        self.assertEqual(row, [{"wire_id": "claude-beta-2", "priority": 100, "enabled": True, "origin": "seed"}])
        self.assertIn("SCRIPT state view=after apply (read-only)", text)

        code, text = self._run("apply")
        self.assertEqual(code, 0, text)
        self.assertIn("SCRIPT committed changes=0", text)

    def test_refuses_a_non_dev_database(self):
        async def make_prod():
            conn = await asyncpg.connect(_dsn(DB))
            try:
                await conn.execute("UPDATE shared.llm_provider_connection"
                                   " SET secret_name = 'aa-llm/prod/anthropic-direct'"
                                   " WHERE connection_key = 'anthropic-direct'")
            finally:
                await conn.close()

        asyncio.run(make_prod())
        before = self.scopes()
        code, text = self._run("apply")
        self.assertEqual(code, 1, text)
        self.assertIn("SCRIPT refuse", text)
        self.assertEqual(self.scopes(), before)


if __name__ == "__main__":
    unittest.main()
