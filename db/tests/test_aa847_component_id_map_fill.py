"""AA-847: db/scripts/aa847_component_id_map_fill.py (tripplanner.component_id_map fill, tp-017).

No database: a fake connection answers the script's SQL constants. Checks the run-script shape (READ_ONLY dry run as
merged), the match rules (name first, then destination; old version tour ids mapped through raw_tours; orphans and
unknown keys counted, never inserted), that the dry run writes nothing, and that the apply inserts as tripplanner
with ON CONFLICT DO NOTHING.
Run: python3 -m unittest discover -s db/tests -v
"""
import asyncio
import contextlib
import importlib.util
import io
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import run_migration as rm  # noqa: E402

ROOT = HERE.parent.parent
PATH = "db/scripts/aa847_component_id_map_fill.py"


def _load():
    spec = importlib.util.spec_from_file_location("aa847_component_id_map_fill", ROOT / PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fill = _load()

SRC_A = "aaaaaaaa-0000-0000-0000-000000000001"     # live, frozen key = source id
SRC_B = "bbbbbbbb-0000-0000-0000-000000000002"     # live, frozen key = an old version tour_id
OLD_B = "bbbbbbbb-1111-0000-0000-000000000002"
SRC_GONE = "cccccccc-0000-0000-0000-000000000003"  # not live (orphan)
OLD_GONE = "cccccccc-1111-0000-0000-000000000003"
D1, D2 = "d1000000-0000-0000-0000-000000000001", "d2000000-0000-0000-0000-000000000002"

FROZEN = [
    {"id": "f1", "key": SRC_A, "day": 1, "name": "Kuang Si Falls", "activity": "nature", "destination_id": D1},
    {"id": "f2", "key": SRC_A, "day": 2, "name": "Night market (Luang Prabang)", "activity": "culinary",
     "destination_id": D2},
    {"id": "f3", "key": OLD_B, "day": 3, "name": "Pak Ou Caves", "activity": "cultural_heritage", "destination_id": D1},
    {"id": "f4", "key": OLD_B, "day": 4, "name": "Somewhere new", "activity": "trekking", "destination_id": None},
    {"id": "f5", "key": OLD_GONE, "day": 1, "name": "Gone", "activity": "nature", "destination_id": D1},
    {"id": "f6", "key": "never-a-tour", "day": 1, "name": "Ghost", "activity": "nature", "destination_id": D1},
]
CIS = [
    {"component_id": "n1", "source_id": SRC_A, "day_index": 1, "name": "Kuang Si Falls", "activity": "nature",
     "destination_id": D1},
    {"component_id": "n0", "source_id": SRC_A, "day_index": 1, "name": "Kuang Si Falls", "activity": "nature",
     "destination_id": D1},                         # same key, smaller id: the deterministic pick
    {"component_id": "n2", "source_id": SRC_A, "day_index": 2, "name": "Talat Dara market", "activity": "culinary",
     "destination_id": D2},                         # spelled differently: matched by destination
    {"component_id": "n3", "source_id": SRC_B, "day_index": 3, "name": "Pak Ou Caves", "activity": "cultural_heritage",
     "destination_id": D1},
]
LIVE = {SRC_A: "Laos", SRC_B: "Laos"}
KEY_MAP = {OLD_B: SRC_B, OLD_GONE: SRC_GONE}


def _norm(name):
    return re.sub(r"\s+", " ", re.sub(r"\([^)]*\)", "", name.lower())).strip()


class FakeConn:
    def __init__(self, refuse_role=False, id_map=True):
        self.refuse_role, self.id_map = refuse_role, id_map
        self.role = "aa_cis_admin"
        self.statements = []
        self.inserted = None

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if "SET LOCAL ROLE" in sql:
            if self.refuse_role:
                raise PermissionError("permission denied to set role")
            self.role = "tripplanner"
            return "SET"
        if sql is fill.INSERT_SQL:
            assert self.role == "tripplanner"
            self.inserted = list(zip(*args))
            return f"INSERT 0 {len(self.inserted) - 1}"   # one row already there (ON CONFLICT DO NOTHING)
        return "OK"

    async def fetchval(self, sql, *args):
        self.statements.append(sql)
        if sql is fill.ID_MAP_EXISTS_SQL:
            return self.id_map
        if sql is fill.EXISTING_SQL:
            return 0
        raise AssertionError(sql[:60])

    async def fetch(self, sql, *args):
        self.statements.append(sql)
        if sql is fill.LIVE_SOURCES_SQL:
            assert self.role == "tripplanner"
            return [{"source_id": s, "country": c} for s, c in LIVE.items()]
        if sql is fill.CIS_COMPONENTS_SQL:
            assert self.role == "tripplanner"
            return CIS
        if sql is fill.FROZEN_SQL:
            return FROZEN
        if sql is fill.KEY_MAP_SQL:
            assert args[0] == fill.AA_TENANT_ID
            return [{"key": k, "source_id": v} for k, v in KEY_MAP.items() if k in args[1]]
        if sql is fill.NAME_NORM_SQL:
            return [{"name": n, "norm": _norm(n)} for n in args[0]]
        raise AssertionError(sql[:60])

    @contextlib.asynccontextmanager
    async def transaction(self):
        role = self.role
        try:
            yield
        finally:
            self.role = role          # SET LOCAL ROLE ends with its transaction


def _run(conn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(fill.main(conn))
    return rc, buf.getvalue().splitlines()


class ShapeTests(unittest.TestCase):
    def test_runner_accepts_it_and_it_is_merged_as_a_dry_run(self):
        source = (ROOT / PATH).read_text(encoding="utf-8")
        self.assertEqual(rm.script_errors(source, PATH), [])
        self.assertTrue(rm.script_is_read_only(source), "merge the fill as READ_ONLY = True; the apply PR flips it")


class MatchTests(unittest.TestCase):
    def setUp(self):
        norm = {n: _norm(n) for n in {r["name"] for r in FROZEN + CIS}}
        self.pairs, self.counts, self.unmatched = fill.match(FROZEN, CIS, KEY_MAP, LIVE, norm)

    def test_rules_in_order(self):
        self.assertEqual(self.pairs, [("f1", "n0", "name"), ("f2", "n2", "destination"), ("f3", "n3", "name")])

    def test_counts_orphans_and_unknown_keys_apart(self):
        self.assertEqual(self.counts["Laos"], {"frozen": 4, "name": 2, "destination": 1, "unmatched": 1,
                                               "not_live": 0, "no_source": 0})
        self.assertEqual(self.counts["-"], {"frozen": 2, "name": 0, "destination": 0, "unmatched": 0,
                                            "not_live": 1, "no_source": 1})
        self.assertEqual(self.unmatched, [{"country": "Laos", "source_id": SRC_B, "day": 4, "name": "Somewhere new"}])

    def test_source_of(self):
        self.assertEqual(fill.source_of(SRC_A, KEY_MAP, LIVE), SRC_A)
        self.assertEqual(fill.source_of(OLD_B, KEY_MAP, LIVE), SRC_B)
        self.assertIsNone(fill.source_of("never-a-tour", KEY_MAP, LIVE))


class RunTests(unittest.TestCase):
    def test_dry_run_writes_nothing(self):
        conn = FakeConn()
        rc, lines = _run(conn)
        self.assertEqual(rc, 0)
        self.assertIsNone(conn.inserted)
        self.assertNotIn(fill.INSERT_SQL, conn.statements)
        self.assertIn("SCRIPT match_total frozen=6 name=2 destination=1 unmatched=1 not_live=1 no_source=1 "
                      "live_share=0.750", lines)
        self.assertTrue(all(line.startswith("SCRIPT ") for line in lines))

    def test_apply_inserts_as_tripplanner_on_conflict_do_nothing(self):
        fill.READ_ONLY = False
        try:
            conn = FakeConn()
            rc, lines = _run(conn)
        finally:
            fill.READ_ONLY = True
        self.assertEqual(rc, 0)
        self.assertEqual(conn.inserted, [("f1", "n0", "name"), ("f2", "n2", "destination"), ("f3", "n3", "name")])
        self.assertIn("ON CONFLICT (old_id) DO NOTHING", fill.INSERT_SQL)
        self.assertIn("SCRIPT apply inserted=2 skipped_existing=1", lines)

    def test_refuses_without_the_switch_or_the_table(self):
        rc, lines = _run(FakeConn(refuse_role=True))
        self.assertEqual(rc, 1)
        self.assertTrue(any(line.startswith("SCRIPT refuse what=set_role") for line in lines))
        rc, lines = _run(FakeConn(id_map=False))
        self.assertEqual(rc, 1)
        self.assertTrue(any(line.startswith("SCRIPT refuse what=id_map_missing") for line in lines))


if __name__ == "__main__":
    unittest.main()
