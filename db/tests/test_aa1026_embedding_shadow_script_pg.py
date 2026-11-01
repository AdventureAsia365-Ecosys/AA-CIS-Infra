"""AA-1026 D5 (S263): db/scripts/aa1026_embedding_shadow.py against a real PostgreSQL (the DDL itself).

Skipped unless AA1026_TEST_PG_DSN names a throw-away server's superuser DSN (and asyncpg is importable): the CI job of
db/tests has neither, so this file runs locally only. It creates the database `aa1026_shadow_test` (dropped first), the
roles `cis_owner` (NOLOGIN, owner), `cis_app`, `catalog_owner`, `tripplanner` and a NON-superuser login that is a member
of cis_owner and NOT of catalog_owner (the RDS master's relation to them: roles/002, X1 plan §1.4), the two registry
tables of AA-CIS-App migration 328 and the trigger function of 329 (same DDL), and an invented table with real[]
vector columns (no pgvector here; SHADOW_TYPE = "real[]") read by a plain view, a nested view and, for the refusal, a
catalog view owned by catalog_owner. Every step runs through `run()` as that login, like DB Migrate run-script.

  AA1026_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55484/postgres python3 -m unittest db.tests.test_aa1026_embedding_shadow_script_pg
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
DSN = os.environ.get("AA1026_TEST_PG_DSN", "")
try:
    import asyncpg
except ImportError:  # CI image of db/tests: standard library + pyyaml only
    asyncpg = None

DB = "aa1026_shadow_test"
LOGIN = "aa1026_master_login"
COHERE, TITAN = "cohere-embed-v4/1536/v1", "titan-embed-text-v2/1024/v1"

SCHEMA = """
CREATE SCHEMA shared AUTHORIZATION cis_owner;
CREATE SCHEMA catalog AUTHORIZATION cis_owner;
SET ROLE cis_owner;
CREATE TABLE shared.embedding_space (
    space_key text PRIMARY KEY, model_family text NOT NULL, model_id text NOT NULL, model_keys text[] NOT NULL,
    dimension integer NOT NULL, document_input_type text, query_input_type text, version integer NOT NULL DEFAULT 1,
    status text NOT NULL CHECK (status IN ('active', 'standby', 'retired')), notes text,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL);
CREATE TABLE shared.embedding_column (
    table_schema text NOT NULL, table_name text NOT NULL, column_name text NOT NULL,
    space_key text NOT NULL REFERENCES shared.embedding_space (space_key), swap_group text NOT NULL,
    key_columns text[] NOT NULL, writer_stages text[] NOT NULL DEFAULT '{}'::text[], source_key text,
    shadow_column text, shadow_space_key text REFERENCES shared.embedding_space (space_key),
    previous_column text, previous_space_key text REFERENCES shared.embedding_space (space_key),
    readers text, notes text, updated_at timestamptz NOT NULL DEFAULT now(), updated_by text NOT NULL,
    PRIMARY KEY (table_schema, table_name, column_name),
    CONSTRAINT embedding_column_shadow_check CHECK (
        (shadow_column IS NULL) = (shadow_space_key IS NULL)
        AND (shadow_column IS NULL OR shadow_column = column_name || '__shadow')
        AND shadow_space_key IS DISTINCT FROM space_key),
    CONSTRAINT embedding_column_previous_check CHECK (
        (previous_column IS NULL) = (previous_space_key IS NULL)
        AND (previous_column IS NULL OR previous_column = column_name || '__prev')
        AND previous_space_key IS DISTINCT FROM space_key));
CREATE FUNCTION shared._embedding_shadow_reset()
RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    NEW := jsonb_populate_record(NEW, jsonb_build_object(TG_ARGV[0], NULL));
    RETURN NEW;
END
$fn$;
REVOKE ALL ON FUNCTION shared._embedding_shadow_reset() FROM PUBLIC;
INSERT INTO shared.embedding_space (space_key, model_family, model_id, model_keys, dimension, status, updated_by)
VALUES ('cohere-embed-v4/1536/v1', 'cohere', 'cohere.embed-v4:0', '{cohere-embed-v4}', 1536, 'active', 'seed'),
       ('titan-embed-text-v2/1024/v1', 'amazon', 'amazon.titan-embed-text-v2:0', '{titan-embed-text-v2}', 1024,
        'standby', 'seed');

CREATE TABLE shared.zz_vec (id integer PRIMARY KEY, emb real[] NOT NULL, note text);
CREATE INDEX zz_vec_emb_idx ON shared.zz_vec (emb);
INSERT INTO shared.zz_vec VALUES (1, '{1,1}', 'first'), (2, '{2,2}', 'second');
CREATE VIEW shared.zz_v1 WITH (security_barrier = true) AS SELECT id, emb FROM shared.zz_vec;
CREATE VIEW shared.zz_v2 AS SELECT id, emb FROM shared.zz_v1;
COMMENT ON VIEW shared.zz_v1 IS 'invented view';
COMMENT ON COLUMN shared.zz_v1.emb IS 'invented column note';
GRANT USAGE ON SCHEMA shared TO cis_app, tripplanner, catalog_owner;
GRANT SELECT ON shared.zz_v1 TO tripplanner;
GRANT SELECT, INSERT, UPDATE ON shared.zz_vec TO cis_app;
INSERT INTO shared.embedding_column (table_schema, table_name, column_name, space_key, swap_group, key_columns,
                                     updated_by)
VALUES ('shared', 'zz_vec', 'emb', 'cohere-embed-v4/1536/v1', 'zz_group', '{id}', 'seed');

CREATE TABLE shared.zz_place (id integer PRIMARY KEY, emb real[]);
INSERT INTO shared.zz_place VALUES (1, '{1,1}');
GRANT SELECT ON shared.zz_place TO catalog_owner;
GRANT CREATE ON SCHEMA catalog TO catalog_owner;
INSERT INTO shared.embedding_column (table_schema, table_name, column_name, space_key, swap_group, key_columns,
                                     updated_by)
VALUES ('shared', 'zz_place', 'emb', 'cohere-embed-v4/1536/v1', 'zz_catalog', '{id}', 'seed');
RESET ROLE;
SET ROLE catalog_owner;
CREATE VIEW catalog.zz_cv AS SELECT id, emb FROM shared.zz_place;
RESET ROLE;
REVOKE CREATE ON SCHEMA catalog FROM catalog_owner;
"""


def _dsn(db: str, user: str = None) -> str:
    parts = urlsplit(DSN)
    netloc = parts.netloc
    if user:
        netloc = f"{user}@{netloc.split('@', 1)[-1]}"
    return urlunsplit((parts.scheme, netloc, f"/{db}", parts.query, parts.fragment))


def _load():
    spec = importlib.util.spec_from_file_location("aa1026_embedding_shadow",
                                                  ROOT / "db/scripts/aa1026_embedding_shadow.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.SHADOW_TYPE = "real[]"
    mod.COLUMN = "shared.zz_vec.emb"
    mod.SPACE = TITAN
    return mod


@unittest.skipUnless(DSN and asyncpg is not None, "AA1026_TEST_PG_DSN not set or asyncpg missing (local only)")
class RealPostgresTest(unittest.TestCase):
    def setUp(self):
        async def setup():
            admin = await asyncpg.connect(DSN)
            try:
                await admin.execute(f"DROP DATABASE IF EXISTS {DB}")
                for role in (LOGIN, "cis_app", "tripplanner", "catalog_owner", "cis_owner"):
                    await admin.execute(f"DROP ROLE IF EXISTS {role}")
                for role in ("cis_owner", "cis_app", "catalog_owner", "tripplanner"):
                    await admin.execute(f"CREATE ROLE {role} NOLOGIN")
                await admin.execute(f"CREATE ROLE {LOGIN} LOGIN NOSUPERUSER IN ROLE cis_owner")
                await admin.execute(f"CREATE DATABASE {DB}")
            finally:
                await admin.close()
            db = await asyncpg.connect(_dsn(DB))
            try:
                await db.execute(SCHEMA)
            finally:
                await db.close()

        asyncio.run(setup())
        self.mod = _load()

    def step(self, action, mode="apply", **constants):
        for k, v in constants.items():
            setattr(self.mod, k, v)

        async def go():
            conn = await asyncpg.connect(_dsn(DB, LOGIN))
            try:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    code = await self.mod.run(conn, mode, action)
                return code, buf.getvalue()
            finally:
                await conn.close()

        return asyncio.run(go())

    def sql(self, statement, role=None):
        async def go():
            conn = await asyncpg.connect(_dsn(DB))
            try:
                async with conn.transaction():
                    if role:
                        await conn.execute(f"SET LOCAL ROLE {role}")
                    rows = await conn.fetch(statement)
                return [dict(r) for r in rows]
            finally:
                await conn.close()

        return asyncio.run(go())

    def registry(self, table="zz_vec"):
        return self.sql("SELECT space_key, shadow_column, shadow_space_key, previous_column, previous_space_key "
                        f"FROM shared.embedding_column WHERE table_name = '{table}'")[0]

    def values(self, view):
        return [r["emb"] for r in self.sql(f"SELECT emb FROM {view} ORDER BY id")]

    def columns(self):
        return [(r["attname"], r["attnotnull"]) for r in self.sql(
            "SELECT attname, attnotnull FROM pg_attribute WHERE attrelid = 'shared.zz_vec'::regclass "
            "AND attname LIKE 'emb%' AND NOT attisdropped ORDER BY attname")]

    def indexes(self):
        return [r["i"] for r in self.sql("SELECT indexrelid::regclass::text AS i FROM pg_index "
                                         "WHERE indrelid = 'shared.zz_vec'::regclass AND NOT indisprimary ORDER BY 1")]

    def triggers(self):
        return [r["tgname"] for r in self.sql("SELECT tgname FROM pg_trigger WHERE tgrelid = 'shared.zz_vec'::regclass "
                                              "AND NOT tgisinternal")]

    def fill(self, expr="ARRAY[id * 10, id * 10]::real[]"):
        self.sql(f"UPDATE shared.zz_vec SET emb__shadow = {expr}", role="cis_owner")

    def test_dry_run_prepare_changes_nothing(self):
        code, text = self.step("prepare", mode="dry_run")
        self.assertEqual(code, 0, text)
        self.assertIn("SCRIPT ddl sql=ALTER TABLE", text)
        self.assertIn("SCRIPT rolled_back", text)
        self.assertEqual(self.columns(), [("emb", True)])
        self.assertEqual(self.registry(), {"space_key": COHERE, "shadow_column": None, "shadow_space_key": None,
                                           "previous_column": None, "previous_space_key": None})

    def test_prepare_fill_swap_rollback_and_drop(self):
        code, text = self.step("prepare")
        self.assertEqual(code, 0, text)
        code, text = self.step("prepare")                                 # idempotent: a fill resumes
        self.assertIn("SCRIPT done action=prepare result=emb__shadow", text)
        self.assertEqual(self.registry()["shadow_column"], "emb__shadow")
        self.assertEqual(self.triggers(), ["emb__shadow_reset"])
        code, text = self.step("swap")
        self.assertEqual(code, 1)
        self.assertIn("2 row(s) have a vector but no shadow vector", text)

        self.fill()
        self.sql("CREATE INDEX zz_vec_emb_idx__shadow ON shared.zz_vec (emb__shadow)", role="cis_owner")
        code, text = self.step("swap", mode="dry_run")
        self.assertEqual(code, 0, text)
        self.assertIn("CREATE VIEW \"shared\".\"zz_v1\" WITH (security_barrier=true) AS <its definition>", text)
        self.assertEqual(self.values("shared.zz_v2"), [[1.0, 1.0], [2.0, 2.0]])      # the dry run rolled back
        code, text = self.step("swap")
        self.assertEqual(code, 0, text)
        self.assertIn("SCRIPT done action=swap result=1", text)

        for view in ("shared.zz_v1", "shared.zz_v2"):
            self.assertEqual(self.values(view), [[10.0, 10.0], [20.0, 20.0]], view)
        self.assertEqual(self.registry(), {"space_key": TITAN, "shadow_column": None, "shadow_space_key": None,
                                           "previous_column": "emb__prev", "previous_space_key": COHERE})
        self.assertEqual(self.sql(f"SELECT status FROM shared.embedding_space WHERE space_key = '{TITAN}'"),
                         [{"status": "active"}])
        v1 = self.sql("SELECT pg_get_userbyid(relowner) AS owner, reloptions, "
                      "obj_description(oid, 'pg_class') AS comment, col_description(oid, 2) AS col, "
                      "has_table_privilege('tripplanner', oid, 'SELECT') AS tp "
                      "FROM pg_class WHERE oid = 'shared.zz_v1'::regclass")[0]
        self.assertEqual(v1, {"owner": "cis_owner", "reloptions": ["security_barrier=true"],
                              "comment": "invented view", "col": "invented column note", "tp": True})
        self.assertEqual(self.columns(), [("emb", True), ("emb__prev", False)])
        self.assertEqual(self.indexes(), ["shared.zz_vec_emb_idx", "shared.zz_vec_emb_idx__prev"])
        self.assertTrue(self.sql("SELECT pg_get_indexdef('shared.zz_vec_emb_idx'::regclass) AS d")[0]["d"]
                        .endswith("(emb)"))
        self.assertEqual(self.triggers(), [])

        # a writer after the swap fills only the new column; rolling back then needs ALLOW_MISSING
        self.sql("INSERT INTO shared.zz_vec (id, emb) VALUES (3, '{30,30}')", role="cis_app")
        code, text = self.step("rollback")
        self.assertEqual(code, 1)
        self.assertIn("1 row(s) have no vector in emb__prev", text)
        self.assertEqual(self.registry()["space_key"], TITAN)                             # nothing changed
        self.sql("DELETE FROM shared.zz_vec WHERE id = 3")
        code, text = self.step("rollback")
        self.assertEqual(code, 0, text)
        for view in ("shared.zz_v1", "shared.zz_v2"):
            self.assertEqual(self.values(view), [[1.0, 1.0], [2.0, 2.0]], view)
        self.assertEqual(self.registry(), {"space_key": COHERE, "shadow_column": "emb__shadow",
                                           "shadow_space_key": TITAN, "previous_column": None,
                                           "previous_space_key": None})
        self.assertEqual(self.indexes(), ["shared.zz_vec_emb_idx", "shared.zz_vec_emb_idx__shadow"])
        self.assertEqual(self.triggers(), ["emb__shadow_reset"])

        code, text = self.step("drop_shadow")
        self.assertEqual(code, 0, text)
        self.assertEqual(self.registry()["shadow_column"], None)
        self.assertEqual(self.columns(), [("emb", True)])
        self.assertEqual(self.triggers(), [])

    def test_a_rewritten_serving_vector_empties_its_shadow(self):
        self.step("prepare")
        self.fill()
        # the writers run as cis_app: a re-embed of row 1, an unchanged vector on row 2, then an upsert of row 2
        self.sql("UPDATE shared.zz_vec SET emb = '{9,9}' WHERE id = 1", role="cis_app")
        self.sql("UPDATE shared.zz_vec SET emb = '{2,2}', note = 'same vector' WHERE id = 2", role="cis_app")
        shadow = {r["id"]: r["s"] for r in self.sql("SELECT id, emb__shadow AS s FROM shared.zz_vec")}
        self.assertEqual(shadow, {1: None, 2: [20.0, 20.0]})
        self.sql("INSERT INTO shared.zz_vec (id, emb) VALUES (2, '{8,8}') "
                 "ON CONFLICT (id) DO UPDATE SET emb = EXCLUDED.emb", role="cis_app")
        self.assertEqual(self.sql("SELECT count(emb__shadow) AS n FROM shared.zz_vec"), [{"n": 0}])
        code, text = self.step("swap")
        self.assertEqual(code, 1)
        self.assertIn("2 row(s) have a vector but no shadow vector", text)
        self.fill("ARRAY[id * 100, id * 100]::real[]")                     # a fill catch-up is not reset
        code, text = self.step("swap")
        self.assertEqual(code, 0, text)
        self.assertEqual(self.values("shared.zz_v1"), [[100.0, 100.0], [200.0, 200.0]])

    def test_swap_allow_missing_leaves_unfilled_rows_empty(self):
        self.sql("ALTER TABLE shared.zz_vec ALTER COLUMN emb DROP NOT NULL", role="cis_owner")
        self.step("prepare")
        self.sql("UPDATE shared.zz_vec SET emb__shadow = '{5,5}' WHERE id = 1", role="cis_owner")
        code, text = self.step("swap", ALLOW_MISSING=True)
        self.assertEqual(code, 0, text)
        self.assertEqual(self.values("shared.zz_v1"), [[5.0, 5.0], None])

    def test_a_view_of_another_owner_is_refused_before_any_change(self):
        code, text = self.step("prepare", COLUMN="shared.zz_place.emb")
        self.assertEqual(code, 0, text)
        self.sql("UPDATE shared.zz_place SET emb__shadow = '{7,7}'", role="cis_owner")
        code, text = self.step("swap", COLUMN="shared.zz_place.emb")
        self.assertEqual(code, 1)
        self.assertIn("catalog.zz_cv belongs to catalog_owner", text)
        self.assertIn("cis/ migration", text)
        self.assertEqual(self.registry("zz_place")["space_key"], COHERE)
        self.assertEqual(self.values("catalog.zz_cv"), [[1.0, 1.0]])

    def test_prepare_refusals(self):
        for constants, why in (({"COLUMN": "shared.zz_vec.nope"}, "is not in shared.embedding_column"),
                               ({"SPACE": COHERE}, "already serves"),
                               ({"SPACE": "nope/16/v1"}, "unknown or retired")):
            mod = _load()
            for k, v in constants.items():
                setattr(mod, k, v)
            self.mod = mod
            code, text = self.step("prepare")
            self.assertEqual(code, 1, why)
            self.assertIn(why, text)
        self.mod = _load()
        self.sql("DROP FUNCTION shared._embedding_shadow_reset()")
        code, text = self.step("prepare")
        self.assertEqual(code, 1)
        self.assertIn("apply AA-CIS-App migration 329 first", text)


if __name__ == "__main__":
    unittest.main()
