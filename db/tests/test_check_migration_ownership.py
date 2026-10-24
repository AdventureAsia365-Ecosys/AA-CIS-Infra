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
