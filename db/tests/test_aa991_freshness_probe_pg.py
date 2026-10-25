"""AA-991: db/scripts/aa991_freshness_probe.py against a real PostgreSQL (the SQL itself, not a fake connection).

Skipped unless AA991_TEST_PG_DSN names a throw-away server's superuser DSN (and asyncpg is importable): the CI job
of db/tests has neither, so this file runs locally only. It creates the database `aa991_freshness_test` (dropped
first), a stub of every object the probe reads with the column names of docs/architecture/db-schema-reference.md
(Verified 2026-10-25, CIS 280), the role `cis_app` (NOLOGIN) and a non-superuser login that is a member of it (the
master's relation to cis_app on RDS), seeds a small world with known stale links and runs the probe in a session with
default_transaction_read_only=on (what the runner sets for READ_ONLY scripts).

  AA991_TEST_PG_DSN=postgresql://postgres@127.0.0.1:55491/postgres python3 -m unittest db.tests.test_aa991_freshness_probe_pg
  (or: python3 -m unittest discover -s db/tests -p 'test_aa991*')
"""
import asyncio
import contextlib
import importlib.util
import io
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import freshness_gate as gate  # noqa: E402

ROOT = HERE.parent.parent
DSN = os.environ.get("AA991_TEST_PG_DSN", "")
try:
    import asyncpg  # noqa: F401
except ImportError:  # CI image of db/tests: standard library + pyyaml only
    asyncpg = None

_spec = importlib.util.spec_from_file_location("aa991_freshness_probe", ROOT / "db/scripts/aa991_freshness_probe.py")
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)

DB = "aa991_freshness_test"
LOGIN = "aa991_probe_login"

SCHEMA = """
CREATE ROLE cis_app NOLOGIN;
CREATE ROLE aa991_probe_login LOGIN NOSUPERUSER IN ROLE cis_app;
CREATE SCHEMA gold_aa_internal; CREATE SCHEMA acp_contract; CREATE SCHEMA acp_shared; CREATE SCHEMA geo;
CREATE SCHEMA silver_aa_internal; CREATE SCHEMA shared;
CREATE TYPE gold_aa_internal.master_status_enum AS ENUM ('active', 'inactive', 'trashed');
CREATE TABLE gold_aa_internal.published_tours (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tour_id uuid NOT NULL UNIQUE,
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001',
    master_status gold_aa_internal.master_status_enum NOT NULL, deleted_at timestamptz,
    published_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL);
ALTER TABLE gold_aa_internal.published_tours ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold_aa_internal.published_tours FORCE ROW LEVEL SECURITY;
CREATE POLICY published_tours_cis_app_all ON gold_aa_internal.published_tours TO cis_app USING (true) WITH CHECK (true);
-- v_tour_liveness is a view over raw_tours / published_tours / events on RDS; the probe reads tour_id + changed_at.
CREATE TABLE gold_aa_internal.v_tour_liveness (source_system text, source_id text, tour_id uuid, state text,
    reason text, changed_at timestamptz);
CREATE TABLE gold_aa_internal.tenant_tour_versions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000002', published_tour_id uuid NOT NULL,
    created_at timestamptz NOT NULL);
CREATE TABLE acp_contract.tour_atoms (atom_id text PRIMARY KEY, tour_id uuid NOT NULL,
    owner_scope text NOT NULL DEFAULT 'platform', text text NOT NULL DEFAULT 'x', activity_type text,
    deleted boolean NOT NULL DEFAULT false, is_empty_marker boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, itinerary_day smallint, place text,
    action text, evidence text);
ALTER TABLE acp_contract.tour_atoms ENABLE ROW LEVEL SECURITY;
CREATE POLICY tour_atoms_cis_app_all ON acp_contract.tour_atoms TO cis_app USING (true) WITH CHECK (true);
CREATE VIEW acp_contract.v_active_tour_atoms AS
SELECT ta.* FROM acp_contract.tour_atoms ta
  JOIN gold_aa_internal.published_tours pt ON pt.tour_id = ta.tour_id AND pt.master_status = 'active'
   AND pt.deleted_at IS NULL
 WHERE NOT ta.deleted AND NOT ta.is_empty_marker;
CREATE TABLE acp_contract.atom_segment (segment_id text PRIMARY KEY, canonical_place text NOT NULL,
    canonical_action text NOT NULL, created_at timestamptz NOT NULL);
CREATE TABLE acp_contract.atom_segment_member (segment_id text NOT NULL, atom_id text NOT NULL,
    is_alias boolean NOT NULL DEFAULT false, PRIMARY KEY (segment_id, atom_id));
CREATE TABLE acp_contract.atom_segment_alias (segment_id_old text PRIMARY KEY, segment_id_canonical text NOT NULL,
    merged_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE acp_shared.subject (subject_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000002', segment_id text, route_id text,
    channel text NOT NULL DEFAULT 'blog', state text NOT NULL DEFAULT 'proposed',
    cleared_bar_reason jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE acp_shared.subject ENABLE ROW LEVEL SECURITY;
CREATE POLICY subject_cis_app_all ON acp_shared.subject TO cis_app USING (true) WITH CHECK (true);
CREATE TABLE acp_shared.debate_brand_fit_cache (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000002', segment_id text, route_id text,
    brand_version integer NOT NULL DEFAULT 1, computed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE acp_contract.atom_ranking (tour_id uuid NOT NULL, segment_id text NOT NULL, market text NOT NULL,
    excluded_reason text, computed_at timestamptz NOT NULL, version integer NOT NULL DEFAULT 1,
    superseded_at timestamptz, recurrence integer NOT NULL DEFAULT 1, questions integer NOT NULL DEFAULT 0,
    said integer NOT NULL DEFAULT 0);
CREATE TABLE acp_contract.route (route_id text PRIMARY KEY, tour_id uuid NOT NULL, hub_id uuid,
    hub_name text NOT NULL DEFAULT '', ordered_segment_ids jsonb NOT NULL, first_day smallint NOT NULL,
    last_day smallint NOT NULL, created_at timestamptz NOT NULL, version integer NOT NULL DEFAULT 1,
    superseded_at timestamptz);
CREATE TABLE geo.tour_place (component_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), source_id text NOT NULL,
    tour_id uuid NOT NULL, day_index integer NOT NULL DEFAULT 1, atom_ids text[] NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE acp_shared.atom_place_card (atom_id text PRIMARY KEY, card_id uuid,
    resolved_at timestamptz NOT NULL DEFAULT now(), miss_reason text);
CREATE TABLE acp_shared.angle_gate_request (request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000002', atom_id text NOT NULL,
    status text NOT NULL DEFAULT 'pending_goal', created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL,
    route_segment_ids jsonb);
ALTER TABLE acp_shared.angle_gate_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY angle_gate_request_cis_app_all ON acp_shared.angle_gate_request TO cis_app USING (true) WITH CHECK (true);
CREATE TABLE silver_aa_internal.seo_context (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tour_id uuid NOT NULL,
    tenant_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001', expires_at timestamptz,
    cache_key character varying(500), fetched_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE shared.job (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL, status text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now());
GRANT USAGE ON SCHEMA gold_aa_internal, acp_contract, acp_shared, geo, silver_aa_internal, shared TO cis_app;
GRANT SELECT ON ALL TABLES IN SCHEMA gold_aa_internal, acp_contract, acp_shared, geo, silver_aa_internal, shared
    TO cis_app;
"""

# T1 healthy; T2 re-published 2 days ago and nothing followed; T3 re-published 1 hour ago (inside the window);
# T4 paused 2 days ago with ranking left behind; T5 active with no atoms. Times are relative to now().
T = {n: f"00000000-0000-0000-0000-00000000000{n}" for n in range(1, 6)}
SEED = f"""
INSERT INTO gold_aa_internal.published_tours (tour_id, master_status, updated_at) VALUES
 ('{T[1]}', 'active', now() - interval '3 days'), ('{T[2]}', 'active', now() - interval '2 days'),
 ('{T[3]}', 'active', now() - interval '1 hour'), ('{T[4]}', 'inactive', now() - interval '10 days'),
 ('{T[5]}', 'active', now() - interval '5 days');
INSERT INTO gold_aa_internal.v_tour_liveness (source_id, tour_id, state, changed_at) VALUES
 ('k1', '{T[1]}', 'served', now() - interval '30 days'), ('k2', '{T[2]}', 'served', now() - interval '30 days'),
 ('k3', '{T[3]}', 'served', now() - interval '30 days'), ('k4', '{T[4]}', 'paused', now() - interval '2 days'),
 ('k5', '{T[5]}', 'served', now() - interval '30 days');
INSERT INTO acp_contract.tour_atoms (atom_id, tour_id, place, itinerary_day, deleted, created_at, updated_at) VALUES
 ('a1', '{T[1]}', 'Hanoi', 1, false, now() - interval '3 days', now() - interval '3 days' + interval '1 minute'),
 ('a2', '{T[1]}', 'Halong', 2, false, now() - interval '3 days', now() - interval '3 days' + interval '1 minute'),
 ('a3', '{T[2]}', 'Hue', 1, false, now() - interval '3 days', now() - interval '3 days'),
 ('a3old', '{T[2]}', 'Hue old', 1, true, now() - interval '9 days', now() - interval '9 days'),
 ('a5', '{T[3]}', 'Kyoto', 1, false, now() - interval '30 minutes', now() - interval '30 minutes'),
 ('a6', '{T[3]}', 'Nara', 2, false, now() - interval '30 minutes', now() - interval '30 minutes'),
 ('a7', '{T[4]}', 'Seoul', 1, false, now() - interval '10 days', now() - interval '10 days');
INSERT INTO acp_contract.atom_segment (segment_id, canonical_place, canonical_action, created_at) VALUES
 ('S1', 'Hanoi', 'visit', now() - interval '10 days'), ('S2', 'Halong', 'cruise', now() - interval '10 days'),
 ('S3', 'Hue old', 'visit', now() - interval '10 days'), ('S5', 'Kyoto', 'visit', now() - interval '10 days'),
 ('S6', 'Nara', 'visit', now() - interval '10 days'), ('S7', 'Seoul', 'visit', now() - interval '10 days'),
 ('S8', 'Nowhere', 'visit', now() - interval '10 days'), ('S9', 'Gone', 'visit', now() - interval '10 days'),
 ('S10', 'Kyoto', 'eat', now() - interval '10 days'), ('S11', 'Hanoi old', 'visit', now() - interval '10 days'),
 ('S12', 'Seoul', 'walk', now() - interval '10 days');
INSERT INTO acp_contract.atom_segment_member (segment_id, atom_id) VALUES
 ('S1', 'a1'), ('S2', 'a2'), ('S3', 'a3old'), ('S5', 'a5'), ('S6', 'a6'), ('S7', 'a7'), ('S10', 'a5'),
 ('S12', 'a7');
-- AA-988: S11 gave way to S1 (alias row keeps it); S12's only member is an atom of the paused T4 (kept for a restore)
INSERT INTO acp_contract.atom_segment_alias (segment_id_old, segment_id_canonical) VALUES ('S11', 'S1');
INSERT INTO acp_contract.atom_ranking (tour_id, segment_id, market, computed_at, superseded_at) VALUES
 ('{T[1]}', 'S1', 'US', now() - interval '3 days', NULL), ('{T[1]}', 'S2', 'US', now() - interval '3 days', NULL),
 ('{T[1]}', 'S1', 'US', now() - interval '9 days', now() - interval '3 days'),
 ('{T[2]}', 'S3', 'US', now() - interval '9 days', NULL),
 ('{T[3]}', 'S5', 'US', now() - interval '20 minutes', NULL), ('{T[3]}', 'S6', 'US', now() - interval '20 minutes', NULL),
 ('{T[4]}', 'S7', 'US', now() - interval '10 days', NULL);
INSERT INTO acp_contract.route (route_id, tour_id, ordered_segment_ids, first_day, last_day, created_at) VALUES
 ('{T[1]}:1-2', '{T[1]}', '["S1", "S2"]', 1, 2, now() - interval '3 days' + interval '5 minutes'),
 ('{T[2]}:1-2', '{T[2]}', '["S3", "S9"]', 1, 2, now() - interval '5 days');
INSERT INTO geo.tour_place (source_id, tour_id, atom_ids) VALUES
 ('k1', '{T[1]}', ARRAY['a1']), ('k2', '{T[2]}', ARRAY['a3old']), ('k4', '{T[4]}', ARRAY['a7']);
INSERT INTO acp_shared.atom_place_card (atom_id, card_id) VALUES
 ('a1', gen_random_uuid()), ('a2', NULL), ('a3old', gen_random_uuid());
INSERT INTO gold_aa_internal.tenant_tour_versions (published_tour_id, created_at)
 SELECT id, now() - interval '4 days' FROM gold_aa_internal.published_tours WHERE tour_id = '{T[1]}'
 UNION ALL SELECT id, now() - interval '2 days' FROM gold_aa_internal.published_tours WHERE tour_id = '{T[1]}';
INSERT INTO acp_shared.angle_gate_request (atom_id, created_at, updated_at) VALUES
 ('a3old', now() - interval '9 days', now() - interval '9 days'), ('a1', now() - interval '1 day', now()),
 ('gone-atom', now() - interval '1 hour', now() - interval '1 hour');
INSERT INTO silver_aa_internal.seo_context (tour_id, expires_at, cache_key, fetched_at) VALUES
 ('{T[1]}', now() + interval '30 days', 'x:ideas_v3', now() - interval '10 days'),
 ('{T[2]}', now() - interval '2 days', 'x:ideas_v2', now() - interval '200 days'),
 ('{T[4]}', now() - interval '1 hour', NULL, now() - interval '40 days'),
 ('{T[3]}', now() - interval '2 days', 'x:ideas_v3', now() - interval '30 days'),
 ('{T[3]}', now() - interval '20 days', NULL, now() - interval '300 days');
-- AA-990/991: T3's newest row expired but is an ideas_v3 row S1 still reuses (fetched 30 days ago) → not stale;
-- T3's older row never counts (newest row per tour only).
INSERT INTO shared.job (kind, status) VALUES ('recompute', 'queued'), ('a3_atomize', 'succeeded');
"""

# metric -> (n, aged) for the seed above (worked out by hand in docs/implementation-notes/AA-991.md, Should know).
EXPECTED = {
    "atoms_older_than_master": (1, 1), "active_tours_without_atoms": (1, 1), "active_atoms_without_segment": (1, 1),
    "tours_with_place_atoms_but_no_segment": (1, 1), "orphan_segments": (1, 1),
    "orphan_segments_kept_referenced": (2, 2), "ranking_missing": (1, 0),
    "ranking_off_active_pairs": (2, 2), "active_tours_without_ranking": (1, 1), "routes_missing": (1, 0),
    "routes_differ": (1, 1), "active_tours_without_route": (2, 1), "current_routes_older_than_atoms": (1, 1),
    "routes_with_dead_segment": (1, 1), "geo_tour_place_rows_on_inactive_atoms": (2, 2),
    "geo_tour_place_stale_rows": (1, 1), "place_card_links_missing": (1, 1),
    "active_place_atoms_without_card_link": (3, 1), "tenant_versions_older_than_master": (1, 1),
    "angle_gate_requests_on_inactive_atoms": (2, 1), "seo_context_expired": (4, 3),
    "seo_context_expired_active_tours": (1, 1),
}


def _dsn(db, user=None):
    """The test DSN with another database (and user)."""
    head, _, tail = DSN.rpartition("/")
    base = head + "/" + db + ("?" + tail.split("?", 1)[1] if "?" in tail else "")
    if user:
        scheme, _, rest = base.partition("://")
        hostpart = rest.split("@", 1)[1] if "@" in rest else rest
        base = f"{scheme}://{user}@{hostpart}"
    return base


async def _setup():
    admin = await asyncpg.connect(DSN)
    try:
        await admin.execute(f"DROP DATABASE IF EXISTS {DB}")
        for role in (LOGIN, "cis_app"):
            await admin.execute(f"DROP ROLE IF EXISTS {role}")
        await admin.execute(f"CREATE DATABASE {DB}")
    finally:
        await admin.close()
    conn = await asyncpg.connect(_dsn(DB))
    try:
        await conn.execute(SCHEMA)
        await conn.execute(SEED)
    finally:
        await conn.close()


async def _teardown():
    admin = await asyncpg.connect(DSN)
    try:
        await admin.execute(f"DROP DATABASE IF EXISTS {DB}")
        for role in (LOGIN, "cis_app"):
            await admin.execute(f"DROP ROLE IF EXISTS {role}")
    finally:
        await admin.close()


async def _run_probe(user=LOGIN):
    conn = await asyncpg.connect(_dsn(DB, user), server_settings={"default_transaction_read_only": "on"})
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = await probe.main(conn)
    finally:
        await conn.close()
    return rc, buf.getvalue().splitlines()


RAN_AS = "MIGRATE ran as: aa_cis_admin (run-script, READ_ONLY: default_transaction_read_only=on)"


@unittest.skipUnless(DSN and asyncpg is not None, "set AA991_TEST_PG_DSN (throw-away server) and install asyncpg")
class ProbeOnPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        asyncio.run(_setup())
        cls.rc, cls.lines = asyncio.run(_run_probe())
        cls.res, why = gate.read_json(cls.lines)
        assert why is None, why

    @classmethod
    def tearDownClass(cls):
        asyncio.run(_teardown())

    def test_runs_clean_as_cis_app(self):
        self.assertEqual(self.rc, 0)
        self.assertEqual(self.res["errors"], [], self.res["errors"])
        self.assertEqual(self.res["read_as"], "cis_app")
        self.assertEqual(self.res["login"], LOGIN)

    def test_every_metric_counts_what_the_seed_planted(self):
        got = {n: (m["n"], m["aged"]) for n, m in self.res["metrics"].items()}
        self.assertEqual(got, EXPECTED)
        self.assertEqual(list(self.res["metrics"]), list(probe.METRICS) + list(probe.ROUTE_METRICS))

    def test_samples_name_the_planted_rows(self):
        m = self.res["metrics"]
        self.assertEqual(m["atoms_older_than_master"]["sample_aged"], [T[2]])
        self.assertEqual(m["orphan_segments"]["sample"], ["S8"])
        self.assertEqual(m["orphan_segments_kept_referenced"]["sample"], ["S11", "S12"])
        self.assertEqual(m["seo_context_expired_active_tours"]["sample"], [T[2]])
        self.assertEqual(m["routes_missing"]["sample"], [T[3]])
        self.assertEqual(m["routes_differ"]["sample_aged"], [T[2]])
        self.assertEqual(sorted(m["ranking_off_active_pairs"]["sample"]), sorted([T[2], T[4]]))
        self.assertEqual(m["place_card_links_missing"]["sample"], ["a3"])

    def test_totals_jobs_and_route_parity(self):
        t = self.res["totals"]
        self.assertEqual((t["active_tours"], t["active_atoms"], t["tours_changed_within_window"]), (4, 5, 1))
        self.assertEqual(self.res["jobs_in_flight"], [{"kind": "recompute", "status": "queued", "n": 1}])
        self.assertEqual(self.res["route_parity"], {"expected_routes": 2, "current_routes_compared": 2})

    def test_verdict_and_gate(self):
        v = self.res["verdict"]
        self.assertEqual((v["stale"], v["stale_aged"], v["errors"]), (13, 12, 0))
        log = [RAN_AS] + self.lines
        report = gate.evaluate(log, "0", enforce=False)
        self.assertTrue(report["green"], report["failures"])
        self.assertEqual(len(report["would_fail"]), 11)
        enforced = gate.evaluate(log, "0", enforce=True)
        self.assertFalse(enforced["green"])
        self.assertEqual(sum(f.startswith("stale: ") for f in enforced["failures"]), 11)

    def test_role_switch_refused_is_an_error_not_a_master_read(self):
        async def run():
            admin = await asyncpg.connect(_dsn(DB))
            try:
                await admin.execute("CREATE ROLE aa991_outsider LOGIN NOSUPERUSER")
            finally:
                await admin.close()
            try:
                return await _run_probe("aa991_outsider")
            finally:
                admin = await asyncpg.connect(_dsn(DB))
                try:
                    await admin.execute("DROP ROLE aa991_outsider")
                finally:
                    await admin.close()
        rc, lines = asyncio.run(run())
        res, why = gate.read_json(lines)
        self.assertIsNone(why)
        self.assertEqual(rc, 0)
        self.assertEqual(res["metrics"], {})
        self.assertEqual(res["errors"][0]["metric"], "session")
        self.assertEqual(res["errors"][0]["sqlstate"], "42501")
        self.assertFalse(gate.evaluate([RAN_AS] + lines, "0")["green"])


if __name__ == "__main__":
    unittest.main()
