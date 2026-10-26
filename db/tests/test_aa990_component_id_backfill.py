"""AA-990: db/scripts/aa990_component_id_backfill.py (re-point dangling TripPlanner pins in component_id_map)."""

import ast
import asyncio
import contextlib
import importlib.util
import io
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = "db/scripts/aa990_component_id_backfill.py"
_spec = importlib.util.spec_from_file_location("aa990_component_id_backfill", ROOT / PATH)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

T0 = datetime(2026, 10, 20, tzinfo=timezone.utc)      # before the flip
T1 = datetime(2026, 10, 22, tzinfo=timezone.utc)      # map fill (flip)
T2 = datetime(2026, 10, 23, tzinfo=timezone.utc)      # pinned after the flip
T3 = datetime(2026, 10, 25, 19, tzinfo=timezone.utc)  # S252 rebuild


def _norm(s):
    return " ".join("".join(ch if ch.isalnum() else " " for ch in (s or "").lower()).split())


def _place(cid, source, day, name, act="cultural_heritage", dest=None, card=None, link=None, country="vietnam",
           locality=""):
    return {"component_id": cid, "source_id": source, "day_index": day, "name": name, "name_norm": _norm(link or name),
            "country_norm": country, "locality_norm": locality, "activity": act, "destination_id": dest,
            "place_card_id": card}


class PureTest(unittest.TestCase):
    def test_component_uuid_matches_cis_names_component_id(self):
        # CIS: names.component_id("src-1", 2, "Hoi An Ancient Town", "Vietnam", "cultural_heritage")
        self.assertEqual(mod.component_uuid("src-1", 2, "hoi an ancient town", "vietnam", "cultural_heritage"),
                         "8f3f0189-90bf-5d57-a2d1-03c41bdf3d52")

    def test_pins_and_ids_reads_add_remove_reorder(self):
        ev = [{"trip_id": "t", "event_type": "add_component", "payload": json.dumps({"component_id": "a"}),
               "created_at": T2},
              {"trip_id": "t", "event_type": "add_component", "payload": {"component_id": "a"}, "created_at": T0},
              {"trip_id": "t", "event_type": "remove_component", "payload": {"component_id": "b"}, "created_at": T2},
              {"trip_id": "t", "event_type": "reorder", "payload": {"ordered_component_ids": ["a", "c"]},
               "created_at": T2}]
        pins, ids, keys = mod.pins_and_ids(ev)
        self.assertEqual(pins, [{"trip_id": "t", "raw": "a", "created_at": T0}])
        self.assertEqual(ids, {"a", "b", "c"})
        self.assertEqual(keys, {"component_id": 2})

    def test_rederive_recovers_the_id_a_dropped_build_minted(self):
        old_id = mod.component_uuid("S", 3, "my son sanctuary", "vietnam", "cultural_heritage")
        idx = mod.rederive_index([{"tour_id": "v1", "day": 3, "place": "Mỹ Sơn Sanctuary", "card_id": None,
                                   "card_name": None, "destination_id": None}],
                                 {"v1": "S"}, {"S": {"vietnam"}}, {"Mỹ Sơn Sanctuary": "my son sanctuary"})
        self.assertEqual(len(idx), 8)                                # 8 activities x 1 country
        self.assertEqual(idx[old_id]["spelling"], "my son sanctuary")
        self.assertEqual(idx[old_id]["day"], 3)

    def test_pick_target_rule_order_and_nearest_day(self):
        rows = [dict(_place("p2", "S", 2, "Hoi An Ancient Town"), spelling="hoi an ancient town"),
                dict(_place("p5", "S", 5, "Hoi An Ancient Town", act="culinary"), spelling="hoi an ancient town"),
                dict(_place("pd", "S", 1, "Linh Mu Pagoda", dest="D1"), spelling="linh mu pagoda")]
        old = {"day": 4, "spelling": "hoi an ancient town", "link": "hoi an ancient town", "country_norm": "vietnam",
               "activity": "cultural_heritage", "destination_id": None, "card_id": None}
        self.assertEqual(mod.pick_target(old, rows), ("p5", "spelling", None))
        old_dest = dict(old, spelling="thien mu pagoda", link="thien mu pagoda", destination_id="D1")
        self.assertEqual(mod.pick_target(old_dest, rows), ("pd", "destination", None))
        gone = dict(old, spelling="bach ma park", link="bach ma park")
        self.assertEqual(mod.pick_target(gone, rows), (None, None, "no_same_place"))

    def _markets(self):
        rows = [dict(_place("cr", "S", 4, "Night Market", country="thailand", locality="chiang rai"),
                     spelling="night market"),
                dict(_place("bkk", "S", 1, "Wat Pho", country="thailand"), spelling="wat pho")]
        return rows, mod.generic_names(rows)

    def test_generic_name_never_matches_the_same_name_in_another_city(self):
        rows, generic = self._markets()
        self.assertEqual(generic, {"night market"})
        old = {"day": 2, "spelling": "night market", "link": "night market", "country_norm": "thailand",
               "activity": "culinary", "destination_id": None, "card_id": None, "locality": "chiang mai"}
        self.assertEqual(mod.pick_target(old, rows, generic), (None, None, "no_same_place"))
        same_city = dict(old, locality="chiang rai")
        self.assertEqual(mod.pick_target(same_city, rows, generic), ("cr", "spelling", None))

    def test_generic_name_without_a_locality_is_unmatched_not_guessed(self):
        rows, generic = self._markets()
        old = {"day": 4, "spelling": "night market", "link": "night market", "country_norm": None,
               "activity": None, "destination_id": None, "card_id": None, "locality": None}     # e.g. a snapshot
        self.assertEqual(mod.pick_target(old, rows, generic), (None, None, "generic_no_locality"))
        # a generic spelling of a card-linked row (locality_norm '') is generic too: still no match without a locality
        rows.append(dict(_place("cm", "S", 2, "Night Market", link="Chiang Mai Night Bazaar", country="thailand"),
                         spelling="night market"))
        self.assertEqual(mod.pick_target(old, rows, generic)[0], None)
        # an unresolvable generic row ('?') never matches, even a known locality
        q = [dict(_place("q", "S", 2, "Night Market", country="thailand", locality="?"), spelling="night market")]
        self.assertEqual(mod.pick_target(dict(old, locality="chiang mai"), q, generic)[0], None)

    def test_old_locality_from_the_card_else_a_day_anchor_the_old_atoms_confirm(self):
        norm = {"Night Market": "night market", "Chiang Mai": "chiang mai", "Doi Suthep": "doi suthep",
                "Chiang Rai": "chiang rai"}
        a_card = {"tour_id": "v1", "day": 2, "place": "Night Market", "card_locality": "Chiang Rai"}
        self.assertEqual(mod.old_locality(a_card, "S", norm, {}, {}), "chiang rai")
        a = {"tour_id": "v1", "day": 2, "place": "Night Market", "card_locality": None}
        confirmed = mod.day_towns([a, {"tour_id": "v1", "day": 2, "place": "Chiang Mai"}], norm)
        self.assertEqual(mod.old_locality(a, "S", norm, {("S", 2): "chiang mai"}, confirmed), "chiang mai")
        # the current day 2 sleeps in Chiang Rai, but the old version's day 2 never names it: unknown
        self.assertIsNone(mod.old_locality(a, "S", norm, {("S", 2): "chiang rai"}, confirmed))
        idx = mod.rederive_index([a, {"tour_id": "v1", "day": 2, "place": "Chiang Mai"}], {"v1": "S"},
                                 {"S": {"thailand"}}, norm, {("S", 2): "chiang mai"})
        cid = mod.component_uuid("S", 2, "night market", "thailand", "culinary")
        self.assertEqual(idx[cid]["locality"], "chiang mai")

    def test_plan_reports_generic_no_locality(self):
        rows, _ = self._markets()
        snap = {"SNAP": {"source_id": "S", "day": 4, "spelling": "night market", "link": "night market",
                         "country_norm": None, "activity": None, "destination_id": None, "card_id": None,
                         "locality": None}}
        d = mod.plan({"SNAP"}, {}, rows, {}, {}, snap, {"S"})
        self.assertEqual((d["SNAP"]["target"], d["SNAP"]["reason"]), (None, "generic_no_locality"))

    def test_follow_redirect_chain_and_cycle(self):
        self.assertEqual(mod.follow_redirect("a", {"a": "b", "b": "c"}, {"c": {}}), "c")
        self.assertIsNone(mod.follow_redirect("a", {"a": "b", "b": "a"}, {}))

    def test_plan_insert_update_and_reasons(self):
        rebuilt = mod.component_uuid("S", 2, "hoi an ancient town", "vietnam", "local_immersion")
        places = [dict(_place("NEW", "S", 2, "Hoi An Ancient Town"), spelling="hoi an ancient town"),
                  dict(_place("KEEP", "S", 1, "Da Nang"), spelling="da nang")]
        rederived = {rebuilt: {"source_id": "S", "day": 2, "spelling": "hoi an ancient town",
                               "link": "hoi an ancient town", "country_norm": "vietnam", "activity": "local_immersion",
                               "destination_id": None, "card_id": None}}
        snapshots = {"SNAP": {"source_id": "S", "day": 1, "spelling": "da nang", "link": "da nang",
                              "country_norm": None, "activity": None, "destination_id": None, "card_id": None},
                     "OFF": {"source_id": "GONE", "day": 1, "spelling": "x", "link": "x", "country_norm": None,
                             "activity": None, "destination_id": None, "card_id": None}}
        id_map = {"TPOLD": rebuilt, "TPFINE": "KEEP"}
        raw = {rebuilt, "TPOLD", "TPFINE", "KEEP", "SNAP", "OFF", "LOST", "R1"}
        d = mod.plan(raw, id_map, places, {"R1": "R2", "R2": "NEW"}, rederived, snapshots, {"S"})
        self.assertNotIn("TPFINE", d)                                   # resolves already
        self.assertNotIn("KEEP", d)
        self.assertEqual((d[rebuilt]["target"], d[rebuilt]["in_map"]), ("NEW", False))
        self.assertEqual((d["TPOLD"]["target"], d["TPOLD"]["in_map"], d["TPOLD"]["cur"]), ("NEW", True, rebuilt))
        self.assertEqual((d["SNAP"]["target"], d["SNAP"]["recovered_by"]), ("KEEP", "snapshot"))
        self.assertEqual((d["R1"]["target"], d["R1"]["recovered_by"]), ("NEW", "redirect"))
        self.assertEqual(d["OFF"]["reason"], "source_not_live")
        self.assertEqual(d["LOST"]["reason"], "not_recoverable")
        self.assertTrue(all(x["matched_by"] in (None, "name", "destination") for x in d.values()))   # tp-017 CHECK


class _Conn:
    """Answers the script's reads from fixtures; records writes."""

    def __init__(self, data):
        self.data = data
        self.writes = []
        self.roles = []

    async def fetchval(self, sql, *args):
        return True

    async def fetch(self, sql, *args):
        for key, rows in self.data.items():
            if getattr(mod, key) == sql:
                return rows
        if sql == mod.NAME_NORM_SQL:
            return [{"name": n, "norm": _norm(n)} for n in args[0]]
        raise AssertionError("unexpected SQL")

    async def execute(self, sql, *args):
        if sql.startswith("SET LOCAL ROLE"):
            self.roles.append(sql.split()[-1])
            return "SET"
        if sql.startswith("SELECT set_config"):
            return "SELECT 1"
        self.writes.append((sql, args))
        return "INSERT 0 1" if "INSERT" in sql else "UPDATE 1"

    def transaction(self):
        class _Tx:
            async def __aenter__(self_inner):
                return self_inner

            async def __aexit__(self_inner, *exc):
                return False
        return _Tx()


def _fixture():
    dropped = mod.component_uuid("S", 2, "hoi an ancient town", "vietnam", "local_immersion")
    return dropped, {
        "EVENTS_SQL": [
            {"trip_id": "trip1", "event_type": "add_component", "payload": json.dumps({"component_id": dropped}),
             "created_at": T2},
            {"trip_id": "trip2", "event_type": "add_component", "payload": json.dumps({"component_id": "TPOLD"}),
             "created_at": T0},
            {"trip_id": "trip2", "event_type": "add_component", "payload": json.dumps({"component_id": "KEEP"}),
             "created_at": T2}],
        "MAP_SQL": [{"old_id": "TPOLD", "new_id": dropped, "created_at": T1}],
        "DRAFTS_SQL": [],
        "PLACES_SQL": [_place("NEW", "S", 2, "Hoi An Ancient Town"), _place("KEEP", "S", 1, "Da Nang")],
        "DAYS_SQL": [{"source_id": "S", "day_index": 2, "anchor_norm": "hoi an"}],
        "BUILDS_SQL": [{"source_id": "S", "country": "Vietnam", "built_at": T3, "redirects": None}],
        "LIVE_SQL": [{"source_id": "S"}],
        "VERSIONS_SQL": [{"tour_id": "11111111-1111-1111-1111-111111111111", "source_id": "S", "country": "Vietnam"}],
        "ATOMS_SQL": [{"tour_id": "11111111-1111-1111-1111-111111111111", "day": 2, "place": "Hoi An Ancient Town",
                       "card_id": None, "card_name": None, "destination_id": None}],
    }


def _run(conn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = asyncio.run(mod.main(conn))
    return rc, buf.getvalue()


class MainTest(unittest.TestCase):
    def test_merged_as_dry_run(self):
        tree = ast.parse((ROOT / PATH).read_text())
        assigns = [n for n in tree.body if isinstance(n, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "READ_ONLY" for t in n.targets)]
        self.assertEqual(len(assigns), 1)
        self.assertIs(mod.READ_ONLY, True)

    def test_dry_run_counts_and_writes_nothing(self):
        _, data = _fixture()
        conn = _Conn(data)
        rc, text = _run(conn)
        self.assertEqual(rc, 0)
        self.assertEqual(conn.writes, [])
        self.assertEqual(conn.roles, [])
        self.assertIn("SCRIPT pins pins=3 trips=2 dangling=2 trips_with_dangling=2", text)
        self.assertIn("SCRIPT dangling_origin catalog_id=1 pre_flip_mapped=1", text)
        self.assertIn("before_flip=1", text)
        self.assertIn("before_current_build=1", text)
        self.assertIn("SCRIPT plan insert=1 update=1 unmatched=0", text)
        self.assertIn("SCRIPT expected_after dangling=0", text)
        self.assertIn("SCRIPT payload_keys event=add_component keys=component_id n=3", text)
        self.assertNotIn("trip1", text)                                  # no trip ids in the log

    def test_apply_inserts_as_tripplanner_updates_as_tp_owner_and_prints_restore(self):
        dropped, data = _fixture()
        conn = _Conn(data)
        mod.READ_ONLY = False
        try:
            rc, text = _run(conn)
        finally:
            mod.READ_ONLY = True
        self.assertEqual(rc, 0)
        self.assertEqual(conn.roles, ["tripplanner", "tripplanner", "tp_owner", "tp_owner"])
        self.assertEqual([w[1] for w in conn.writes],
                         [(dropped, "NEW", "name"), ("TPOLD", dropped, "NEW", "name")])
        self.assertIn(f"SCRIPT restore op=insert old_id={dropped}", text)
        self.assertIn(f"SCRIPT restore op=update old_id=TPOLD prev_new_id={dropped}", text)
        self.assertIn("SCRIPT apply inserted=1 updated=1 skipped_changed=0", text)

    def test_second_run_after_apply_plans_nothing(self):
        dropped, data = _fixture()
        data["MAP_SQL"] = [{"old_id": "TPOLD", "new_id": "NEW", "created_at": T1},
                           {"old_id": dropped, "new_id": "NEW", "created_at": T3}]
        rc, text = _run(_Conn(data))
        self.assertIn("SCRIPT plan insert=0 update=0 unmatched=0", text)
        self.assertIn("dangling=0", text)

    def test_write_sql_shapes(self):
        self.assertIn("ON CONFLICT (old_id) DO NOTHING", mod.INSERT_SQL)
        self.assertIn("AND new_id = $2::uuid", mod.UPDATE_SQL)            # guarded on the value the plan saw
        for name in [n for n in dir(mod) if n.endswith("_SQL") and n not in ("INSERT_SQL", "UPDATE_SQL")]:
            sql = getattr(mod, name).upper()
            for verb in ("INSERT ", "UPDATE ", "DELETE ", "TRUNCATE ", "ALTER ", "DROP ", "CREATE "):
                self.assertNotIn(verb, sql, f"{name} contains {verb.strip()}")


if __name__ == "__main__":
    unittest.main()
