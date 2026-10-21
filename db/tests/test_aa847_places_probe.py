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
# The pre-6c cis search (the exact aggregate), for the test that simulates a block generated before 6c.
PRE_6C_CIS_SEARCH = ("SELECT d.destination_id AS id, MIN(c.embedding <=> $1::vector) AS best_distance "
                     "FROM catalog.v_tour_component c JOIN catalog.v_destination d "
                     "ON d.destination_id = c.destination_id GROUP BY d.destination_id LIMIT 60")
PLAN = json.dumps([{"Plan": {"Node Type": "Limit", "Actual Total Time": 5.0, "Actual Loops": 1, "Actual Rows": 3,
                             "Plans": [{"Node Type": "Subquery Scan", "Alias": "d", "Actual Total Time": 4.0,
                                        "Actual Loops": 1, "Actual Rows": 3, "Filter": "(d.lat >= $1)",
                                        "Plans": [{"Node Type": "Seq Scan", "Relation Name": "destinations",
                                                   "Actual Total Time": 1.0, "Actual Loops": 1, "Actual Rows": 9,
                                                   "Filter": "(country = $1)"}]}]},
                    "Execution Time": 5.5, "Planning Time": 0.4}])


def _node(node_type, rel=None, loops=1, kids=(), **extra):
    n = {"Node Type": node_type, "Actual Total Time": 1.0, "Actual Loops": loops, "Actual Rows": 1, **extra}
    if rel:
        n["Relation Name"] = rel
    if kids:
        n["Plans"] = list(kids)
    return n


def _topk_doc(scan_plan, count_loops=60):
    """A TOPK_SQL_CIS-shaped plan: the `scan` CTE (InitPlan) + the per-destination component_count SubPlan."""
    cte = dict(_node("Limit", kids=[scan_plan]), **{"Parent Relationship": "InitPlan", "Subplan Name": "CTE scan"})
    count = dict(_node("Aggregate", kids=[_node("Hash Join", kids=[
        _node("Seq Scan", "raw_tours", loops=count_loops), _node("Seq Scan", "tour_place", loops=count_loops)])]),
        **{"Parent Relationship": "SubPlan", "Subplan Name": "SubPlan 2"})
    root = _node("Limit", kids=[cte, _node("Sort", kids=[_node("Hash Join", kids=[_node("CTE Scan", Alias="c"),
                                                                                    _node("Seq Scan", "tour_place")]),
                                                         count])])
    return json.dumps([{"Plan": root, "Execution Time": 13.0, "Planning Time": 2.0}])


def _live(rt_scan):
    return _node("Hash Join", kids=[_node("Seq Scan", "published_tours"), _node("Hash", kids=[rt_scan])])


# Dev today (S246): natural = exact top-N sort over a seq scan; liveness = a hash semi join
TOPK_NATURAL = _topk_doc(_node("Sort", kids=[_node("Hash Semi Join", kids=[
    _node("Seq Scan", "tour_place"), _node("Hash", kids=[_live(_node("Seq Scan", "raw_tours"))])])]))
# enable_sort=off before 258: HNSW ordered by distance, liveness through a Join Filter on the expression key
TOPK_FORCED_PRE258 = _topk_doc(_node("Nested Loop", **{"Join Type": "Semi", "Join Filter":
                                                      "((COALESCE(rt.source_group_id, rt.tour_id))::text = gp.source_id)"},
                                     kids=[_node("Index Scan", "tour_place", **{"Index Name": "tour_place_embedding_hnsw",
                                                                                "Order By": "(embedding <=> $1)"}),
                                           _node("Materialize", kids=[_live(_node("Seq Scan", "raw_tours"))])]))
# after 258: the liveness probe is an index scan on the stored key, no Join Filter
TOPK_FORCED_POST258 = _topk_doc(_node("Nested Loop", **{"Join Type": "Semi"}, kids=[
    _node("Index Scan", "tour_place", **{"Index Name": "tour_place_embedding_hnsw", "Order By": "(embedding <=> $1)"}),
    _node("Nested Loop", kids=[_node("Index Scan", "raw_tours", **{"Index Name": "raw_tours_source_key_idx",
                                                                   "Index Cond": "(source_key = gp.source_id)"}),
                               _node("Index Scan", "published_tours", **{"Index Name": "published_tours_pkey"})])]),
    count_loops=1)


class FakeConn:
    def __init__(self, refuse_role=False, forced_plan=TOPK_FORCED_PRE258, fail_execute_explain=False):
        self.refuse_role = refuse_role
        self.forced_plan = forced_plan
        self.fail_execute_explain = fail_execute_explain
        self.role = "aa_cis_admin"
        self.statements = []
        self.settings = {}          # transaction-local settings (set_config(..., true)), rolled back with a savepoint
        self.fetch_log = []         # (sql, plan_cache_mode at the call)
        self.fetch_settings = []    # (sql, every transaction-local setting at the call)
        self.explain_log = []       # (sql, settings at the EXPLAIN, role)

    def setting(self, name):
        return self.settings.get(name, {"plan_cache_mode": "auto", "enable_sort": "on"}.get(name, "off"))

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if "SET LOCAL ROLE" in sql:
            if self.refuse_role:
                raise PermissionError("permission denied to set role")
            self.role = "tripplanner"
        m = re.search(r"set_config\(('([^']+)'|\$1), *('([^']*)'|\$\d), *true\)", sql)
        if m:
            name = m.group(2) or args[0]
            value = m.group(4) if m.group(4) is not None else args[-1]
            self.settings[name] = value
        return "OK"

    async def fetchval(self, sql, *args):
        self.statements.append(sql)
        if "current_user" in sql:
            return self.role
        if "extversion" in sql:
            return "0.8.0"
        if sql.lstrip().startswith("EXPLAIN") or "EXPLAIN (ANALYZE" in sql:
            self.explain_log.append((sql, dict(self.settings), self.role))
            if "EXECUTE " + probe.GENERIC_STMT in sql and self.fail_execute_explain:
                raise RuntimeError("explain failed")
            if "catalog.v_component_embedding" in sql:
                return self.forced_plan if self.setting("enable_sort") == "off" else TOPK_NATURAL
            return PLAN
        m = re.search(r"current_setting\('([^']+)'", sql) or re.match(r"\s*SHOW (\w+)", sql)
        if m:
            return self.setting(m.group(1))
        return 3

    async def fetch(self, sql, *args):
        self.statements.append(sql)
        self.fetch_log.append((sql, self.setting("plan_cache_mode")))
        self.fetch_settings.append((sql, dict(self.settings)))
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
        saved = dict(self.settings)
        try:
            yield
        except BaseException:
            self.settings = saved       # ROLLBACK TO SAVEPOINT undoes set_config(..., true); RELEASE keeps it
            raise


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
        for kind in ("inputs", "timing", "calls", "repeat", "parity", "parity_total", "env_topk", "env_topk_summary",
                     "generic_plan", "fingerprint", "defect_tour", "defect_component", "defect_pair", "day_text",
                     "coverage", "coverage_gate", "env", "grant", "xref", "stats", "done"):
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
        # A block generated from a pre-6c TripPlanner commit: no assembly twins, the cis search is CIS_SEARCH_SQL.
        saved = dict(probe.READERS)
        for key in ASSEMBLY_6C:
            probe.READERS.pop(key, None)
        probe.READERS["browse.search.CIS_SEARCH_SQL"] = PRE_6C_CIS_SEARCH
        try:
            _, lines = _run(FakeConn())
        finally:
            probe.READERS.clear()
            probe.READERS.update(saved)
        self.assertFalse(any(line.startswith("SCRIPT assembly_input") for line in lines))
        self.assertTrue(any(line.startswith("SCRIPT timing reader=search country=Laos source=cis ") for line in lines))
        self.assertFalse(any(line.startswith("SCRIPT timing reader=search_exact country=Laos source=cis ")
                             for line in lines))

    def test_committed_block_is_tripplanner_6c_6d(self):
        # AA-847 step 18: the block is generated from the TripPlanner build that reads CIS 253/256 and tp-017.
        self.assertEqual(probe.READERS_ABSENT, ["browse.search.CIS_SEARCH_SQL"])
        for key in ASSEMBLY_6C:
            self.assertIn(key, probe.READERS)
        self.assertIn("FROM catalog.v_component_embedding", probe.READERS["shared.vector_topk.TOPK_SQL_CIS"])
        self.assertIn("FROM tripplanner.component_id_map", probe.READERS["shared.component_ids.MAP_SQL"])
        for key in ("shared.vector_topk.TOPK_SQL_CIS", "shared.vector_topk.EXACT_SQL_CIS",
                    "browse.countries.COUNTRY_DESTINATIONS_SQL_CIS", "browse.destinations.DEST_SQL_CIS",
                    "browse.tiles.TILE_SQL_CIS"):
            for col in ("shape_kind", "shape_status", "length_km", "min_lat", "max_lng"):   # 6d line columns (256)
                self.assertIn(col, probe.READERS[key], f"{key}: {col}")
        _, lines = _run(FakeConn())
        text = "\n".join(lines)
        self.assertNotIn("section_error", text)
        self.assertRegex(text, r"(?m)^SCRIPT timing reader=search country=Laos source=cis ")
        self.assertRegex(text, r"(?m)^SCRIPT timing reader=search_exact country=Laos source=cis ")
        self.assertRegex(text, r"(?m)^SCRIPT parity reader=assembly_components country=Laos ")
        self.assertRegex(text, r"(?m)^SCRIPT timing reader=assembly_id_map country=Laos source=cis ")

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


class ProbeFixTests(unittest.TestCase):
    """S246 gate diagnosis, section 2.1: the probe fixes."""

    def test_env_topk_runs_as_tripplanner_natural_and_forced_with_tripplanner_settings(self):
        conn = FakeConn()
        _, lines = _run(conn)
        topk = [(sql, st, role) for sql, st, role in conn.explain_log if "catalog.v_component_embedding" in sql
                and "LIMIT $2" in sql and "<=> $1::vector" in sql]
        modes = [st.get("enable_sort", "on") for _, st, _ in topk]
        self.assertIn("off", modes)
        self.assertIn("on", modes)
        for sql, st, role in topk[-2:]:                        # the two env_topk EXPLAINs come last (pass 1)
            self.assertEqual(role, "tripplanner")
            self.assertEqual(st["hnsw.ef_search"], "400")      # TripPlanner ef_search_for(200)
            self.assertEqual(st["hnsw.iterative_scan"], "relaxed_order")
            self.assertEqual(sql, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "
                             + probe.reader("shared.vector_topk.TOPK_SQL_CIS"))   # the generated SQL, no q join
        self.assertNotEqual(conn.setting("enable_sort"), "off", "enable_sort leaked past the env_topk EXPLAIN")
        summary = next(line for line in lines if line.startswith("SCRIPT env_topk_summary"))
        for part in ("role=tripplanner", "uses_hnsw_natural=f", "uses_hnsw_forced=t",
                     "live_index=-", "join_filter_source_id=t", "raw_tours_seq_loops_gt1=t",
                     "verdict_full=FAIL", "verdict_pre258=PASS"):
            self.assertIn(part, summary)
        self.assertIn("Seq Scan:raw_tours", summary)
        self.assertFalse(hasattr(probe, "TOPK_EXPLAIN_SQL"), "the master-pass top-k EXPLAIN is gone")

    def test_env_topk_after_258_passes_the_full_check(self):
        _, lines = _run(FakeConn(forced_plan=TOPK_FORCED_POST258))
        summary = next(line for line in lines if line.startswith("SCRIPT env_topk_summary"))
        self.assertIn("live_index=raw_tours_source_key_idx", summary)
        self.assertIn("join_filter_source_id=f", summary)
        # the natural fake plan still re-scans raw_tours per destination (count subquery): full fails on that alone
        self.assertIn("verdict_full=FAIL", summary)
        self.assertIn("raw_tours_seq_loops_gt1=t", summary)

    def test_topk_plan_facts(self):
        nat = probe.topk_plan_facts(json.loads(TOPK_NATURAL))
        self.assertFalse(nat["uses_hnsw"])
        self.assertEqual(nat["live_probe"], "Hash:-/Hash Join:-/Hash:-/Seq Scan:raw_tours")
        self.assertEqual(nat["raw_tours_seq_loops"], 60)        # the count subquery, outside the scan CTE
        pre = probe.topk_plan_facts(json.loads(TOPK_FORCED_PRE258))
        self.assertTrue(pre["uses_hnsw"] and pre["hnsw_order_by"] and pre["join_filter_source_id"])
        self.assertEqual(pre["live_probe"], "Materialize:-/Hash Join:-/Hash:-/Seq Scan:raw_tours")
        self.assertIsNone(pre["live_index"])
        post = probe.topk_plan_facts(json.loads(TOPK_FORCED_POST258))
        self.assertEqual(post["live_index"], "raw_tours_source_key_idx")
        self.assertEqual(post["live_probe"], "Nested Loop:-/Index Scan:raw_tours[raw_tours_source_key_idx]")
        self.assertFalse(post["join_filter_source_id"])
        self.assertEqual(post["raw_tours_seq_loops"], 1)

    def test_cis_routes_single_and_chain_plan_per_call_and_nothing_else_does(self):
        conn = FakeConn()
        _run(conn)
        r = probe.READERS
        forced = {r["browse.routes.SINGLE_SQL_CIS"], r["browse.routes.CHAIN_SQL_CIS"]}
        seen = {"forced": 0, "other_routes": 0}
        for sql, mode in conn.fetch_log:
            if sql in forced:
                self.assertEqual(mode, "force_custom_plan", sql[:60])
                seen["forced"] += 1
            elif "catalog.v_" in sql or "tripplanner." in sql:
                self.assertEqual(mode, "auto", sql[:60])
                seen["other_routes"] += sql in (r["browse.routes.SINGLE_SQL"], r["browse.routes.CHAIN_SQL"],
                                                r["browse.routes.DAYS_SQL_CIS"])
        self.assertEqual(seen["forced"], 2 * 19 * len(probe.COUNTRIES) * probe.REPEATS)
        self.assertGreater(seen["other_routes"], 0)
        self.assertFalse(any("SET LOCAL plan_cache_mode" in sql for sql in conn.statements))
        self.assertEqual(conn.setting("plan_cache_mode"), "auto")

    def test_routes_single_per_call_lists_and_the_unforced_diagnostic(self):
        conn = FakeConn()
        _, lines = _run(conn)
        calls = [line for line in lines if line.startswith("SCRIPT calls reader=routes_single ")]
        self.assertEqual(len(calls), 2 * len(probe.COUNTRIES) * probe.REPEATS)
        self.assertEqual(len(calls[0].split("ms=")[1].split(",")), len(probe.ROUTE_DAYS))
        auto = [line for line in lines if line.startswith("SCRIPT calls reader=routes_single_auto ")]
        self.assertEqual(len(auto), len(probe.COUNTRIES))          # run 1, cis only
        auto_sql = probe.reader("browse.routes.SINGLE_SQL_CIS") + probe.AUTO_TAG
        self.assertNotEqual(auto_sql, probe.READERS["browse.routes.SINGLE_SQL_CIS"])   # its own prepared statement
        self.assertTrue(all(mode == "auto" for sql, mode in conn.fetch_log if sql == auto_sql))
        self.assertFalse(any(line.startswith("SCRIPT parity reader=routes_single_auto") for line in lines))

    def test_generic_plan_proof_prepares_explains_and_deallocates(self):
        conn = FakeConn()
        _, lines = _run(conn)
        prep = [sql for sql in conn.statements if sql.startswith("PREPARE " + probe.GENERIC_STMT)]
        self.assertEqual(len(prep), 1)
        self.assertIn("(text, int, int) AS " + probe.reader("browse.routes.SINGLE_SQL_CIS"), prep[0])
        ex = [(sql, st) for sql, st, _ in conn.explain_log if "EXECUTE " + probe.GENERIC_STMT in sql]
        self.assertEqual([st["plan_cache_mode"] for _, st in ex],
                         ["force_generic_plan", "force_custom_plan"] * len(probe.COUNTRIES))
        self.assertIn("EXECUTE aa847_single_generic('Laos', 21, 3)", ex[0][0])
        self.assertIn("DEALLOCATE " + probe.GENERIC_STMT, conn.statements)
        self.assertTrue(any(line.startswith("SCRIPT generic_plan reader=routes_single country=Laos days=21 ")
                            and "generic_exec_ms=" in line and "jit=" in line for line in lines))

    def test_generic_plan_deallocates_when_the_explain_fails(self):
        conn = FakeConn(fail_execute_explain=True)
        _, lines = _run(conn)
        self.assertIn("DEALLOCATE " + probe.GENERIC_STMT, conn.statements)
        self.assertTrue(any(line.startswith("SCRIPT plan_error reader=routes_single_generic") for line in lines))
        self.assertNotIn("section_error", "\n".join(lines))

    def test_analyze_sql_joins_on_relid(self):
        self.assertIn("c.oid = s.relid", probe.ANALYZE_SQL)
        self.assertNotIn("::regclass", probe.ANALYZE_SQL)

    def test_env_line_prints_jit(self):
        _, lines = _run(FakeConn())
        env = next(line for line in lines if line.startswith("SCRIPT env pgvector="))
        self.assertIn("jit=", env)
        self.assertIn("plan_cache_mode=auto", env)

    def test_tiles_markers_match_the_cis_bbox_filter(self):
        self.assertEqual(probe.MARKERS["tiles"], ["lat >=", "lng >=", "max_lat", "max_lng"])

    def test_three_runs_and_median_parity(self):
        _, lines = _run(FakeConn())
        self.assertEqual(sum(line.startswith("SCRIPT repeat run=") for line in lines), probe.REPEATS)
        parity = [line for line in lines if line.startswith("SCRIPT parity reader=")]
        self.assertTrue(parity and all(f"runs={probe.REPEATS}" in line for line in parity))
        self.assertTrue(any(line.startswith("SCRIPT parity_total ") and f"runs={probe.REPEATS}" in line
                            for line in lines))
        # one slow run neither fails a reader nor does one fast run rescue it
        self.assertTrue(probe.parity_verdict([10, 12, 11], [100, 900, 120])[3])
        self.assertFalse(probe.parity_verdict([10, 12, 11], [250, 90, 260])[3])
        self.assertFalse(probe.parity_verdict([10, 10, 10], [10, 10, 10], cis_errors=1)[3])
        self.assertEqual(probe.median([3, 1, 2]), 2)
        self.assertEqual(probe.median([4, 1, 2, 3]), 2.5)
        self.assertEqual(probe.parity_verdict([200, 210, 190], [0])[2], 300.0)

    def test_search_settings_stay_with_the_search_readers(self):
        conn = FakeConn()
        _run(conn)
        r = probe.reader
        search = {r(k) for k in ("shared.vector_topk.TOPK_SQL", "shared.vector_topk.EXACT_SQL",
                                 "shared.vector_topk.TOPK_SQL_CIS", "shared.vector_topk.EXACT_SQL_CIS")}
        later = {r(k) for _, lk, ck in probe.ASSEMBLY_READERS for k in (lk, ck)} | {
            r("browse.routes.SINGLE_SQL_CIS"), r("browse.routes.CHAIN_SQL_CIS")}
        seen = {"search": 0, "later": 0}
        for sql, st in conn.fetch_settings:
            if sql in search:
                self.assertEqual(st.get("hnsw.ef_search"), "400", sql[:60])
                self.assertEqual(st.get("hnsw.iterative_scan"), "relaxed_order", sql[:60])
                seen["search"] += 1
            elif sql in later:          # TripPlanner runs these outside the search's transaction
                self.assertNotIn("hnsw.ef_search", st, sql[:60])
                self.assertNotIn("hnsw.iterative_scan", st, sql[:60])
                seen["later"] += 1
        self.assertTrue(seen["search"] and seen["later"], seen)
        self.assertNotIn("hnsw.ef_search", conn.settings)
        # the EXPLAIN of the slowest search call sees the search's settings again
        ex = [st for sql, st, _ in conn.explain_log if sql.endswith(r("shared.vector_topk.TOPK_SQL"))]
        self.assertTrue(ex and all(st.get("hnsw.ef_search") == "400" for st in ex))

    def test_a_run_cut_short_stays_out_of_the_median(self):
        def series(*ms):
            s = probe.Series()
            for m in ms:
                s.add(m, [], None, "SELECT 1", ())
            return s
        full, cut = probe.complete_runs([series(100, 120, 90), series(110, 100, 95), series(5)])
        self.assertEqual((len(full), cut), (2, 1))
        self.assertEqual(probe.complete_runs([]), ([], 0))
        self.assertEqual(probe.complete_runs([series(1, 2)])[1], 0)

    def test_hnsw_is_the_named_index_only(self):
        doc = json.loads(TOPK_FORCED_POST258)
        self.assertTrue(probe.topk_plan_facts(doc)["uses_hnsw"])
        other = json.loads(TOPK_FORCED_POST258.replace(probe.HNSW_INDEX, "itinerary_components_embedding_idx"))
        self.assertFalse(probe.topk_plan_facts(other)["uses_hnsw"])

    def test_explain_settings_end_with_their_savepoint(self):
        conn = FakeConn()

        async def go():
            await probe.explain_doc(conn, "SELECT 1", (), [("enable_sort", "off")])
        asyncio.run(go())
        self.assertEqual(conn.explain_log[-1][1]["enable_sort"], "off")
        self.assertNotIn("enable_sort", conn.settings)


if __name__ == "__main__":
    unittest.main()
