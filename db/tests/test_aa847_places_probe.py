"""AA-847: db/scripts/aa847_places_probe.py (read-only places probe: coverage gate, reader timings, fingerprints).

No database, no asyncpg: a fake connection answers the probe's SQL by matching on it, so the whole main() runs and
every report line is exercised. The reader SQL block is generated from the TripPlanner source by the root
docs/audits/2026-10-21-S246-aa847/gen_probe_sql.py (`--check` re-generates and diffs it).
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import json
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa847_places_probe.py"
_spec = importlib.util.spec_from_file_location("aa847_places_probe", ROOT / PATH)
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)

LAOS_SRC = "11111111-1111-1111-1111-111111111111"
VN_SRC = "22222222-2222-2222-2222-222222222222"
OLD_TOUR = "33333333-3333-3333-3333-333333333333"   # an old tour_id the frozen tables still use for VN_SRC
ORPHAN = "44444444-4444-4444-4444-444444444444"     # a frozen key of a tour that is not live any more
ITIN = "Day 1 — Arrive in Luang Prabang\nKuang Si Falls swim.\n\nDay 2-3 — Mekong\nBoat.\n\nDay 4 — Depart\nBye."
REQUIRED_READERS = (
    "browse.countries.COUNTRIES_SQL", "browse.countries.COUNTRIES_SQL_CIS", "browse.tiles.TILE_SQL",
    "browse.tiles.TILE_SQL_CIS", "browse.destinations.DEST_SQL_CIS", "browse.destinations.COMPONENTS_SQL_CIS",
    "browse.routes.SINGLE_SQL_CIS", "browse.routes.CHAIN_SQL_CIS", "browse.routes.DAYS_SQL_CIS",
    "browse.routes.COMPONENTS_SQL_CIS", "shared.vector_topk.TOPK_SQL",
)
# The cis search reader: the exact aggregate before TripPlanner 6c, the top-k over catalog.v_component_embedding after.
CIS_SEARCH_READERS = ("browse.search.CIS_SEARCH_SQL", "shared.vector_topk.TOPK_SQL_CIS")
# What a 6c-generated block adds (the assembly twins); a test runs the probe with stand-ins for them.
ASSEMBLY_6C = {
    "assembly.events.COMPONENTS_SQL":
        "SELECT c.id FROM tripplanner.itinerary_components c WHERE c.id = ANY($1::uuid[])",
    "assembly.events.COMPONENTS_SQL_CIS":
        "SELECT c.component_id AS id FROM catalog.v_tour_component c WHERE c.component_id = ANY($1::uuid[])",
    "assembly.suggestions.TASTE_SQL": "SELECT c.embedding FROM tripplanner.itinerary_components c WHERE c.id = ANY($1)",
    "assembly.suggestions.TASTE_SQL_CIS":
        "SELECT c.embedding FROM catalog.v_tour_component c WHERE c.component_id = ANY($1::uuid[])",
    "assembly.coverage.OPTIONS_SQL": "SELECT DISTINCT destination_id FROM tripplanner.itinerary_components",
    "assembly.coverage.OPTIONS_SQL_CIS": "SELECT DISTINCT destination_id FROM catalog.v_tour_component",
    "assembly.activities.ACTIVITIES_SQL": "SELECT c.name FROM tripplanner.itinerary_components c",
    "assembly.activities.ACTIVITIES_SQL_CIS": "SELECT c.name FROM catalog.v_tour_component c",
    "assembly.suggestions.ROUTE_CANDIDATES_SQL": "SELECT n.destination_id FROM tripplanner.tour_graph_node n",
    "assembly.suggestions.ROUTE_CANDIDATES_SQL_CIS": "SELECT n.destination_id FROM catalog.v_graph_node n",
    "shared.component_ids.MAP_SQL": "SELECT old_id, new_id FROM tripplanner.component_id_map",
    "shared.vector_topk.TOPK_SQL_CIS": "SELECT od.destination_id AS id FROM catalog.v_component_embedding c",
    "shared.vector_topk.EXACT_SQL_CIS": "SELECT d.destination_id AS id FROM catalog.v_tour_component c",
}
PLAN = json.dumps([{"Plan": {"Node Type": "Limit", "Actual Total Time": 5.0, "Actual Loops": 1, "Actual Rows": 3,
                             "Plans": [{"Node Type": "Subquery Scan", "Alias": "d", "Actual Total Time": 4.0,
                                        "Actual Loops": 1, "Actual Rows": 3, "Filter": "(d.lat >= $1)",
                                        "Plans": [{"Node Type": "Seq Scan", "Relation Name": "destinations",
                                                   "Actual Total Time": 1.0, "Actual Loops": 1, "Actual Rows": 9,
                                                   "Filter": "(country = $1)"}]}]},
                    "Execution Time": 5.5, "Planning Time": 0.4}])


class FakeConn:
    def __init__(self, refuse_role=False):
        self.refuse_role = refuse_role
        self.role = "aa_cis_admin"
        self.statements = []

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if "SET LOCAL ROLE" in sql:
            if self.refuse_role:
                raise PermissionError("permission denied to set role")
            self.role = "tripplanner"
        return "OK"

    async def fetchval(self, sql, *args):
        self.statements.append(sql)
        if "current_user" in sql:
            return self.role
        if "extversion" in sql:
            return "0.8.0"
        if sql.lstrip().startswith("EXPLAIN") or "EXPLAIN (ANALYZE" in sql:
            return PLAN
        if "current_setting" in sql:
            return "off"
        return 3

    async def fetch(self, sql, *args):
        self.statements.append(sql)
        p = probe
        if sql is p.LIVE_TOURS_SQL:
            return [{"source_id": LAOS_SRC, "tour_id": LAOS_SRC, "title": "Laos Kuang Si", "country": "Laos"},
                    {"source_id": VN_SRC, "tour_id": VN_SRC, "title": "Ho Chi Minh Trail by Bicycle, 14 Days",
                     "country": "Vietnam"}]
        if sql is p.CIS_COMPONENT_SOURCES_SQL or sql is p.CIS_GRAPH_SOURCES_SQL:
            return [{"source_id": LAOS_SRC}]
        if sql is p.FROZEN_KEYS_SQL:
            return [{"key": LAOS_SRC}, {"key": OLD_TOUR}, {"key": ORPHAN}]
        if sql is p.KEY_MAP_SQL:
            assert args[0] == p.AA_TENANT_ID
            return [{"key": OLD_TOUR, "source_id": VN_SRC, "country": "Vietnam"}]
        if sql is p.COUNTRY_DESTS_SQL:
            return [{"id": "d1", "lat": 19.7, "lng": 102.1}, {"id": "d2", "lat": 19.75, "lng": 102.2}]
        if sql is p.QUERY_VECTORS_SQL:
            return [{"v": "[0.1,0.2]"}]
        if sql is p.SAMPLE_TOURS_SQL:
            return [{"tour_id": LAOS_SRC, "source_id": LAOS_SRC}]
        if sql is p.VIEWS_SQL:
            return [{"relname": "v_tour"}, {"relname": "v_tour_component"}]
        if "md5(coalesce(string_agg" in sql:
            return [{"n": 2, "h": "abc"}]
        if sql is p.DEFECT_TOURS_SQL:
            return [{"tour_id": LAOS_SRC, "source_id": LAOS_SRC, "title": "Laos Kuang Si", "country": "Laos",
                     "duration_raw": "4 days", "duration_days": 4, "itinerary_text": ITIN}]
        if sql is p.DEFECT_COMPONENTS_SQL:
            return [{"day_index": 1, "name": "Kuang Si Falls", "destination_id": "d1", "destination_name": "Kuang Si",
                     "geo_precision": "point", "located_by": "geoapify", "review_reason": None,
                     "result_type": "amenity", "lat": 19.7, "lng": 102.1}]
        if sql is p.FROZEN_DAY_COUNTS_SQL:
            return [{"day": 1, "n": 2}]
        if sql is p.KUANG_SI_SQL:
            return [{"id": "d1aaaaaa", "name": "Kuang Si Falls", "country": "Laos", "lat": 19.749, "lng": 101.993,
                     "located_by": "geoapify", "geo_precision": "point", "geo_status": "ok", "dup": None},
                    {"id": "d2bbbbbb", "name": "Tat Kuang Si", "country": "Laos", "lat": 19.75, "lng": 101.99,
                     "located_by": "llm", "geo_precision": "area", "geo_status": "ok", "dup": None}]
        if sql is p.TOUR_TEXTS_SQL:
            return [{"source_id": LAOS_SRC, "tour_id": LAOS_SRC, "country": "Laos", "itinerary_text": ITIN},
                    {"source_id": VN_SRC, "tour_id": VN_SRC, "country": "Vietnam", "itinerary_text": ITIN}]
        if sql is p.FROZEN_COMPONENTS_SQL:
            return [{"name": "Kuang Si Falls", "source_tour_id": LAOS_SRC, "source_day_index": 1},
                    {"name": "Amber Fort", "source_tour_id": OLD_TOUR, "source_day_index": 4},
                    {"name": "Gone", "source_tour_id": ORPHAN, "source_day_index": 1}]
        if sql is p.CIS_COMPONENTS_TEXT_SQL:
            return [{"name": "Kuang Si Falls", "source_id": LAOS_SRC, "day_index": 1}]
        if sql is p.BUILD_BY_COUNTRY_SQL:
            return [{"country": "Laos", "status": "ok", "n": 27, "cost_usd": 0.81, "avg_cost_usd": 0.03}]
        if sql is p.BUILD_STATE_SQL:
            return [{"source_id": LAOS_SRC, "status": "ok", "built_at": "t", "cost_usd": 0.03}]
        if sql is p.TP_GRANTS_SQL:
            return [{"kind": "column", "object": "silver_aa_internal.raw_tours(country,tour_id) SELECT", "ok": True}]
        if sql is p.XREF_SQL:
            return [{"table_schema": "booking", "table_name": "hotels"}]
        if sql is p.ANALYZE_SQL:
            return [{"rel": "geo.tour_place", "n_live_tup": 967, "reltuples": 10.0, "last_analyze": None,
                     "last_autoanalyze": None}]
        if sql is p.STATEMENTS_SQL:
            return []
        if sql is p.ASM_IDS_SQL or sql is p.ASM_IDS_SQL_CIS:
            return [{"id": "c1"}, {"id": "c2"}]
        if "browse.routes" not in sql and "SELECT" in sql:
            # a TripPlanner reader (legacy or cis): a couple of rows in the shape the probe reads back
            return [{"tour_id": LAOS_SRC, "a_tour": LAOS_SRC, "b_tour": VN_SRC, "destination_id": "d1", "n": 1}]
        raise AssertionError(f"unexpected SQL: {sql[:80]}")

    @contextlib.asynccontextmanager
    async def transaction(self):
        yield


def _run(conn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(probe.main(conn))
    return rc, buf.getvalue().splitlines()


class ShapeTests(unittest.TestCase):
    def test_runner_accepts_the_file_as_read_only(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source))

    def test_reader_block_is_generated_from_a_tripplanner_commit(self):
        self.assertRegex(probe.READERS_FROM, r"^AA-TripPlanner-Web@[0-9a-f]{12}$")
        for key in REQUIRED_READERS:
            self.assertIn(key, probe.READERS)
        self.assertTrue(any(k in probe.READERS for k in CIS_SEARCH_READERS), "no cis search reader")
        for key, sql in probe.READERS.items():
            self.assertIsInstance(sql, str, key)
            self.assertNotRegex(sql, r"\{[a-z_]+\}", f"{key}: an unrendered placeholder")
        text = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(text.count("# BEGIN GENERATED READERS"), 1)
        self.assertEqual(text.count("# END GENERATED READERS"), 1)

    def test_cis_readers_read_catalog_views_only(self):
        for key, sql in probe.READERS.items():
            if key.endswith("_CIS") and "SQL" in key:
                self.assertNotIn("tripplanner.itinerary_components", sql, key)
                self.assertNotIn("tripplanner.tour_", sql, key)
                self.assertNotIn("shared.destinations", sql, key)

    def test_legacy_topk_gets_its_active_tour_filter_back(self):
        sql = probe.reader("shared.vector_topk.TOPK_SQL")
        self.assertNotIn("<ACTIVE_TOUR_SQL>", sql)
        self.assertIn("gold_aa_internal.published_tours", sql)


class HelperTests(unittest.TestCase):
    def test_heading_days_lists_ranged_headings(self):
        canonical, ranged, covered = probe.heading_days(ITIN)
        self.assertEqual(canonical, {1, 4})
        self.assertEqual(ranged, ["2-3"])
        self.assertEqual(covered, {1, 2, 3, 4})

    def test_day_texts_fold_a_ranged_heading_into_the_previous_day(self):
        days = probe.day_texts(ITIN)
        self.assertEqual(sorted(days), [1, 4])
        self.assertIn("Mekong", days[1])          # the catalog's _tour_day_text rule (AA-847 ranged_heading)

    def test_names_place(self):
        self.assertTrue(probe.names_place("Swim at the Kuang Si Falls", "Kuang Si Falls"))
        self.assertTrue(probe.names_place("Swim at Kuang Si", "Kuang Si Waterfall"))
        self.assertFalse(probe.names_place("Drive to Jaisalmer", "Amber Fort"))
        self.assertTrue(probe.names_place("Visit Hội An old town", "Hoi An"))

    def test_km(self):
        self.assertAlmostEqual(probe.km(0, 0, 0, 1), 111.19, places=1)

    def test_fmt_quotes_spaces(self):
        self.assertEqual(probe._fmt("a b"), '"a b"')
        self.assertEqual(probe._fmt(None), "-")
        self.assertEqual(probe._fmt(True), "t")


class RunTests(unittest.TestCase):
    def test_full_run_reports_every_section(self):
        rc, lines = _run(FakeConn())
        self.assertEqual(rc, 0)
        text = "\n".join(lines)
        self.assertNotIn("section_error", text)
        self.assertIn("SCRIPT pass role=tripplanner", text)
        for kind in ("inputs", "timing", "parity", "parity_total", "fingerprint", "defect_tour", "defect_component",
                     "defect_pair", "day_text", "coverage", "coverage_gate", "env", "grant", "xref", "stats", "done"):
            self.assertRegex(text, rf"(?m)^SCRIPT {kind}\b", kind)
        self.assertTrue(all(line.startswith("SCRIPT ") for line in lines))

    def test_coverage_gate_counts_live_frozen_keys_only(self):
        _, lines = _run(FakeConn())
        # VN_SRC is live and in the frozen tables (through OLD_TOUR) but has no cis components: missing.
        # ORPHAN is not live: it is counted as not live, never as missing.
        self.assertIn("SCRIPT coverage_gate missing_in_cis_live=1 verdict=FAIL", lines)
        self.assertTrue(any(line.startswith("SCRIPT coverage_missing country=Vietnam source_id=" + VN_SRC)
                            for line in lines))
        self.assertTrue(any("not_live=1" in line for line in lines if line.startswith("SCRIPT coverage_frozen")))

    def test_qual_above_a_barrier_subquery_is_reported_not_pushed(self):
        _, lines = _run(FakeConn())
        tiles = [line for line in lines if line.startswith("SCRIPT qual reader=tiles")]
        self.assertTrue(any("marker=\"lat >=\"" in line and "pushed=f" in line for line in tiles), tiles)

    def test_day_text_check_maps_old_tour_ids_and_skips_orphans(self):
        _, lines = _run(FakeConn())
        frozen = [line for line in lines if line.startswith("SCRIPT day_text source=frozen")]
        self.assertTrue(any("country=Vietnam" in line and "not_named=1" in line for line in frozen), frozen)
        self.assertFalse(any("Gone" in line for line in frozen))

    def test_after_6c_the_assembly_readers_and_the_cis_top_k_are_timed(self):
        saved = dict(probe.READERS)
        probe.READERS.update(ASSEMBLY_6C)
        probe.READERS.pop("browse.search.CIS_SEARCH_SQL", None)
        try:
            _, lines = _run(FakeConn())
        finally:
            probe.READERS.clear()
            probe.READERS.update(saved)
        text = "\n".join(lines)
        self.assertNotIn("section_error", text)
        for name in ("assembly_components", "assembly_taste", "assembly_options", "assembly_activities",
                     "assembly_route_candidates"):
            self.assertRegex(text, rf"(?m)^SCRIPT parity reader={name} country=Laos ", name)
        self.assertRegex(text, r"(?m)^SCRIPT timing reader=assembly_id_map country=Laos source=cis ")
        self.assertRegex(text, r"(?m)^SCRIPT timing reader=search_exact country=Laos source=cis ")
        self.assertIn("SCRIPT assembly_input country=Laos destinations=2 legacy_ids=2 cis_ids=2", lines)

    def test_before_6c_no_assembly_section(self):
        _, lines = _run(FakeConn())
        self.assertFalse(any(line.startswith("SCRIPT assembly_input") for line in lines))

    def test_refused_role_switch_returns_1(self):
        rc, lines = _run(FakeConn(refuse_role=True))
        self.assertEqual(rc, 1)
        self.assertTrue(any(line.startswith("SCRIPT refuse what=set_role") for line in lines))

    def test_no_write_statement(self):
        conn = FakeConn()
        _run(conn)
        for sql in conn.statements:
            self.assertIsNone(re.search(r"\b(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE)\b",
                                        sql.split("FROM")[0] if "EXPLAIN" in sql else sql, re.I), sql[:80])


if __name__ == "__main__":
    unittest.main()
