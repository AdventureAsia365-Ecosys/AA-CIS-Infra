"""Unit tests for db/check_migration_ownership.py (AA-853 migration ownership lint).

Run: python3 -m unittest discover -s db/tests -v
"""
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_migration_files as cmf  # noqa: E402
import check_migration_ownership as own  # noqa: E402

REPO = Path(__file__).resolve().parent.parent.parent
REGISTER = "INSERT INTO shared.schema_versions (version, description) VALUES ('{key}', 'x') ON CONFLICT DO NOTHING;\n"


def wrap(body: str, key: str = "bk-099") -> str:
    return "BEGIN;\n" + body + "\n" + REGISTER.format(key=key) + "COMMIT;\n"


def errors(sql: str, path: str = "db/migrations/booking/099_x.sql") -> list:
    return own.lint(sql, path)[0]


class OwnSchemaIsClean(unittest.TestCase):
    def test_booking_objects_and_registration(self):
        sql = wrap("""
            CREATE TABLE IF NOT EXISTS booking.thing (id bigint PRIMARY KEY, ref text REFERENCES booking.other (id));
            CREATE UNIQUE INDEX IF NOT EXISTS thing_ref_uidx ON booking.thing (ref);
            CREATE OR REPLACE VIEW booking.v_thing AS SELECT t.id FROM booking.thing t JOIN catalog.v_tour v ON true;
            CREATE TRIGGER thing_touch BEFORE UPDATE OF ref ON booking.thing
                FOR EACH ROW EXECUTE FUNCTION booking.touch();
            ALTER TABLE booking.thing ENABLE ROW LEVEL SECURITY;
            CREATE POLICY thing_tenant ON booking.thing FOR ALL TO booking USING (true);
            COMMENT ON COLUMN booking.thing.ref IS 'pii:contact; x';
            GRANT SELECT, INSERT ON booking.thing TO booking;
            GRANT USAGE ON SCHEMA booking TO booking;
            ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner IN SCHEMA booking GRANT SELECT ON TABLES TO booking;
            UPDATE booking.thing SET ref = NULL WHERE id = 1;
            DELETE FROM booking.thing WHERE id = 2;
        """)
        self.assertEqual(errors(sql), [])

    def test_reads_of_other_owners_are_not_findings(self):
        sql = wrap("""
            CREATE VIEW booking.v_x AS SELECT * FROM catalog.v_tour WHERE source_id IN (SELECT id FROM shared.job);
            CREATE TABLE booking.y (a int, FOREIGN KEY (a) REFERENCES booking.z (id) ON UPDATE SET NULL);
            SELECT geo.name_norm('x') FOR UPDATE;
        """)
        self.assertEqual(errors(sql), [])

    def test_function_bodies_are_not_read(self):
        sql = wrap("""
            CREATE OR REPLACE FUNCTION booking.f() RETURNS void LANGUAGE sql
                AS $$ INSERT INTO shared.job (kind) VALUES ('x') $$;
        """)
        self.assertEqual(errors(sql), [])

    def test_temporary_objects(self):
        sql = wrap("""
            CREATE TEMP TABLE snap ON COMMIT DROP AS SELECT 1;
            CREATE OR REPLACE TEMP VIEW snap_v AS SELECT 1;
            INSERT INTO snap SELECT 2;
            DROP VIEW snap_v;
        """)
        self.assertEqual(errors(sql), [])

    def test_search_path_resolves_unqualified_names(self):
        sql = wrap("""
            SET LOCAL search_path TO booking, public;
            CREATE TABLE thing (id int);
            COMMENT ON COLUMN thing.id IS 'x';
        """)
        self.assertEqual(errors(sql), [])

    def test_search_path_names_the_file_created_earlier_resolve_to_it(self):
        sql = wrap("""
            SET search_path = booking, catalog;
            CREATE TABLE products (id int);
            INSERT INTO products VALUES (1);
            ALTER TABLE products ADD COLUMN x int;
        """)
        self.assertEqual(errors(sql), [])

    def test_quoted_search_path(self):
        self.assertEqual(errors(wrap("SET search_path = 'booking';\nCREATE TABLE thing (id int);")), [])
        self.assertEqual(errors(wrap("SET LOCAL search_path TO \"booking\";\nCREATE TABLE thing (id int);")), [])

    def test_own_statements_review_round(self):
        sql = wrap("""
            CREATE SCHEMA AUTHORIZATION booking;
            ALTER TABLE ALL IN TABLESPACE pg_default SET TABLESPACE pg_default;
            SELECT 1 AS a INTO booking.snapshot;
            SELECT 1 AS a INTO TEMP snap2;
            INSERT INTO snap2 SELECT 2;
            ALTER TABLE booking.parent ATTACH PARTITION booking.p2026 FOR VALUES FROM (1) TO (2);
            CREATE EXTENSION IF NOT EXISTS citext SCHEMA booking;
            ALTER DEFAULT PRIVILEGES FOR ROLE bk_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
            REASSIGN OWNED BY bk_owner TO bk_owner;
            DO $$ DECLARE n int; BEGIN SELECT count(*) INTO n FROM catalog.v_tour; END $$;
        """)
        self.assertEqual(errors(sql), [])

    def test_owner_roles_mirror_the_registry(self):
        import isolation_probe as probe
        self.assertEqual(own.OWNER_ROLES, {k: frozenset({o.owner_role}) | o.view_owner_roles
                                           for k, o in probe.OWNERS.items()})

    def test_roles_dir_is_not_checked(self):
        self.assertEqual(errors("GRANT USAGE ON SCHEMA shared TO bk_owner;", "db/migrations/roles/009_x.sql"), [])

    def test_strings_naming_other_schemas_are_not_objects(self):
        sql = wrap("DO $$ BEGIN RAISE NOTICE 'CREATE TABLE shared.x'; END $$;")
        self.assertEqual(errors(sql), [])


class OtherOwnersFail(unittest.TestCase):
    CASES = {
        "CREATE TABLE shared.x (id int);": "CREATE TABLE shared.x",
        "CREATE UNLOGGED TABLE IF NOT EXISTS tripplanner.x (id int);": "CREATE TABLE tripplanner.x",
        "CREATE SCHEMA IF NOT EXISTS reporting;": "CREATE SCHEMA reporting",
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS j_idx ON shared.job (kind);": "CREATE INDEX ON shared.job",
        "CREATE OR REPLACE TRIGGER t AFTER INSERT ON shared.job FOR EACH ROW EXECUTE FUNCTION booking.f();":
            "CREATE TRIGGER ON shared.job",
        "CREATE POLICY p ON crm.trip TO booking USING (true);": "CREATE POLICY ON crm.trip",
        "DROP POLICY IF EXISTS p ON crm.trip;": "DROP POLICY ON crm.trip",
        "ALTER TABLE ONLY shared.job ADD COLUMN x int;": "ALTER TABLE shared.job",
        "ALTER TABLE booking.t SET SCHEMA shared;": "ALTER TABLE SET SCHEMA shared",
        "DROP FUNCTION IF EXISTS booking.f(int, text), geo.name_norm(text);": "DROP FUNCTION geo.name_norm",
        "DROP TABLE IF EXISTS public.leftover CASCADE;": "DROP TABLE public.leftover",
        "COMMENT ON COLUMN shared.job.kind IS 'x';": "COMMENT ON COLUMN shared.job",
        "COMMENT ON TABLE catalog.v_tour IS 'x';": "COMMENT ON TABLE catalog.v_tour",
        "GRANT SELECT ON catalog.v_tour TO booking;": "GRANT ON catalog.v_tour",
        "GRANT SELECT (id) ON TABLE shared.job TO booking;": "GRANT ON shared.job",
        "REVOKE ALL ON SCHEMA tripplanner FROM PUBLIC;": "GRANT ON SCHEMA tripplanner",
        "GRANT SELECT ON ALL TABLES IN SCHEMA shared, geo TO booking;": "GRANT ON ALL IN SCHEMA geo",
        "ALTER DEFAULT PRIVILEGES IN SCHEMA shared GRANT SELECT ON TABLES TO booking;":
            "ALTER DEFAULT PRIVILEGES IN SCHEMA shared",
        "INSERT INTO shared.job (kind) VALUES ('bk_x');": "INSERT INTO shared.job",
        "UPDATE shared.job j SET status = 'done';": "UPDATE shared.job",
        "WITH d AS (SELECT 1) DELETE FROM ONLY shared.job;": "DELETE FROM shared.job",
        "TRUNCATE TABLE booking.a, shared.job RESTART IDENTITY;": "TRUNCATE shared.job",
        "REFRESH MATERIALIZED VIEW CONCURRENTLY shared.mv;": "REFRESH MATERIALIZED VIEW shared.mv",
        "DO $$ BEGIN IF NOT EXISTS (SELECT 1) THEN ALTER TABLE shared.job ADD COLUMN y int; END IF; END $$;":
            "ALTER TABLE shared.job",
        'CREATE TABLE "shared"."Quoted" (id int);': "CREATE TABLE shared.quoted",
        # review round (S250): statements the first version let through
        "SELECT 1 AS a INTO catalog.newt;": "SELECT INTO catalog.newt",
        "WITH s AS (SELECT 1 AS a) SELECT a INTO UNLOGGED TABLE shared.s2 FROM s;": "SELECT INTO shared.s2",
        "ALTER TABLE booking.t ATTACH PARTITION catalog.p FOR VALUES IN (1);": "ATTACH PARTITION catalog.p",
        "ALTER TABLE booking.t DETACH PARTITION shared.p CONCURRENTLY;": "DETACH PARTITION shared.p",
        "CREATE EXTENSION IF NOT EXISTS citext SCHEMA catalog;": "CREATE EXTENSION catalog.citext",
        "ALTER DEFAULT PRIVILEGES FOR ROLE catalog_owner GRANT SELECT ON TABLES TO booking;":
            "ALTER DEFAULT PRIVILEGES without IN SCHEMA (role catalog_owner)",
        "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO booking;":
            "ALTER DEFAULT PRIVILEGES without IN SCHEMA (the role running the file)",
        "REASSIGN OWNED BY catalog_owner TO bk_owner;": "REASSIGN OWNED BY (role catalog_owner)",
        "DROP OWNED BY bk_owner;": "DROP OWNED BY (role bk_owner)",
        "CREATE SCHEMA AUTHORIZATION crm;": "CREATE SCHEMA crm",
    }

    def test_each_touch_of_another_schema_fails(self):
        for stmt, expected in self.CASES.items():
            with self.subTest(stmt=stmt):
                errs = errors(wrap(stmt))
                self.assertTrue(errs, stmt)
                self.assertTrue(any(expected in e for e in errs), errs)
                self.assertTrue(all("AA-853" in e for e in errs))

    def test_unqualified_create_without_search_path(self):
        errs = errors(wrap("CREATE TABLE loose (id int);"))
        self.assertEqual(len(errs), 1)
        self.assertIn("unqualified", errs[0])

    def test_search_path_with_another_owners_schema(self):
        # PostgreSQL resolves a non-CREATE name to the first schema of the path that holds it: catalog.products here.
        for stmt in ("INSERT INTO products VALUES (1);", "ALTER TABLE products ADD COLUMN x int;",
                     "DROP TABLE products;", "GRANT SELECT ON products TO booking;",
                     "CREATE INDEX p_idx ON products (id);"):
            with self.subTest(stmt=stmt):
                errs = errors(wrap("SET search_path = booking, catalog;\n" + stmt))
                self.assertEqual(len(errs), 1, errs)
                self.assertIn("may be catalog", errs[0])
        errs = errors(wrap("SET search_path = 'booking, catalog';\nUPDATE products SET id = 2;"))
        self.assertIn("may be catalog", errs[0])

    def test_reset_search_path_clears_it(self):
        for reset in ("RESET search_path;", "SET search_path TO DEFAULT;", "SET LOCAL search_path = DEFAULT;"):
            with self.subTest(reset=reset):
                errs = errors(wrap(f"SET search_path = booking;\n{reset}\nCREATE TABLE loose (id int);"))
                self.assertEqual(len(errs), 1, errs)
                self.assertIn("unqualified", errs[0])

    def test_owner_named_in_message(self):
        errs = errors(wrap("CREATE TABLE crm.x (id int);"))
        self.assertIn("belongs to owner crm", errs[0])
        errs = errors(wrap("CREATE TABLE public.x (id int);"))
        self.assertIn("no owner in db/owners.yaml", errs[0])

    def test_cis_may_touch_every_cis_schema_but_not_booking(self):
        path = "db/migrations/cis/299_x.sql"
        self.assertEqual(errors(wrap("CREATE TABLE geo.x (id int); GRANT USAGE ON SCHEMA catalog TO booking;", "299"),
                                path), [])
        self.assertTrue(errors(wrap("ALTER TABLE booking.trip_case ADD COLUMN x int;", "299"), path))

    def test_cis_may_still_name_the_schemas_it_dropped(self):
        # AA-850: CIS 299 dropped four empty schemas (owners.yaml dropped_schemas). 244 / 245 grant on them and 299
        # drops them, so cis/ files may name them; they belong to no other owner, which may not.
        path = "db/migrations/cis/299_x.sql"
        sql = wrap("DROP SCHEMA IF EXISTS acp_silver_s4 RESTRICT; GRANT USAGE ON SCHEMA acp_gold_output TO cis_app;",
                   "299")
        self.assertEqual(errors(sql, path), [])
        errs = errors(wrap("CREATE TABLE acp_silver_s2.x (id int);"))
        self.assertTrue(errs)
        self.assertIn("belongs to owner cis", errs[0])

    def test_historical_tripplanner_destinations_file_fails(self):
        # TripPlanner migrations/002_shared_destinations.sql (2026) created a CIS table: the case the lint exists for.
        sql = ("CREATE TABLE IF NOT EXISTS shared.destinations (id uuid PRIMARY KEY);\n"
               "CREATE UNIQUE INDEX IF NOT EXISTS destinations_lower_name_uidx ON shared.destinations (lower(name));\n")
        errs = errors(sql, "db/migrations/tripplanner/002_shared_destinations.sql")
        self.assertEqual(len(errs), 2)

    def test_dynamic_sql_is_a_note_not_an_error(self):
        sql = wrap("DO $$ BEGIN EXECUTE format('ALTER TABLE %I.x ADD y int', 'shared'); END $$;")
        errs, notes = own.lint(sql, "db/migrations/booking/099_x.sql")
        self.assertEqual(errs, [])
        self.assertEqual(len(notes), 1)


class EveryCopyPasses(unittest.TestCase):
    def test_every_copy_in_the_repo(self):
        failures = {}
        for f in sorted((REPO / "db" / "migrations").glob("*/*.sql")):
            rel = f.relative_to(REPO).as_posix()
            errs = errors(f.read_text(encoding="utf-8"), rel)
            if errs:
                failures[rel] = errs
        self.assertEqual(failures, {})


class WiredIntoTheCopyGuardLint(unittest.TestCase):
    def test_check_migration_files_fails_on_a_foreign_touch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = root / "db" / "migrations" / "booking"
            d.mkdir(parents=True)
            (d / "098_ok.sql").write_text(wrap("CREATE TABLE booking.ok (id int);", "bk-098"), encoding="utf-8")
            (d / "099_bad.sql").write_text(wrap("CREATE TABLE shared.bad (id int);"), encoding="utf-8")
            out = io.StringIO()
            code = cmf.run(cmf.all_copies(root), root, out=out)
        self.assertEqual(code, 1)
        self.assertIn("ok    db/migrations/booking/098_ok.sql", out.getvalue())
        self.assertIn("FAIL  db/migrations/booking/099_bad.sql: line 2: CREATE TABLE shared.bad", out.getvalue())


if __name__ == "__main__":
    unittest.main()
