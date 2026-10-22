"""Unit tests for db/check_erd_drift.py (AA-894 scope 3): design ERD page vs the live erd.json.

The live side is built with db/gen_erd.py from a small schema_dump.py fixture, so the two scripts stay compatible.
Run: python3 -m unittest discover -s db/tests -v
"""
import copy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_erd_drift as drift  # noqa: E402
import gen_erd as erd  # noqa: E402
from test_gen_erd import col, fk, pk_index, rel  # noqa: E402

DESIGN = '''---
id: APP-04-erd-design-crm
---

# ERD design: crm schema

<!-- erd-design schema=crm enforce=ENFORCE implied-fk=tenant_id:tenant -->

```mermaid
erDiagram
    tenant {
        uuid tenant_id PK
        text slug UK
    }
    member {
        uuid member_id PK
        uuid tenant_id FK
    }
    tenant ||--o{ member : "tenant_id"
```

Text between the diagrams.

```mermaid
erDiagram
    %% the trip is the folder
    trip {
        uuid trip_id PK
        uuid tenant_id FK
        uuid owner_member_id FK
        text stage
    }
    "many" {
        uuid pk_ PK
        uuid tenant_id FK
        uuid trip_id FK
        uuid destination_id FK "soft? no: a real cross-schema FK"
    }
    member |o--o{ trip : "owner_member_id"
    trip ||--o{ "many" : "trip_id"
    "shared.destinations" ||--o{ "many" : "destination_id"
```
'''


def design_text(enforce=False):
    return DESIGN.replace("ENFORCE", "true" if enforce else "false")


def live_dump(mutate=None):
    """A format-2 dump whose crm schema matches DESIGN; `mutate(relations)` seeds a mismatch."""
    crm = {
        "tenant": rel([col("tenant_id"), col("slug", "text")], [pk_index("crm", "tenant", "tenant_id")],
                      owner="crm_owner"),
        "member": rel([col("member_id"), col("tenant_id")], [pk_index("crm", "member", "member_id")],
                      [fk("member_tenant_id_fkey", "tenant_id", "crm", "tenant", "tenant_id")], owner="crm_owner"),
        "trip": rel([col("trip_id"), col("tenant_id"), col("owner_member_id", not_null=False), col("stage", "text")],
                    [pk_index("crm", "trip", "trip_id")],
                    [fk("trip_tenant_id_fkey", "tenant_id", "crm", "tenant", "tenant_id"),
                     fk("trip_owner_member_id_fkey", "owner_member_id", "crm", "member", "member_id")],
                    owner="crm_owner"),
        "many": rel([col("pk"), col("tenant_id"), col("trip_id"), col("destination_id")],
                    [pk_index("crm", "many", "pk")],
                    [fk("many_tenant_id_fkey", "tenant_id", "crm", "tenant", "tenant_id"),
                     fk("many_trip_id_fkey", "trip_id", "crm", "trip", "trip_id"),
                     fk("many_destination_id_fkey", "destination_id", "shared", "destinations", "id")],
                    owner="crm_owner"),
        # A partition of a partitioned table is not a table of its own on either side.
        "many_2026_10": rel([col("pk")], is_partition=True, owner="crm_owner"),
    }
    if mutate:
        mutate(crm)
    return {
        "format": 2, "generated_at": "2026-10-22T03:43:00+00:00",
        "schemas": [{"schema": "crm", "owner": "crm_owner", "grants": []},
                    {"schema": "shared", "owner": "cis_owner", "grants": []}],
        "relations": {"crm": crm,
                      "shared": {"destinations": rel([col("id")], [pk_index("shared", "destinations", "id")],
                                                     owner="cis_owner")}},
        "migrations": [], "migrations_latest_per_owner": {},
    }


def model(mutate=None):
    return erd.build_model(live_dump(mutate))


def seed_mismatch(crm):
    """Drop an FK, add a table nobody designed, change a primary key."""
    crm["trip"]["constraints"] = [c for c in crm["trip"]["constraints"] if c["constraint"] != "trip_owner_member_id_fkey"]
    crm["stray"] = rel([col("id")], [pk_index("crm", "stray", "id")], owner="crm_owner")
    crm["member"]["indexes"] = [pk_index("crm", "member", "tenant_id, member_id")]


class ParseTest(unittest.TestCase):
    def setUp(self):
        self.design = drift.parse_design(design_text(), "crm.md")

    def test_marker(self):
        self.assertEqual(self.design.schema, "crm")
        self.assertFalse(self.design.enforce)
        self.assertEqual(self.design.implied, [("tenant_id", "tenant")])
        self.assertTrue(drift.parse_design(design_text(True)).enforce)

    def test_tables_keys_and_edges(self):
        self.assertEqual(sorted(self.design.tables), ["many", "member", "tenant", "trip"])
        self.assertEqual(self.design.tables["many"].pk, ["pk"])            # `pk_` is gen_erd's spelling of `pk`
        self.assertEqual(self.design.tables["trip"].fk_columns, ["tenant_id", "owner_member_id"])
        self.assertEqual(self.design.edges, {
            ("member", ("tenant_id",), "tenant"),                        # drawn
            ("trip", ("owner_member_id",), "member"),
            ("trip", ("tenant_id",), "tenant"),                          # implied by the marker
            ("many", ("tenant_id",), "tenant"),
            ("many", ("trip_id",), "trip"),
            ("many", ("destination_id",), "shared.destinations"),        # cross-schema parent stays qualified
        })
        self.assertEqual(self.design.problems, [])

    def test_design_problems(self):
        text = design_text().replace('    trip ||--o{ "many" : "trip_id"\n', "") \
            .replace("        uuid owner_member_id FK\n", "        uuid owner_member_id\n") \
            .replace("    %% the trip is the folder\n", "    trip }}--{{ nonsense\n    ghost\n")
        problems = drift.parse_design(text).problems
        self.assertTrue(any("line does not parse" in p for p in problems), problems)
        self.assertTrue(any(p.startswith("ghost is referenced") for p in problems), problems)
        self.assertTrue(any("many.trip_id is marked FK" in p for p in problems), problems)
        self.assertTrue(any("owner_member_id that is not an FK attribute of trip" in p for p in problems), problems)

    def test_missing_marker_and_second_box(self):
        text = design_text().replace("<!-- erd-design schema=crm enforce=false implied-fk=tenant_id:tenant -->", "")
        d = drift.parse_design(text)
        self.assertIsNone(d.schema)
        self.assertTrue(any("marker" in p for p in d.problems))
        twice = design_text().replace("    %% the trip is the folder\n", "    tenant {\n        uuid tenant_id PK\n    }\n")
        self.assertTrue(any("second attribute block" in p for p in drift.parse_design(twice).problems))


class CompareTest(unittest.TestCase):
    def test_matching_state_is_in_sync(self):
        for enforce in (False, True):
            with self.subTest(enforce=enforce):
                result = drift.check(drift.parse_design(design_text(enforce), "crm.md"), model())
                self.assertEqual(result.status, "in_sync", result.findings)
                self.assertFalse(result.fails)

    def test_seeded_mismatch_is_reported(self):
        result = drift.check(drift.parse_design(design_text(), "crm.md"), model(seed_mismatch))
        self.assertEqual(result.status, "drift")
        self.assertEqual(result.findings["missing_tables"], [])
        self.assertEqual(result.findings["extra_tables"], ["stray"])
        self.assertEqual(result.findings["missing_edges"], [("trip", ("owner_member_id",), "member")])
        self.assertEqual(result.findings["extra_edges"], [])
        self.assertEqual(len(result.findings["pk"]), 1)
        self.assertIn("`member`", result.findings["pk"][0])
        self.assertFalse(result.fails)                                   # enforce=false: report only
        self.assertTrue(drift.check(drift.parse_design(design_text(True)), model(seed_mismatch)).fails)

    def test_missing_table_and_extra_edge(self):
        def mutate(crm):
            del crm["many"]
            crm["trip"]["constraints"].append(fk("trip_x_fkey", "stage", "crm", "tenant", "slug"))
        result = drift.check(drift.parse_design(design_text(True)), model(mutate))
        self.assertEqual(result.findings["missing_tables"], ["many"])
        self.assertEqual(result.findings["extra_edges"], [("trip", ("stage",), "tenant")])
        self.assertTrue(result.fails)

    def test_not_live_schema_passes_even_when_enforced(self):
        def drop_all(crm):
            crm.clear()
        for m in (model(drop_all), {"schemas": []}):
            result = drift.check(drift.parse_design(design_text(True)), m)
            self.assertEqual(result.status, "not_live")
            self.assertFalse(result.fails)

    def test_design_problem_fails_only_when_enforced_and_live(self):
        broken = design_text(True).replace("    %% the trip is the folder\n", "    ghost\n")
        self.assertEqual(drift.check(drift.parse_design(broken), model()).status, "invalid")
        self.assertTrue(drift.check(drift.parse_design(broken), model()).fails)
        self.assertFalse(drift.check(drift.parse_design(broken.replace("enforce=true", "enforce=false")),
                                     model()).fails)


class CliTest(unittest.TestCase):
    def run_cli(self, design, live, name="crm.md"):
        with tempfile.TemporaryDirectory() as tmp:
            ddir = Path(tmp) / "design"
            ddir.mkdir()
            (ddir / name).write_text(design, encoding="utf-8")
            (ddir / "README.md").write_text("# not a design page\n", encoding="utf-8")
            (Path(tmp) / "erd.json").write_text(json.dumps(live), encoding="utf-8")
            summary = Path(tmp) / "summary.md"
            out = io.StringIO()
            with redirect_stdout(out):
                code = drift.main([str(Path(tmp) / "erd.json"), str(ddir), "--summary", str(summary)])
            return code, out.getvalue(), summary.read_text(encoding="utf-8")

    def test_green_on_match(self):
        code, out, summary = self.run_cli(design_text(True), model())
        self.assertEqual(code, 0, out)
        self.assertIn("in sync (4 tables, 6 FK edges)", summary)

    def test_red_on_seeded_mismatch_when_enforced(self):
        code, out, summary = self.run_cli(design_text(True), model(seed_mismatch))
        self.assertEqual(code, 1, out)
        self.assertIn("**drift: 3 finding(s)** (fails)", summary)
        self.assertIn("FK edges in the design, not live (1): `trip` (owner_member_id) -> `member`", summary)
        self.assertIn("::error title=ERD drift::crm", out)

    def test_report_only_when_not_enforced(self):
        code, out, _ = self.run_cli(design_text(False), model(seed_mismatch))
        self.assertEqual(code, 0)
        self.assertIn("::warning title=ERD drift::crm", out)

    def test_not_live_yet(self):
        code, out, summary = self.run_cli(design_text(True), {"schemas": [], "fingerprint": "f" * 64})
        self.assertEqual(code, 0)
        self.assertIn("not live yet", summary)

    def test_file_name_must_match_schema(self):
        code, _, summary = self.run_cli(design_text(True), model(), name="booking.md")
        self.assertEqual(code, 1)
        self.assertIn("file name booking.md does not match schema=crm", summary)

    def test_usage_error(self):
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            self.assertEqual(drift.main([os.devnull + ".missing", os.devnull]), 2)


if __name__ == "__main__":
    unittest.main()
